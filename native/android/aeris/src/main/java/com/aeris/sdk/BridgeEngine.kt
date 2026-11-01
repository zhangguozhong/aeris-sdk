package com.aeris.sdk

import com.google.gson.JsonArray
import com.google.gson.JsonObject

/** 宿主注入同一 Engine，各容器保持独立 Connection；模块只注册一次。 */
class BridgeEngine(
    val dispatcher: BridgeDispatcher = AndroidBridgeDispatcher(),
    private val limits: BridgeFlowLimits = BridgeFlowLimits(),
) {
    companion object {
        val shared: BridgeEngine by lazy { BridgeEngine() }
    }

    // 保留原两参数及默认参数构造ABI；新诊断入口使用独立重载。
    var diagnostics = BridgeDiagnostics()
        private set

    constructor(
        dispatcher: BridgeDispatcher = AndroidBridgeDispatcher(),
        limits: BridgeFlowLimits = BridgeFlowLimits(),
        diagnostics: BridgeDiagnostics,
    ) : this(dispatcher, limits) {
        this.diagnostics = diagnostics
    }

    private val registry = BridgeRegistry()
    internal val outbound by lazy { BridgeOutboundFlow(dispatcher, limits, diagnostics) }
    internal val events = BridgeEventHub(this)
    private val connections = mutableSetOf<BridgeConnection>()
    private var configurationLocked = false
    val defaultModuleName
        get() = registry.defaultModuleName

    val connectionCount
        get(): Int {
            dispatcher.checkThread()
            return connections.size
        }

    fun configureDefaultModule(name: String) {
        dispatcher.checkThread()
        if (configurationLocked) throw BridgeFailure("CONFIGURATION_LOCKED", "请在创建连接前配置默认模块")
        registry.configureDefaultModule(name)
    }

    fun register(module: BridgeModule) {
        dispatcher.checkThread()
        registry.register(module)
    }

    fun registerEvent(
        topic: String,
        provider: BridgeEventProvider? = null,
        scope: BridgeEventScope = BridgeEventScope.GLOBAL,
        permissions: Set<String> = emptySet(),
    ) {
        dispatcher.checkThread()
        events.register(topic, provider, scope, permissions)
    }

    /** 保留原注册签名；宿主可明确覆盖状态或业务事件的交付策略。 */
    fun registerEvent(
        topic: String,
        provider: BridgeEventProvider? = null,
        scope: BridgeEventScope = BridgeEventScope.GLOBAL,
        permissions: Set<String> = emptySet(),
        delivery: BridgeEventDelivery,
    ) {
        dispatcher.checkThread()
        events.register(topic, provider, scope, permissions, delivery)
    }

    fun publish(topic: String, data: JsonObject, uiContext: BridgeUIContext? = null): Boolean {
        dispatcher.checkThread()
        val accepted = events.publish(topic, data, uiContext)
        diagnostics.record(
            if (accepted) BridgeDiagnosticStage.PROVIDER_PUBLISH
            else BridgeDiagnosticStage.PROVIDER_REJECT,
            topic = topic,
        )
        return accepted
    }

    fun makeConnection(
        source: BridgeSource = BridgeSource.UNKNOWN,
        uiContext: BridgeUIContext? = null,
        allowedPermissions: Set<String> = emptySet(),
        allowedEventTopics: Set<String>? = null,
        emit: (String) -> Unit,
    ): BridgeConnection {
        dispatcher.checkThread()
        configurationLocked = true
        return BridgeConnection(
                this,
                source.value,
                uiContext,
                allowedPermissions.toSet(),
                allowedEventTopics?.toSet(),
                emit,
            )
            .also {
                connections.add(it)
                diagnostics.change(BridgeDiagnosticGauge.CONNECTIONS, 1)
                diagnostics.record(BridgeDiagnosticStage.CONNECTION_OPEN, connection = it)
            }
    }

    internal fun detach(connection: BridgeConnection) {
        connections.remove(connection)
    }

    fun handle(session: BridgeSession) {
        dispatcher.checkThread()
        val connection = session.connection
        if (
            connection.engine !== this ||
                connection.isClosed ||
                session.state != BridgeSessionState.RECEIVED
        )
            return
        val id = session.callbackId ?: return
        val prefix = BridgeCodec.prefix(id) ?: return
        val raw = session.method ?: ""
        if (raw == "bridge.hello") {
            if (connection.clientPrefix != null) return
        } else if (!connection.accepts(id)) return
        if (id in connection.active || id in connection.completed || !connection.receiving.add(id))
            return
        try {
            diagnostics.record(
                BridgeDiagnosticStage.REQUEST_RECEIVE,
                connection,
                callbackId = id,
                method = raw,
            )
            if (connection.isClosed) return
            BridgeCodec.validateRequest(session.message)
            if (
                connection.isClosing &&
                    raw !in setOf("bridge.cancel", "bridge.unsubscribe", "bridge.close")
            )
                throw BridgeFailure("BRIDGE_CLOSING", "连接正在关闭")
            val params = session.params
            when (raw) {
                "bridge.hello" -> {
                    connection.clientPrefix = prefix
                    val features = JsonArray().apply { add("events") }
                    respond(
                        connection,
                        id,
                        session.extra,
                        jsonObject(
                            "ready" to true,
                            "features" to features,
                            "defaultModule" to defaultModuleName,
                            "capabilityRevision" to "registry-${registry.revision}",
                            "limits" to jsonObject("maxMessageBytes" to BridgeCodec.MAX_BYTES),
                        ),
                        control = true,
                    )
                }
                "bridge.close" -> connection.close()
                "bridge.cancel" -> {
                    val target = BridgeCodec.string(params, "targetCallbackId")
                    if (
                        target == null ||
                            !connection.accepts(target) ||
                            !setOf("targetCallbackId", "reason").containsAll(params.keySet()) ||
                            (params.has("reason") && BridgeCodec.string(params, "reason") == null)
                    )
                        throw BridgeFailure(
                            "INVALID_ARGUMENT",
                            "需要有效 targetCallbackId 和可选字符串 reason",
                        )
                    val active = connection.active[target]
                    active?.cancelInternal()
                    respond(
                        connection,
                        id,
                        session.extra,
                        jsonObject("accepted" to (active != null)),
                        control = true,
                    )
                }
                "bridge.subscribe" -> {
                    val (subscription, activation) = events.subscribe(connection, params)
                    respond(
                        connection,
                        id,
                        session.extra,
                        jsonObject("subscriptionId" to subscription),
                        control = true,
                        afterEmit = activation,
                    )
                }
                "bridge.unsubscribe" -> {
                    val target = BridgeCodec.string(params, "subscriptionId")
                    if (
                        target == null ||
                            !connection.accepts(target) ||
                            params.keySet() != setOf("subscriptionId")
                    )
                        throw BridgeFailure("INVALID_ARGUMENT", "缺少有效 subscriptionId")
                    respond(
                        connection,
                        id,
                        session.extra,
                        jsonObject("accepted" to events.unsubscribe(connection, target)),
                        control = true,
                    )
                }
                else -> {
                    if (raw.startsWith("bridge.")) throw BridgeFailure("METHOD_NOT_FOUND", "未知系统方法")
                    if (connection.active.size >= limits.maxActiveRequests)
                        throw BridgeFailure("TOO_MANY_REQUESTS", "活跃业务请求超过预算")
                    val (canonical, invocation) = registry.resolve(raw)
                    if (!connection.permissions.containsAll(invocation.permissions))
                        throw BridgeFailure("PERMISSION_DENIED", "连接无权调用此方法")
                    connection.active[id] = session
                    session.start(canonical, session.message.get("timeoutMs")?.asLong ?: 120000)
                    diagnostics.record(
                        BridgeDiagnosticStage.DISPATCH,
                        connection,
                        callbackId = id,
                        method = canonical,
                    )
                    if (
                        !connection.isClosed &&
                            session.state == BridgeSessionState.RUNNING &&
                            connection.active[id] === session
                    )
                        invocation.invoke(session)
                }
            }
        } catch (failure: BridgeFailure) {
            reject(session, failure, raw)
        } catch (error: Exception) {
            reject(session, BridgeFailure("INTERNAL_ERROR", "Bridge 分发失败"), raw)
        } finally {
            connection.receiving.remove(id)
        }
    }

    private fun reject(session: BridgeSession, failure: BridgeFailure, raw: String) {
        val connection = session.connection
        diagnostics.record(
            BridgeDiagnosticStage.REQUEST_REJECT,
            connection,
            callbackId = session.callbackId,
            method = raw,
            code = failure.code,
        )
        if (connection.isClosed) return
        if (
            session.state == BridgeSessionState.RUNNING &&
                connection.active[session.callbackId] === session
        )
            session.fail(failure.code, failure.message)
        else
            session.callbackId?.let {
                respond(
                    connection,
                    it,
                    session.extra,
                    error = failure,
                    control = raw.startsWith("bridge."),
                )
            }
    }

    private fun respond(
        connection: BridgeConnection,
        id: String,
        extra: String?,
        data: JsonObject? = null,
        error: BridgeFailure? = null,
        control: Boolean,
        afterEmit: (() -> Unit)? = null,
    ) {
        connection.remember(id)
        try {
            diagnostics.record(BridgeDiagnosticStage.RESPONSE_ENCODE, connection, callbackId = id)
            if (!connection.isClosed)
                connection.send(
                    BridgeCodec.response(id, 1, true, data, error, extra),
                    control,
                    afterEmit,
                )
        } catch (e: Exception) {
            connection.fail("BACKPRESSURE", "无法编码控制回包")
        }
    }
}
