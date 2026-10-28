import Foundation

public struct BridgeFlowLimits: Sendable {
    public let dataMessages: Int, dataBytes: Int, controlMessages: Int, controlBytes: Int
    public let globalDataMessages: Int, globalDataBytes: Int, globalControlMessages: Int,
        globalControlBytes: Int, batchSize: Int
    public init(
        dataMessages: Int = 128, dataBytes: Int = 4 * 1024 * 1024, controlMessages: Int = 32,
        controlBytes: Int = 256 * 1024, globalDataMessages: Int = 1024,
        globalDataBytes: Int = 16 * 1024 * 1024, globalControlMessages: Int = 256,
        globalControlBytes: Int = 2 * 1024 * 1024, batchSize: Int = 32
    ) {
        self.dataMessages = max(1, dataMessages)
        self.dataBytes = max(1, dataBytes)
        self.controlMessages = max(1, controlMessages)
        self.controlBytes = max(1, controlBytes)
        self.globalDataMessages = max(1, globalDataMessages)
        self.globalDataBytes = max(1, globalDataBytes)
        self.globalControlMessages = max(1, globalControlMessages)
        self.globalControlBytes = max(1, globalControlBytes)
        self.batchSize = min(32, max(1, batchSize))
    }
}

struct BridgeOutboundMetadata {
    let callbackId: String?, subscriptionId: String?, topic: String?
    init(callbackId: String? = nil, subscriptionId: String? = nil, topic: String? = nil) {
        self.callbackId = callbackId
        self.subscriptionId = subscriptionId
        self.topic = topic
    }
}

/// 持有已编码的不可变字符串，每次尝试发送前先释放队列配额。
@MainActor final class BridgeOutboundFlow {
    private struct Frame {
        let text: String, bytes: Int, control: Bool, event: Bool, enqueued: Double
        let metadata: BridgeOutboundMetadata
        let afterEmit: (@MainActor () -> Void)?
    }
    private final class Queue {
        weak var connection: BridgeConnection?
        var data: [Frame] = [], control: [Frame] = [], dataBytes = 0, controlBytes = 0,
            controlsServed = 0
        init(_ connection: BridgeConnection) { self.connection = connection }
        var empty: Bool { data.isEmpty && control.isEmpty }
    }
    private let limits: BridgeFlowLimits, diagnostics: BridgeDiagnostics
    private var queues: [ObjectIdentifier: Queue] = [:], ready: [ObjectIdentifier] = []
    private var dataCount = 0, dataBytes = 0, controlCount = 0, controlBytes = 0, pumping = false,
        scheduled = false
    init(limits: BridgeFlowLimits, diagnostics: BridgeDiagnostics) {
        self.limits = limits
        self.diagnostics = diagnostics
    }
    func submit(
        _ c: BridgeConnection, text: String, control: Bool = false, event: Bool = false,
        metadata: BridgeOutboundMetadata = BridgeOutboundMetadata(),
        afterEmit: (@MainActor () -> Void)? = nil
    ) {
        guard !c.isClosed else { return }
        let key = ObjectIdentifier(c)
        let q = queues[key] ?? Queue(c)
        let bytes = text.utf8.count
        let fits =
            control
            ? (q.control.count < limits.controlMessages
                && bytes <= limits.controlBytes - q.controlBytes
                && controlCount < limits.globalControlMessages
                && bytes <= limits.globalControlBytes - controlBytes)
            : (q.data.count < limits.dataMessages && bytes <= limits.dataBytes - q.dataBytes
                && dataCount < limits.globalDataMessages
                && bytes <= limits.globalDataBytes - dataBytes)
        guard fits else {
            c.failBackpressure()
            return
        }
        if q.empty { ready.append(key) }
        queues[key] = q
        let frame = Frame(
            text: text, bytes: bytes, control: control, event: event, enqueued: diagnostics.now(),
            metadata: metadata, afterEmit: afterEmit)
        if control {
            q.control.append(frame)
            q.controlBytes += bytes
            controlCount += 1
            controlBytes += bytes
            diagnostics.change(.pendingControl, 1)
        } else {
            q.data.append(frame)
            q.dataBytes += bytes
            dataCount += 1
            dataBytes += bytes
        }
        diagnostics.change(.queuedMessages, 1)
        diagnostics.change(.queuedBytes, bytes)
        diagnostics.record(
            event ? .eventEnqueue : .responseEnqueue, connection: c,
            callbackId: metadata.callbackId, subscriptionId: metadata.subscriptionId,
            topic: metadata.topic)
        if !pumping && !scheduled { drain() }
    }
    func remove(_ c: BridgeConnection) {
        let key = ObjectIdentifier(c)
        guard let q = queues.removeValue(forKey: key) else { return }
        ready.removeAll { $0 == key }
        for f in q.control + q.data { release(f) }
    }
    private func release(_ f: Frame) {
        if f.control {
            controlCount -= 1
            controlBytes -= f.bytes
            diagnostics.change(.pendingControl, -1)
        } else {
            dataCount -= 1
            dataBytes -= f.bytes
        }
        diagnostics.change(.queuedMessages, -1)
        diagnostics.change(.queuedBytes, -f.bytes)
    }
    private func drain() {
        guard !pumping else { return }
        pumping = true
        var emitted = 0
        while emitted < limits.batchSize, !ready.isEmpty {
            let key = ready.removeFirst()
            guard let q = queues[key] else { continue }
            guard let c = q.connection, !c.isClosed else {
                queues.removeValue(forKey: key)
                for f in q.control + q.data { release(f) }
                continue
            }
            let f: Frame
            if !q.control.isEmpty && (q.controlsServed < 4 || q.data.isEmpty) {
                f = q.control.removeFirst()
                q.controlBytes -= f.bytes
                q.controlsServed += 1
            } else {
                f = q.data.removeFirst()
                q.dataBytes -= f.bytes
                q.controlsServed = 0
            }
            if q.empty { queues.removeValue(forKey: key) } else { ready.append(key) }
            release(f)
            emitted += 1
            diagnostics.observe(.queue, since: f.enqueued)
            diagnostics.record(
                f.event ? .eventEmit : .responseEmit, connection: c,
                callbackId: f.metadata.callbackId, subscriptionId: f.metadata.subscriptionId,
                topic: f.metadata.topic)
            guard !c.isClosed else { continue }  // 可选诊断监听器可能同步关闭连接。
            c.emit(f.text)
            // 当前订阅的确认回包返回后，才能激活初始快照。
            if !c.isClosed { f.afterEmit?() }
        }
        pumping = false
        guard !ready.isEmpty, !scheduled else { return }
        scheduled = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.scheduled = false
            self.drain()
        }
    }
}
