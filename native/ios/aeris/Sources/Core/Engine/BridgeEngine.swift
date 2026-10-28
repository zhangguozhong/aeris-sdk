import Foundation

@MainActor public final class BridgeEngine {
    /// App 组装入口使用进程内共享实例，并且只注册一次模块。
    /// Transport 仍显式注入 Engine，各容器的连接始终独立。
    public static let shared = BridgeEngine()
    // Provider 回调仅接收数据接收器，Engine 仍是统一发布入口。
    // 延迟组装允许弱引用 self，避免 Engine 与 Hub 循环持有。
    private lazy var events = BridgeEventHub(publishToEngine: { [weak self] topic, data, context in
        _ = self?.publish(topic: topic, data: data, uiContext: context)
    })
    private let registry: BridgeRegistry
    private var hasCreatedConnection = false
    public var defaultModuleName: String { registry.defaultModuleName }
    /// 仅允许宿主启动时配置，关闭连接不会解除 Engine 的配置锁定。
    public func configureDefaultModule(_ name: String) throws {
        guard !hasCreatedConnection else {
            throw BridgeFailure("CONFIGURATION_LOCKED", "Configure before creating any connection")
        }
        try registry.configureDefaultModule(name)
    }
    /// 为测试和独立协议工具创建隔离的 Registry。
    public let diagnostics: BridgeDiagnostics
    private let flowLimits: BridgeFlowLimits
    private lazy var outbound = BridgeOutboundFlow(limits: flowLimits, diagnostics: diagnostics)
    public convenience init(
        flowLimits: BridgeFlowLimits = BridgeFlowLimits(), diagnostics: BridgeDiagnostics? = nil
    ) {
        self.init(
            responseEncoder: BridgeResponseEncoder(), flowLimits: flowLimits,
            diagnostics: diagnostics)
    }
    private let responseEncoder: BridgeResponseEncoder
    init(
        responseEncoder: BridgeResponseEncoder, flowLimits: BridgeFlowLimits = BridgeFlowLimits(),
        diagnostics: BridgeDiagnostics? = nil
    ) {
        registry = BridgeRegistry()
        self.responseEncoder = responseEncoder
        self.flowLimits = flowLimits
        self.diagnostics = diagnostics ?? BridgeDiagnostics()
    }
    /// 每次调用均创建全新且独立持有的容器连接。
    public func makeConnection(
        source: BridgeSource = .unknown, uiContext: BridgeUIContext? = nil,
        allowedPermissions: Set<String> = [], allowedEventTopics: Set<String>? = nil,
        emit: @escaping @MainActor (String) -> Void
    ) -> BridgeConnection {
        hasCreatedConnection = true
        let connection = BridgeConnection(
            diagnostics: diagnostics, source: source, allowedPermissions: allowedPermissions,
            uiContext: uiContext, allowedEventTopics: allowedEventTopics, emit: emit)
        connection.enqueue = {
            [weak self, weak connection] text, control, event, metadata, afterEmit in
            guard let self, let connection else { return }
            self.outbound.submit(
                connection, text: text, control: control, event: event, metadata: metadata,
                afterEmit: afterEmit)
        }
        connection.discardOutbound = { [weak self, weak connection] in
            if let connection { self?.outbound.remove(connection) }
        }
        connection.onClose = { [weak self, weak connection] in
            if let connection { self?.events.detach(connection) }
        }
        diagnostics.change(.connections, 1)
        diagnostics.record(.connectionOpen, connection: connection)
        return connection
    }
    public func register(module: any BridgeModule) throws { try registry.register(module) }
    /// 声明业务通知，也可以为 topic 绑定可选的快照数据源。
    public func registerEvent(
        topic: String, provider: (any BridgeEventProvider)? = nil,
        scope: BridgeEventScope = .global, delivery: BridgeEventDelivery? = nil
    ) throws {
        try events.register(topic: topic, provider: provider, scope: scope, delivery: delivery)
    }
    /// 为已有原生监听保留兼容入口，仍使用同一个 topic 注册表。
    public func registerEventProvider(
        topic: String, provider: any BridgeEventProvider, scope: BridgeEventScope = .global,
        delivery: BridgeEventDelivery? = nil
    ) throws {
        try registerEvent(topic: topic, provider: provider, scope: scope, delivery: delivery)
    }
    /// 所有原生状态变化都从这里发布，包括系统 Provider 的更新。
    @discardableResult public func publish(
        topic: String, data: [String: Any], uiContext: BridgeUIContext? = nil
    ) -> Bool {
        let accepted = events.distribute(topic: topic, data: data, context: uiContext)
        diagnostics.record(accepted ? .providerPublish : .providerReject, topic: topic)
        return accepted
    }
    public func handle(_ input: BridgeSession) {
        let c = input.connection
        let m = input.message.fields
        func respond(
            _ id: String, in connection: BridgeConnection,
            result: Result<[String: Any], BridgeFailure>, extra: String? = nil, seq: Int = 1,
            finished: Bool? = nil
        ) {
            self.respond(
                id, in: connection, result: result, extra: extra, seq: seq,
                finished: finished ?? true, control: input.method?.hasPrefix("bridge.") == true)
        }
        guard !c.isClosed, input.state == .received else { return }
        guard let callbackId = input.callbackId,
            let prefix = BridgeConnection.prefix(of: callbackId)
        else { return }
        let raw = input.method ?? ""
        if raw == "bridge.hello" {
            guard c.clientPrefix == nil else { return }  // 重复 hello 不得重置活跃客户端。
        } else {
            guard c.accepts(callbackId) else { return }
        }
        if c.active[callbackId] != nil || c.completedIDs.contains(callbackId)
            || c.receivingIDs.contains(callbackId)
        {
            return
        }
        // 先预留入站标识，再调用可选的 App 监听器；监听器可能重入 handle。
        c.receivingIDs.insert(callbackId)
        defer { c.receivingIDs.remove(callbackId) }
        diagnostics.record(.requestReceive, connection: c, callbackId: callbackId, method: raw)
        guard !c.isClosed, input.state == .received else { return }
        if raw == "bridge.hello" {
            guard c.clientPrefix == nil else { return }
        } else {
            guard c.accepts(callbackId) else { return }
        }
        if let error = BridgePayloadValidator.request(m) {
            diagnostics.record(
                .requestReject, connection: c, callbackId: callbackId, method: raw, code: error.code
            )
            let safeExtra = input.extra.flatMap { BridgeCodec.extraFitsResponse($0) ? $0 : nil }
            respond(callbackId, in: c, result: .failure(error), extra: safeExtra)
            return
        }
        guard let params = input.params else { return }  // 共用语义校验器已在前面确认参数为对象。
        if c.isClosing {
            switch raw {
            case "bridge.cancel", "bridge.unsubscribe", "bridge.close": break
            default:
                respond(
                    callbackId, in: c,
                    result: .failure(BridgeFailure("BRIDGE_CLOSING", "Connection is closing")),
                    extra: input.extra)
                return
            }
        }
        if raw == "bridge.hello" {
            c.clientPrefix = prefix
            respond(
                callbackId, in: c,
                result: .success([
                    "ready": true, "features": ["events"],
                    "defaultModule": registry.defaultModuleName,
                    "capabilityRevision": "registry-\(registry.revision)",
                    "limits": ["maxMessageBytes": 256 * 1024],
                ]), extra: input.extra)
            return
        }
        if raw == "bridge.close" {
            c.close()
            return
        }
        if raw == "bridge.cancel" {
            guard let target = params["targetCallbackId"] as? String, c.accepts(target) else {
                respond(
                    callbackId, in: c,
                    result: .failure(
                        BridgeFailure("INVALID_ARGUMENT", "Expected params.targetCallbackId")),
                    extra: input.extra)
                return
            }
            let session = c.accepts(target) ? c.active[target] : nil
            session?.cancel()
            // accepted 只确认已受理取消目标请求，不代表异步界面清理完成。
            // 操作必须保留资源租约，直到自身 dismiss 完成。
            respond(
                callbackId, in: c, result: .success(["accepted": session != nil]),
                extra: input.extra)
            return
        }
        if raw == "bridge.subscribe" {
            do {
                let id = try events.subscribe(c, params: params)
                let activate = events.activation(c, id: id)
                self.respond(
                    callbackId, in: c, result: .success(["subscriptionId": id]), extra: input.extra,
                    control: true, afterEmit: activate)
            } catch let e as BridgeFailure {
                respond(callbackId, in: c, result: .failure(e), extra: input.extra)
            } catch {
                respond(
                    callbackId, in: c,
                    result: .failure(BridgeFailure("INTERNAL_ERROR", "Subscription failed")),
                    extra: input.extra)
            }
            return
        }
        if raw == "bridge.unsubscribe" {
            guard let id = params["subscriptionId"] as? String, c.accepts(id) else {
                respond(
                    callbackId, in: c,
                    result: .failure(BridgeFailure("INVALID_ARGUMENT", "Expected subscriptionId")),
                    extra: input.extra)
                return
            }
            respond(
                callbackId, in: c, result: .success(["accepted": events.unsubscribe(c, id: id)]),
                extra: input.extra)
            return
        }
        if raw.hasPrefix("bridge.") {
            respond(
                callbackId, in: c,
                result: .failure(BridgeFailure("METHOD_NOT_FOUND", "Unknown system method")),
                extra: input.extra)
            return
        }
        guard c.active.count < 128 else {
            respond(
                callbackId, in: c,
                result: .failure(BridgeFailure("TOO_MANY_REQUESTS", "Pending limit reached")),
                extra: input.extra)
            return
        }
        do {
            let (canonical, method) = try registry.resolve(raw)
            guard method.permissions.isSubset(of: c.allowedPermissions) else {
                throw BridgeFailure("PERMISSION_DENIED", "Host policy denied module permissions")
            }
            let budget = m["timeoutMs"].flatMap(BridgePayloadValidator.integer) ?? 120000
            c.active[callbackId] = input
            c.started(input)
            input.start(canonical: canonical, timeoutMs: budget, encoder: responseEncoder) {
                [weak c, weak input] prepared in
                guard let c, let input, c.active[callbackId] === input else { return }
                if prepared.finished {
                    c.active.removeValue(forKey: callbackId)
                    c.ended(input)
                    c.completedIDs.append(callbackId)
                    if c.completedIDs.count > 1024 { c.completedIDs.removeFirst() }
                }
                c.send(prepared)
            }
            // 分发监听器看到的是已完整托管的运行中 Session，关闭或取消时可将其移除。
            diagnostics.record(.dispatch, connection: c, callbackId: callbackId, method: canonical)
            guard !c.isClosed, input.state == .running, c.active[callbackId] === input else {
                return
            }
            method.invoke(input)  // 传递平台 Transport 创建的同一个对象。
        } catch let e as BridgeFailure {
            respond(callbackId, in: c, result: .failure(e), extra: input.extra)
        } catch {
            respond(
                callbackId, in: c,
                result: .failure(BridgeFailure("INTERNAL_ERROR", "Native execution failed")),
                extra: input.extra)
        }
    }
    private func respond(
        _ callbackId: String, in c: BridgeConnection, result: Result<[String: Any], BridgeFailure>,
        extra: String? = nil, seq: Int = 1, finished: Bool? = nil, control: Bool = false,
        afterEmit: (@MainActor () -> Void)? = nil
    ) {
        guard !c.isClosed else { return }
        do {
            diagnostics.record(.responseEncode, connection: c, callbackId: callbackId)
            guard !c.isClosed else { return }
            c.send(
                try responseEncoder.prepare(
                    callbackId: callbackId, seq: seq, finished: finished, extra: extra,
                    result: result), control: control, afterEmit: afterEmit)
        } catch { c.failBackpressure() }
    }

}
