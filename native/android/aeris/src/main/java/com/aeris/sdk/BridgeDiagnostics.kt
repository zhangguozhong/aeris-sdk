package com.aeris.sdk

enum class BridgeDiagnosticStage(val key: String) {
    CONNECTION_OPEN("connection.open"),
    REQUEST_RECEIVE("request.receive"),
    REQUEST_REJECT("request.reject"),
    DISPATCH("dispatch"),
    RESPONSE_ENCODE("response.encode"),
    RESPONSE_ENQUEUE("response.enqueue"),
    RESPONSE_EMIT("response.emit"),
    REQUEST_END("request.end"),
    REQUEST_CANCEL("request.cancel"),
    REQUEST_TIMEOUT("request.timeout"),
    PROVIDER_PUBLISH("provider.publish"),
    PROVIDER_REJECT("provider.reject"),
    EVENT_ENQUEUE("event.enqueue"),
    EVENT_EMIT("event.emit"),
    CONNECTION_CLOSE("connection.close"),
    BACKPRESSURE("backpressure"),
    CANCEL_HANDLER("cancel.handler"),
    CLEANUP_START("cleanup.start"),
    CLEANUP_END("cleanup.end"),
    CLEANUP_CANCEL("cleanup.cancel"),
}

enum class BridgeDiagnosticGauge(val key: String) {
    QUEUED_MESSAGES("queuedMessages"),
    QUEUED_BYTES("queuedBytes"),
    ACTIVE_SESSIONS("activeSessions"),
    ACTIVE_CALLS("activeCalls"),
    SUBSCRIPTIONS("subscriptions"),
    CONNECTIONS("connections"),
    PENDING_BUSINESS("pendingBusiness"),
    PENDING_CONTROL("pendingControl"),
}

enum class BridgeDiagnosticLatency(val key: String) {
    REQUEST("request"),
    QUEUE("queue"),
    CLEANUP("cleanup"),
}

data class BridgeLatencySummary(
    val count: Long = 0,
    val sumMs: Double = 0.0,
    val maxMs: Double = 0.0,
    /** 耗时分桶上限为 1、5、10、50、100、500、1000、5000 毫秒，最后为溢出桶。 */
    val buckets: List<Long> = List(9) { 0L },
)

data class BridgeDiagnosticRecord(
    val elapsedMs: Double,
    val stage: BridgeDiagnosticStage,
    val endpointId: String?,
    val callbackId: String?,
    val subscriptionId: String?,
    val method: String?,
    val topic: String?,
    val code: String?,
    val source: Int?,
)

data class BridgeDiagnosticsSnapshot(
    val counters: Map<String, Long>,
    val gauges: Map<String, Long>,
    val peaks: Map<String, Long>,
    val latency: Map<String, BridgeLatencySummary>,
    val records: List<BridgeDiagnosticRecord>,
)

/** 在 Engine dispatcher 上采集固定指标和脱敏元数据，不接受业务载荷或异常详情。 */
class BridgeDiagnostics(
    capacity: Int = 128,
    private val clock: () -> Double = { System.nanoTime() / 1e9 },
    observer: ((BridgeDiagnosticRecord) -> Unit)? = null,
) {
    private val capacity = capacity.coerceIn(0, 1024)
    private var origin = readClock()
    private var lastTime = 0.0
    private var observer = observer
    private var notifying = false
    private val counters = mutableMapOf<String, Long>()
    private val gauges = BridgeDiagnosticGauge.entries.associate { it.key to 0L }.toMutableMap()
    private val peaks = gauges.toMutableMap()
    private val latency = mutableMapOf<String, BridgeLatencySummary>()
    private val records = ArrayDeque<BridgeDiagnosticRecord>()

    /** 替换采集器只影响下一次通知，保留已有指标和历史。 */
    fun setObserver(observer: ((BridgeDiagnosticRecord) -> Unit)?) {
        this.observer = observer
    }

    fun snapshot() =
        BridgeDiagnosticsSnapshot(
            counters.toMap(),
            gauges.toMap(),
            peaks.toMap(),
            latency.mapValues { (_, summary) -> summary.copy(buckets = summary.buckets.toList()) },
            records.toList(),
        )

    /** 清除历史，同时保留队列、连接和会话的当前计数。 */
    fun reset() {
        counters.clear()
        records.clear()
        latency.clear()
        peaks.clear()
        peaks.putAll(gauges)
    }

    // 时钟属于诊断扩展点；故障不能中断业务关闭或让指标出现非有限值。
    private fun readClock(): Double? = runCatching(clock).getOrNull()?.takeIf { it.isFinite() }

    internal fun now(): Double {
        val current = readClock() ?: return lastTime
        val began = origin ?: current.also { origin = it }
        val elapsed = (current - began) * 1000
        if (elapsed.isFinite()) lastTime = maxOf(lastTime, elapsed)
        return lastTime
    }

    internal fun change(gauge: BridgeDiagnosticGauge, delta: Int) {
        val current = gauges.getValue(gauge.key) + delta
        gauges[gauge.key] = current
        peaks[gauge.key] = maxOf(peaks.getValue(gauge.key), current)
    }

    internal fun observe(latency: BridgeDiagnosticLatency, since: Double) {
        val elapsed = maxOf(0.0, now() - since)
        val summary = this.latency[latency.key] ?: BridgeLatencySummary()
        val bucket = latencyBounds.indexOfFirst { elapsed <= it }.takeIf { it >= 0 } ?: 8
        val buckets = summary.buckets.toMutableList()
        buckets[bucket]++
        this.latency[latency.key] =
            BridgeLatencySummary(
                summary.count + 1,
                summary.sumMs + elapsed,
                maxOf(summary.maxMs, elapsed),
                buckets,
            )
    }

    internal fun record(
        stage: BridgeDiagnosticStage,
        connection: BridgeConnection? = null,
        callbackId: String? = null,
        subscriptionId: String? = null,
        method: String? = null,
        topic: String? = null,
        code: String? = null,
    ) {
        append(
            BridgeDiagnosticRecord(
                elapsedMs = now(),
                stage = stage,
                endpointId = safeEndpoint(connection?.endpointId),
                callbackId = safeID(callbackId),
                subscriptionId = safeID(subscriptionId),
                method = safeMethod(method),
                topic =
                    topic?.takeIf { BridgeCodec.size(it) in 1..128 && topicPattern.matches(it) },
                code = code?.let { if (it in knownCodes) it else "OTHER" },
                source = connection?.source,
            )
        )
    }

    internal fun trace(stage: BridgeDiagnosticStage, trace: BridgeOperationTrace) {
        append(
            BridgeDiagnosticRecord(
                elapsedMs = now(),
                stage = stage,
                endpointId = trace.endpointId,
                callbackId = trace.callbackId,
                subscriptionId = null,
                method = trace.method,
                topic = null,
                code = null,
                source = trace.source,
            )
        )
    }

    private fun append(record: BridgeDiagnosticRecord) {
        counters[record.stage.key] = (counters[record.stage.key] ?: 0) + 1
        if (capacity > 0) {
            if (records.size == capacity) records.removeFirst()
            records.addLast(record)
        }
        val currentObserver = observer ?: return
        if (notifying) return
        notifying = true
        try {
            currentObserver(record)
        } catch (_: Throwable) {
            counters["observer.error"] = (counters["observer.error"] ?: 0) + 1
        } finally {
            notifying = false
        }
    }

    internal companion object {
        private val latencyBounds = listOf(1.0, 5.0, 10.0, 50.0, 100.0, 500.0, 1000.0, 5000.0)
        private val topicPattern = Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$")
        private val endpointPattern =
            Regex("^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
        private val knownCodes =
            setOf(
                "BACKPRESSURE",
                "DISCONNECTED",
                "CLOSED",
                "CANCELLED",
                "TIMEOUT",
                "INVALID_ARGUMENT",
                "INVALID_METHOD",
                "PAYLOAD_TOO_LARGE",
                "INTERNAL_ERROR",
                "PROTOCOL_ERROR",
                "INVALID_EVENT",
                "METHOD_NOT_FOUND",
                "PERMISSION_DENIED",
                "TOO_MANY_REQUESTS",
                "TOO_MANY_SUBSCRIPTIONS",
                "DUPLICATE_SUBSCRIPTION",
                "EVENT_NOT_FOUND",
                "EVENT_UNAVAILABLE",
                "UI_UNAVAILABLE",
                "BUSY",
                "CAMERA_UNAVAILABLE",
                "PHOTO_ENCODING_FAILED",
                "PHOTO_WRITE_FAILED",
            )

        internal fun safeID(value: String?): String? =
            value?.takeIf { BridgeCodec.prefix(it) != null }

        internal fun safeMethod(value: String?): String? = value?.takeIf(BridgeCodec::validMethod)

        private fun safeEndpoint(value: String?): String? = value?.takeIf(endpointPattern::matches)
    }
}

/** 只保存不可变的标识值及诊断对象，不保留 Session、Connection 或界面所有者。 */
class BridgeOperationTrace
internal constructor(
    private val diagnostics: BridgeDiagnostics,
    connection: BridgeConnection,
    callbackId: String?,
    method: String?,
) {
    val endpointId = connection.endpointId
    val callbackId = BridgeDiagnostics.safeID(callbackId)
    val method = BridgeDiagnostics.safeMethod(method)
    val source = connection.source
    private var began: Double? = null
    private var ended = false

    /** 交互转场取消后允许真正关闭时重新开始计时。 */
    fun cleanupCancelled() {
        if (began == null || ended) return
        began = null
        diagnostics.trace(BridgeDiagnosticStage.CLEANUP_CANCEL, this)
    }

    fun cleanupStarted() {
        if (began != null || ended) return
        began = diagnostics.now()
        diagnostics.trace(BridgeDiagnosticStage.CLEANUP_START, this)
    }

    fun cleanupEnded() {
        val started = began ?: return
        if (ended) return
        ended = true
        diagnostics.trace(BridgeDiagnosticStage.CLEANUP_END, this)
        diagnostics.observe(BridgeDiagnosticLatency.CLEANUP, since = started)
    }
}
