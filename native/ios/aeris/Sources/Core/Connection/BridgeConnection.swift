import Foundation

/// 可信原生端点，关联表通过当前对象和 callbackId 共同隔离。
@MainActor public final class BridgeConnection {
    public private(set) var uiContext: BridgeUIContext?
    public func updateUIContext(_ context: BridgeUIContext?) { uiContext = context }
    public let diagnostics: BridgeDiagnostics
    var enqueue: ((String, Bool, Bool, BridgeOutboundMetadata, (@MainActor () -> Void)?) -> Void)?
    var discardOutbound: (() -> Void)?
    public let source: Int
    public let endpointId = UUID().uuidString
    let emit: @MainActor (String) -> Void
    let allowedPermissions: Set<String>
    /// nil 允许订阅任意已注册 topic，空集合则拒绝全部事件。
    let allowedEventTopics: Set<String>?
    var eventSubscriptionIDs: Set<String> = []
    var onClose: (() -> Void)?
    var clientPrefix: String?
    var active: [String: BridgeSession] = [:]
    var receivingIDs: Set<String> = []
    var completedIDs: [String] = []
    public private(set) var isClosed = false
    public private(set) var isClosing = false

    /// 仅封闭新业务；既有请求和订阅由控制消息或最终 close 完成清理。
    public func beginClosing() {
        guard !isClosed else { return }
        isClosing = true
    }
    init(
        diagnostics: BridgeDiagnostics, source: BridgeSource, allowedPermissions: Set<String>,
        uiContext: BridgeUIContext?, allowedEventTopics: Set<String>?,
        emit: @escaping @MainActor (String) -> Void
    ) {
        self.diagnostics = diagnostics
        self.uiContext = uiContext
        self.source = source.rawValue
        self.allowedEventTopics = allowedEventTopics
        self.allowedPermissions = allowedPermissions
        self.emit = emit
    }
    static func prefix(of callbackId: String) -> String? {
        guard callbackId.utf8.count <= 256, let colon = callbackId.firstIndex(of: ":") else {
            return nil
        }
        let prefix = String(callbackId[..<colon])
        let suffix = String(callbackId[callbackId.index(after: colon)...])
        let pattern = "^[A-Za-z0-9_-]+$"
        guard !prefix.isEmpty, !suffix.isEmpty,
            prefix.range(of: pattern, options: .regularExpression) == prefix
                .startIndex..<prefix.endIndex,
            suffix.range(of: pattern, options: .regularExpression) == suffix
                .startIndex..<suffix.endIndex
        else { return nil }
        return prefix
    }
    func accepts(_ callbackId: String) -> Bool {
        clientPrefix != nil && Self.prefix(of: callbackId) == clientPrefix
    }
    func send(
        _ prepared: BridgePreparedResponse, control: Bool = false,
        afterEmit: (@MainActor () -> Void)? = nil
    ) {
        guard !isClosed else { return }
        enqueue?(
            prepared.text, control, false, BridgeOutboundMetadata(callbackId: prepared.callbackId),
            afterEmit)
    }
    func send(_ fields: [String: Any], topic: String? = nil) {
        guard !isClosed else { return }
        do {
            enqueue?(
                try BridgeCodec.encode(fields), false, true,
                BridgeOutboundMetadata(
                    subscriptionId: fields["subscriptionId"] as? String, topic: topic), nil)
        } catch { failBackpressure() }
    }
    func started(_ session: BridgeSession) {
        diagnostics.change(.activeSessions, 1)
        diagnostics.change(.pendingBusiness, 1)
        diagnostics.change(.activeCalls, 1)
    }
    func ended(_ session: BridgeSession) {
        diagnostics.change(.activeSessions, -1)
        diagnostics.change(.pendingBusiness, -1)
        diagnostics.change(.activeCalls, -1)
    }
    /// 先封闭入站并释放队列配额，再调用可能重入 close() 的紧急发送器。
    private func seal(reason: String? = nil) -> (() -> Void)? {
        guard !isClosed else { return nil }
        isClosed = true
        let sessions = Array(active.values)
        active.removeAll()
        completedIDs.removeAll()
        receivingIDs.removeAll()
        for session in sessions { ended(session) }
        discardOutbound?()
        discardOutbound = nil
        enqueue = nil
        diagnostics.change(.connections, -1)
        diagnostics.record(.connectionClose, connection: self, code: reason)
        let detached = onClose
        onClose = nil
        return { [self] in
            detached?()
            eventSubscriptionIDs.removeAll()
            for session in sessions { session.close() }
        }
    }
    func failBackpressure() {
        guard let cleanup = seal(reason: "BACKPRESSURE") else { return }
        diagnostics.record(.backpressure, connection: self, code: "BACKPRESSURE")
        defer { cleanup() }
        // 固定且有界，独立预留于已耗尽的普通及控制消息配额之外。
        emit(
            #"{"method":"bridge.close","params":{"code":"BACKPRESSURE","reason":"Native outbound queue exceeded"}}"#
        )
    }
    /// 异常断开复用既有系统通知；先封闭连接，再通知客户端，最后清理业务资源。
    func failDisconnected() {
        guard let cleanup = seal(reason: "DISCONNECTED") else { return }
        defer { cleanup() }
        emit(
            #"{"method":"bridge.close","params":{"code":"DISCONNECTED","reason":"Native transport rejected invalid input"}}"#
        )
    }
    public func close() { seal()?() }
}
