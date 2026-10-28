import Foundation

public struct BridgeMessage { public let fields: [String: Any] }
public enum BridgeSessionState: String {
    case received, running, finished, cancelled, timedOut, closed
}

/// Transport 创建、Engine 准备并传给业务 @objc 方法的始终是同一个对象。
@MainActor @objc(AerisBridgeSession) public final class BridgeSession: NSObject {
    public let message: BridgeMessage
    /// 入站时绑定一次，后续 Connection 更新无法改变本次请求的目标。
    public let uiContext: BridgeUIContext?
    public let connection: BridgeConnection
    /// 可信来源取自原生 Transport 的连接，不读取 message.fields。
    @objc public let source: Int
    @objc public let callbackId: String?
    @objc public let method: String?
    @objc public private(set) var moduleName: String?
    @objc public private(set) var methodName: String?
    /// 调用方可选的透传元数据，不解释为路由或权限。
    @objc public let extra: String?
    @objc public let params: [String: Any]?
    public private(set) var state: BridgeSessionState = .received
    public private(set) var deadlineUptime: TimeInterval?
    private var replyCallback: ((BridgePreparedResponse) -> Void)?
    private var responseEncoder: BridgeResponseEncoder?
    private var sequence = 0
    private var startedAt: Double?
    public var operationTrace: BridgeOperationTrace {
        BridgeOperationTrace(
            diagnostics: connection.diagnostics, connection: connection, callbackId: callbackId,
            method: method)
    }
    private var cancellation: (() -> Void)?
    private var deadlineTask: Task<Void, Never>?
    public var onCancel: (() -> Void)? {
        get { cancellation }
        set { if state == .running { cancellation = newValue } }
    }
    public init(message: BridgeMessage, connection: BridgeConnection) {
        self.message = message
        self.connection = connection
        uiContext = connection.uiContext
        source = connection.source
        callbackId = message.fields["callbackId"] as? String
        method = message.fields["method"] as? String
        params = message.fields["params"] as? [String: Any]
        extra = message.fields["extra"] as? String
        super.init()
    }
    func start(
        canonical: String, timeoutMs: Int, encoder: BridgeResponseEncoder,
        reply: @escaping (BridgePreparedResponse) -> Void
    ) {
        precondition(state == .received)
        let names = canonical.split(separator: ".", maxSplits: 1).map(String.init)
        moduleName = names[0]
        methodName = names[1]
        startedAt = connection.diagnostics.now()
        state = .running
        replyCallback = reply
        responseEncoder = encoder
        deadlineUptime = ProcessInfo.processInfo.systemUptime + Double(timeoutMs) / 1000
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            self?.terminate(
                .failure(BridgeFailure("TIMEOUT", "Native deadline exceeded")), as: .timedOut,
                cancel: true, notify: true)
        }
    }
    /// 保留既有业务接口的一次返回并结束行为。
    @objc public func callback(_ result: [String: Any]) { complete(.success(result)) }
    /// 发送过程数据，是否发送及发送频率由原生业务决定。
    @objc public func emit(_ result: [String: Any]) {
        guard state == .running else { return }
        guard let prepared = prepare(.success(result), finished: false) else { return }
        if prepared.finished {
            finish(prepared, as: .finished, cancel: true)
            return
        }
        stopDeadline()  // 启动阶段已结束，用户输入期间没有新消息不视为超时。
        sequence += 1
        replyCallback?(prepared)  // 发送器可能同步取消或关闭当前 Session，发送后不再修改状态。
    }
    @objc public func fail(_ code: String, message: String) {
        complete(.failure(BridgeFailure(code, message)))
    }
    public func complete(_ result: Result<[String: Any], BridgeFailure>) {
        terminate(result, as: .finished, cancel: false, notify: true)
    }
    // 请求取消的共用入口，UIKit 相关清理由绑定的 onCancel 执行。
    // 发送结束响应或移出活跃表，不代表原生界面资源已经释放。
    func cancel() {
        terminate(
            .failure(BridgeFailure("CANCELLED", "Request cancelled")), as: .cancelled, cancel: true,
            notify: true)
    }
    func close() {
        terminate(
            .failure(BridgeFailure("CLOSED", "Connection closed")), as: .closed, cancel: true,
            notify: false)
    }
    private func stopDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
        deadlineUptime = nil
    }
    private func prepare(_ result: Result<[String: Any], BridgeFailure>, finished: Bool)
        -> BridgePreparedResponse?
    {
        guard state == .running, let encoder = responseEncoder else { return nil }
        let output: Result<[String: Any], BridgeFailure> =
            sequence < 9_007_199_254_740_990
            ? result : .failure(BridgeFailure("PROTOCOL_ERROR", "Response sequence exhausted"))
        do {
            connection.diagnostics.record(
                .responseEncode, connection: connection, callbackId: callbackId, method: method)
            guard state == .running, !connection.isClosed else { return nil }
            return try encoder.prepare(
                callbackId: callbackId ?? "", seq: sequence + 1,
                finished: sequence < 9_007_199_254_740_990 ? finished : true, extra: extra,
                result: output)
        } catch {
            // 有界的兜底回包也无法编码时，关闭所属连接并清理全部操作。
            connection.failBackpressure()
            return nil
        }
    }
    private func finish(
        _ prepared: BridgePreparedResponse?, as terminal: BridgeSessionState, cancel: Bool
    ) {
        guard state == .running else { return }
        state = terminal
        connection.diagnostics.record(
            .requestEnd, connection: connection, callbackId: callbackId, method: method)
        if terminal == .cancelled || terminal == .timedOut {
            connection.diagnostics.record(
                terminal == .cancelled ? .requestCancel : .requestTimeout, connection: connection,
                callbackId: callbackId, method: method)
        }
        if let startedAt {
            connection.diagnostics.observe(.request, since: startedAt)
            self.startedAt = nil
        }
        let reply = replyCallback
        replyCallback = nil
        responseEncoder = nil
        let cancelHandler = cancellation
        cancellation = nil
        stopDeadline()
        sequence += 1
        if let prepared { reply?(prepared) }  // 先移出活跃表，再调用可能触发回调的底层取消逻辑。
        if cancel || prepared?.requiresCleanup == true {
            if cancelHandler != nil {
                connection.diagnostics.record(
                    .cancelHandler, connection: connection, callbackId: callbackId, method: method)
            }
            cancelHandler?()
        }  // 界面在 dismiss 完成后释放租约。
    }
    private func terminate(
        _ result: Result<[String: Any], BridgeFailure>, as terminal: BridgeSessionState,
        cancel: Bool, notify: Bool
    ) {
        guard state == .running else { return }
        if !notify {
            finish(nil, as: terminal, cancel: cancel)
            return
        }
        guard let prepared = prepare(result, finished: true) else { return }
        finish(prepared, as: terminal, cancel: cancel)
    }
}
