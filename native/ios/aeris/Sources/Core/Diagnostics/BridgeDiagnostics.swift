import Foundation

public enum BridgeDiagnosticStage: String, Sendable {
    case connectionOpen = "connection.open"
    case requestReceive = "request.receive"
    case requestReject = "request.reject"
    case dispatch
    case responseEncode = "response.encode"
    case responseEnqueue = "response.enqueue"
    case responseEmit = "response.emit"
    case requestEnd = "request.end"
    case requestCancel = "request.cancel"
    case requestTimeout = "request.timeout"
    case providerPublish = "provider.publish"
    case providerReject = "provider.reject"
    case eventEnqueue = "event.enqueue"
    case eventEmit = "event.emit"
    case connectionClose = "connection.close"
    case backpressure
    case cancelHandler = "cancel.handler"
    case cleanupStart = "cleanup.start"
    case cleanupEnd = "cleanup.end"
    case cleanupCancel = "cleanup.cancel"
}
public enum BridgeDiagnosticGauge: String, Sendable, CaseIterable {
    case queuedMessages, queuedBytes, activeSessions, activeCalls, subscriptions, connections,
        pendingBusiness, pendingControl
}
public enum BridgeDiagnosticLatency: String, Sendable { case request, queue, cleanup }
public struct BridgeLatencySummary: Sendable {
    public internal(set) var count = 0
    public internal(set) var sumMs: Double = 0, maxMs: Double = 0
    /// 耗时分桶上限依次为 1、5、10、50、100、500、1000、5000 毫秒，最后为溢出桶。
    public internal(set) var buckets = Array(repeating: 0, count: 9)
}
public struct BridgeDiagnosticRecord: Sendable {
    public let elapsedMs: Double, stage: BridgeDiagnosticStage
    public let endpointId: String?, callbackId: String?, subscriptionId: String?, method: String?,
        topic: String?, code: String?
    public let source: Int?
}
public struct BridgeDiagnosticsSnapshot: Sendable {
    public let counters: [String: Int], gauges: [String: Int], peaks: [String: Int]
    public let latency: [String: BridgeLatencySummary], records: [BridgeDiagnosticRecord]
}

/// 使用固定指标键和经过脱敏的结构化元数据，不提供载荷或异常详情接口。
@MainActor public final class BridgeDiagnostics {
    private let capacity: Int, clock: @MainActor () -> Double
    private var observer: (@MainActor (BridgeDiagnosticRecord) throws -> Void)?
    private let origin: Double
    private var lastTime: Double = 0, notifying = false
    private var counts: [String: Int] = [:], gauges: [String: Int] = [:], peaks: [String: Int] = [:]
    private var latency: [String: BridgeLatencySummary] = [:],
        records: [BridgeDiagnosticRecord] = []
    public init(
        capacity: Int = 128,
        clock: @escaping @MainActor () -> Double = { ProcessInfo.processInfo.systemUptime },
        observer: (@MainActor (BridgeDiagnosticRecord) throws -> Void)? = nil
    ) {
        self.capacity = min(1024, max(0, capacity))
        self.clock = clock
        self.observer = observer
        origin = clock()
        gauges = Dictionary(
            uniqueKeysWithValues: BridgeDiagnosticGauge.allCases.map { ($0.rawValue, 0) })
        peaks = gauges
    }
    /// 为已有 Engine 安装或移除 App 采集器，也支持 BridgeEngine.shared。
    /// 保留历史记录及当前队列和 Session 计数，替换从下一次通知起生效。
    public func setObserver(_ observer: (@MainActor (BridgeDiagnosticRecord) throws -> Void)?) {
        self.observer = observer
    }
    public func snapshot() -> BridgeDiagnosticsSnapshot {
        BridgeDiagnosticsSnapshot(
            counters: counts, gauges: gauges, peaks: peaks, latency: latency, records: records)
    }
    /// 重置历史数据，同时保留共享 Engine 各队列的当前计数。
    public func reset() {
        counts = [:]
        records = []
        latency = [:]
        peaks = gauges
    }
    func now() -> Double {
        let value = max(lastTime, max(0, (clock() - origin) * 1000))
        lastTime = value
        return value
    }
    func change(_ key: BridgeDiagnosticGauge, _ delta: Int) {
        let k = key.rawValue
        gauges[k, default: 0] += delta
        peaks[k] = max(peaks[k, default: 0], gauges[k, default: 0])
    }
    func observe(_ key: BridgeDiagnosticLatency, since: Double) {
        let value = max(0, now() - since)
        let k = key.rawValue
        var summary = latency[k] ?? BridgeLatencySummary()
        summary.count += 1
        summary.sumMs += value
        summary.maxMs = max(summary.maxMs, value)
        let bounds: [Double] = [1, 5, 10, 50, 100, 500, 1000, 5000]
        summary.buckets[bounds.firstIndex(where: { value <= $0 }) ?? 8] += 1
        latency[k] = summary
    }
    static func safeID(_ id: String?) -> String? {
        guard let id, BridgeConnection.prefix(of: id) != nil else { return nil }
        return id
    }
    static func safeEndpoint(_ id: String?) -> String? {
        guard let id, id.utf8.count <= 64, UUID(uuidString: id) != nil else { return nil }
        return id
    }
    static func safeCode(_ code: String?) -> String? {
        guard let code else { return nil }
        let known: Set<String> = [
            "BACKPRESSURE", "DISCONNECTED", "CLOSED", "CANCELLED", "TIMEOUT", "INVALID_ARGUMENT",
            "INVALID_METHOD", "PAYLOAD_TOO_LARGE", "INTERNAL_ERROR", "PROTOCOL_ERROR",
            "INVALID_EVENT", "METHOD_NOT_FOUND", "PERMISSION_DENIED", "TOO_MANY_REQUESTS",
            "TOO_MANY_SUBSCRIPTIONS", "DUPLICATE_SUBSCRIPTION", "EVENT_NOT_FOUND",
            "EVENT_UNAVAILABLE", "UI_UNAVAILABLE", "BUSY", "CAMERA_UNAVAILABLE",
            "PHOTO_ENCODING_FAILED", "PHOTO_WRITE_FAILED",
        ]
        return known.contains(code) ? code : "OTHER"
    }
    func record(
        _ stage: BridgeDiagnosticStage, connection: BridgeConnection? = nil,
        callbackId: String? = nil, subscriptionId: String? = nil, method: String? = nil,
        topic: String? = nil, code: String? = nil
    ) {
        counts[stage.rawValue, default: 0] += 1
        let record = BridgeDiagnosticRecord(
            elapsedMs: now(), stage: stage, endpointId: Self.safeEndpoint(connection?.endpointId),
            callbackId: Self.safeID(callbackId), subscriptionId: Self.safeID(subscriptionId),
            method: method.flatMap { BridgePayloadValidator.method($0) ? $0 : nil },
            topic: topic.flatMap { BridgeEventTopic.isValid($0) ? $0 : nil },
            code: Self.safeCode(code), source: connection?.source)
        if capacity > 0 {
            if records.count == capacity { records.removeFirst() }
            records.append(record)
        }
        guard let observer, !notifying else { return }
        notifying = true
        defer { notifying = false }
        do { try observer(record) } catch { counts["observer.error", default: 0] += 1 }
    }
}

/// 仅保存不可变的操作标识和诊断对象，不持有 Session、Connection 或界面所有者。
@MainActor public final class BridgeOperationTrace {
    private let diagnostics: BridgeDiagnostics
    public let endpointId: String, callbackId: String?, method: String?, source: Int
    private var began: Double?, ended = false
    init(
        diagnostics: BridgeDiagnostics, connection: BridgeConnection, callbackId: String?,
        method: String?
    ) {
        self.diagnostics = diagnostics
        endpointId = connection.endpointId
        self.callbackId = BridgeDiagnostics.safeID(callbackId)
        self.method = method.flatMap { BridgePayloadValidator.method($0) ? $0 : nil }
        source = connection.source
    }
    /// 交互转场被取消时界面尚未清理，后续真正关闭时重新计时。
    public func cleanupCancelled() {
        guard began != nil, !ended else { return }
        began = nil
        diagnostics.trace(.cleanupCancel, self)
    }
    public func cleanupStarted() {
        guard began == nil, !ended else { return }
        began = diagnostics.now()
        diagnostics.trace(.cleanupStart, self)
    }
    public func cleanupEnded() {
        guard let began, !ended else { return }
        ended = true
        diagnostics.trace(.cleanupEnd, self)
        diagnostics.observe(.cleanup, since: began)
    }
}
private extension BridgeDiagnostics {
    func trace(_ stage: BridgeDiagnosticStage, _ trace: BridgeOperationTrace) {
        counts[stage.rawValue, default: 0] += 1
        let record = BridgeDiagnosticRecord(
            elapsedMs: now(), stage: stage, endpointId: trace.endpointId,
            callbackId: trace.callbackId, subscriptionId: nil, method: trace.method, topic: nil,
            code: nil, source: trace.source)
        if capacity > 0 {
            if records.count == capacity { records.removeFirst() }
            records.append(record)
        }
        guard let observer, !notifying else { return }
        notifying = true
        defer { notifying = false }
        do { try observer(record) } catch { counts["observer.error", default: 0] += 1 }
    }
}
