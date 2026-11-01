package com.aeris.sdk

import java.util.UUID

/** 一个可信原生端点；callbackId 和 subscriptionId 的表始终从属于当前对象。 */
class BridgeConnection
internal constructor(
    internal val engine: BridgeEngine,
    val source: Int,
    val uiContext: BridgeUIContext?,
    internal val permissions: Set<String>,
    internal val allowedTopics: Set<String>?,
    internal val emit: (String) -> Unit,
) {
    val diagnostics
        get() = engine.diagnostics

    val endpointId = UUID.randomUUID().toString()
    var isClosed = false
        private set

    var isClosing = false
        private set

    @Volatile
    internal var isNotifyingClose = false
        private set

    internal var clientPrefix: String? = null
    internal val active = mutableMapOf<String, BridgeSession>()
    internal val completed = LinkedHashSet<String>()
    internal val receiving = mutableSetOf<String>()
    internal val subscriptions = mutableMapOf<String, BridgeSubscription>()
    private var terminalError: BridgeFailure? = null
    private val closeObservers = mutableSetOf<(BridgeFailure?) -> Unit>()

    /** 在 Engine dispatcher 上注册及取消；迟到观察者立即收到最终关闭原因。 */
    fun observeClosed(listener: (BridgeFailure?) -> Unit): BridgeCancellation {
        engine.dispatcher.checkThread()
        if (isClosed) {
            listener(terminalError)
            return BridgeCancellation {}
        }
        closeObservers.add(listener)
        return BridgeCancellation { closeObservers.remove(listener) }
    }

    var onClosed: ((BridgeFailure?) -> Unit)? = null

    internal fun accepts(id: String) =
        clientPrefix != null && BridgeCodec.prefix(id) == clientPrefix

    fun beginClosing() {
        engine.dispatcher.checkThread()
        if (!isClosed) isClosing = true
    }

    internal fun remember(id: String) {
        completed.add(id)
        if (completed.size > 1024) completed.remove(completed.first())
    }

    internal fun send(
        prepared: BridgePreparedResponse,
        control: Boolean = false,
        afterEmit: (() -> Unit)? = null,
    ) {
        engine.outbound.submit(
            this,
            prepared.text,
            control,
            afterEmit = afterEmit,
            callbackId = prepared.callbackId,
        )
    }

    internal fun sendEvent(fields: com.google.gson.JsonObject, id: String, topic: String? = null) {
        try {
            engine.outbound.submit(this, BridgeCodec.encode(fields), false, id, topic = topic)
        } catch (e: Exception) {
            fail("BACKPRESSURE", "事件超过消息边界")
        }
    }

    fun close() {
        engine.dispatcher.checkThread()
        seal(null, false)
    }

    internal fun fail(code: String, reason: String) = seal(BridgeFailure(code, reason), true)

    private fun seal(error: BridgeFailure?, notify: Boolean) {
        if (isClosed) return
        isNotifyingClose = true
        try {
            // 先封闭和摘表，再运行可能同步回调的发送器、Provider 或业务取消函数。
            isClosed = true
            terminalError = error
            isClosing = true
            engine.outbound.remove(this)
            val sessions = active.values.toList()
            active.clear()
            sessions.forEach { it.releaseMetrics() }
            receiving.clear()
            completed.clear()
            engine.detach(this)
            diagnostics.change(BridgeDiagnosticGauge.CONNECTIONS, -1)
            if (error?.code == "BACKPRESSURE")
                diagnostics.record(BridgeDiagnosticStage.BACKPRESSURE, this, code = error.code)
            diagnostics.record(BridgeDiagnosticStage.CONNECTION_CLOSE, this, code = error?.code)
            val observers = closeObservers.toList()
            closeObservers.clear()
            val closed = onClosed
            onClosed = null
            if (notify && error != null) {
                runCatching {
                    emit(
                        BridgeCodec.encode(
                            jsonObject(
                                "method" to "bridge.close",
                                "params" to
                                    jsonObject("code" to error.code, "reason" to error.message),
                            )
                        )
                    )
                }
            }
            engine.events.detach(this)
            sessions.forEach { it.closeInternal() }
            runCatching { closed?.invoke(error) }
            observers.forEach { observer -> runCatching { observer(error) } }
        } finally {
            isNotifyingClose = false
        }
    }
}
