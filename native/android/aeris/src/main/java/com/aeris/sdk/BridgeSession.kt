package com.aeris.sdk

import com.google.gson.JsonObject

enum class BridgeSessionState {
    RECEIVED,
    RUNNING,
    FINISHED,
    CANCELLED,
    TIMED_OUT,
    CLOSED,
}

/** 每请求一个实例。业务可以持有 Session，不能让共享 Bridge 保存“当前请求”。 */
class BridgeSession internal constructor(message: JsonObject, val connection: BridgeConnection) {
    internal val message = message.deepCopy()
    val operationTrace
        get() = BridgeOperationTrace(connection.diagnostics, connection, callbackId, method)

    val uiContext = connection.uiContext
    val source = connection.source
    val callbackId = BridgeCodec.string(message, "callbackId")
    val method = BridgeCodec.string(message, "method")
    val params: JsonObject =
        message.get("params")?.takeIf { it.isJsonObject }?.asJsonObject?.deepCopy() ?: JsonObject()
    val extra = BridgeCodec.string(message, "extra")
    var moduleName: String? = null
        private set

    var methodName: String? = null
        private set

    var state = BridgeSessionState.RECEIVED
        private set

    private var sequence = 0L
    private var deadline: BridgeCancellation? = null
    private var cancelAction: (() -> Unit)? = null
    private var needsCancellation = false
    private var counted = false
    private var startedAt: Double? = null
    private val diagnostics
        get() = connection.diagnostics

    var onCancel: (() -> Unit)?
        get() = cancelAction
        set(value) {
            connection.engine.dispatcher.execute {
                if (needsCancellation) runCancel(value)
                else if (state == BridgeSessionState.RUNNING) cancelAction = value
            }
        }

    internal fun start(canonical: String, timeout: Long) {
        check(state == BridgeSessionState.RECEIVED)
        moduleName = canonical.substringBefore('.')
        methodName = canonical.substringAfter('.')
        state = BridgeSessionState.RUNNING
        startedAt = diagnostics.now()
        counted = true
        diagnostics.change(BridgeDiagnosticGauge.ACTIVE_SESSIONS, 1)
        diagnostics.change(BridgeDiagnosticGauge.ACTIVE_CALLS, 1)
        diagnostics.change(BridgeDiagnosticGauge.PENDING_BUSINESS, 1)
        deadline =
            connection.engine.dispatcher.schedule(timeout) {
                terminate(
                    null,
                    BridgeFailure("TIMEOUT", "Native 启动等待超时"),
                    BridgeSessionState.TIMED_OUT,
                    true,
                )
            }
    }

    fun callback(result: JsonObject) = complete(result)

    fun complete(result: JsonObject = JsonObject()) {
        val snapshot = result.deepCopy()
        connection.engine.dispatcher.execute {
            terminate(snapshot, null, BridgeSessionState.FINISHED, false)
        }
    }

    fun fail(code: String, message: String) {
        connection.engine.dispatcher.execute {
            terminate(null, BridgeFailure(code, message), BridgeSessionState.FINISHED, false)
        }
    }

    fun emit(result: JsonObject) {
        val snapshot = result.deepCopy()
        connection.engine.dispatcher.execute {
            if (state != BridgeSessionState.RUNNING || connection.isClosed) return@execute
            val prepared = prepare(snapshot, null, false) ?: return@execute
            if (prepared.finished) finish(prepared, BridgeSessionState.FINISHED, true)
            else {
                deadline?.cancel()
                deadline = null
                sequence++
                connection.send(prepared)
            }
        }
    }

    internal fun cancelInternal() =
        terminate(null, BridgeFailure("CANCELLED", "请求已取消"), BridgeSessionState.CANCELLED, true)

    internal fun closeInternal() {
        finish(null, BridgeSessionState.CLOSED, true)
    }

    private fun terminate(
        data: JsonObject?,
        error: BridgeFailure?,
        target: BridgeSessionState,
        cancel: Boolean,
    ) {
        if (state != BridgeSessionState.RUNNING) return
        val prepared = prepare(data, error, true) ?: return
        finish(prepared, target, cancel)
    }

    private fun prepare(
        data: JsonObject?,
        error: BridgeFailure?,
        finished: Boolean,
    ): BridgePreparedResponse? {
        val id = callbackId ?: return null
        return try {
            diagnostics.record(
                BridgeDiagnosticStage.RESPONSE_ENCODE,
                connection,
                callbackId = callbackId,
                method = method,
            )
            if (state != BridgeSessionState.RUNNING || connection.isClosed) return null
            if (sequence >= 9_007_199_254_740_990L) {
                BridgeCodec.response(
                    id,
                    sequence + 1,
                    true,
                    null,
                    BridgeFailure("PROTOCOL_ERROR", "响应序号耗尽"),
                    extra,
                )
            } else BridgeCodec.response(id, sequence + 1, finished, data, error, extra)
        } catch (e: Exception) {
            connection.fail("BACKPRESSURE", "无法编码有界回包")
            null
        }
    }

    internal fun releaseMetrics() {
        if (!counted) return
        counted = false
        diagnostics.change(BridgeDiagnosticGauge.ACTIVE_SESSIONS, -1)
        diagnostics.change(BridgeDiagnosticGauge.ACTIVE_CALLS, -1)
        diagnostics.change(BridgeDiagnosticGauge.PENDING_BUSINESS, -1)
    }

    private fun runCancel(action: (() -> Unit)?) {
        if (action == null) return
        diagnostics.record(
            BridgeDiagnosticStage.CANCEL_HANDLER,
            connection,
            callbackId = callbackId,
            method = method,
        )
        runCatching(action)
    }

    private fun finish(
        prepared: BridgePreparedResponse?,
        target: BridgeSessionState,
        cancel: Boolean,
    ) {
        if (state != BridgeSessionState.RUNNING) return
        state = target
        deadline?.cancel()
        deadline = null
        callbackId?.let { id ->
            if (connection.active[id] === this) connection.active.remove(id)
            connection.remember(id)
        }
        releaseMetrics()
        val began = startedAt
        startedAt = null
        val action = cancelAction
        cancelAction = null
        needsCancellation = cancel || prepared?.requiresCleanup == true
        // 提前完成状态变更；底层取消允许同步重入 Session。
        diagnostics.record(
            BridgeDiagnosticStage.REQUEST_END,
            connection,
            callbackId = callbackId,
            method = method,
        )
        if (target == BridgeSessionState.CANCELLED || target == BridgeSessionState.TIMED_OUT)
            diagnostics.record(
                if (target == BridgeSessionState.CANCELLED) BridgeDiagnosticStage.REQUEST_CANCEL
                else BridgeDiagnosticStage.REQUEST_TIMEOUT,
                connection,
                callbackId = callbackId,
                method = method,
            )
        if (began != null) diagnostics.observe(BridgeDiagnosticLatency.REQUEST, began)
        if (prepared != null && !connection.isClosed) connection.send(prepared, control = cancel)
        if (needsCancellation) runCancel(action)
    }
}
