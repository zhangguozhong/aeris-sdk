package com.aeris.sdk

import java.util.ArrayDeque

data class BridgeFlowLimits(
    val maxActiveRequests: Int = 128,
    val maxQueuedMessages: Int = 512,
    val maxQueuedBytes: Int = 8 * 1024 * 1024,
    val maxConnectionMessages: Int = 64,
    val maxConnectionBytes: Int = 2 * 1024 * 1024,
    val reservedControlMessages: Int = 64,
    val reservedControlBytes: Int = 512 * 1024,
    val drainBatch: Int = 8,
) {
    init {
        require(
            listOf(
                    maxActiveRequests,
                    maxQueuedMessages,
                    maxQueuedBytes,
                    maxConnectionMessages,
                    maxConnectionBytes,
                    reservedControlMessages,
                    reservedControlBytes,
                    drainBatch,
                )
                .all { it > 0 }
        )
    }
}

internal class BridgeOutboundFlow(
    private val dispatcher: BridgeDispatcher,
    private val limits: BridgeFlowLimits,
    private val diagnostics: BridgeDiagnostics,
) {
    private data class Frame(
        val connection: BridgeConnection,
        val text: String,
        val bytes: Int,
        val control: Boolean,
        val subscription: String?,
        val afterEmit: (() -> Unit)?,
        val callbackId: String?,
        val topic: String?,
        val enqueued: Double,
    )

    private class Queue {
        val control = ArrayDeque<Frame>()
        val data = ArrayDeque<Frame>()
        var controlBytes = 0
        var dataBytes = 0
        var controlsServed = 0
        val isEmpty
            get() = control.isEmpty() && data.isEmpty()
    }

    private val queues = mutableMapOf<BridgeConnection, Queue>()
    private val ready = ArrayDeque<BridgeConnection>()
    private var controlCount = 0
    private var controlBytes = 0
    private var dataCount = 0
    private var dataBytes = 0
    private var drain: BridgeCancellation? = null
    private var pumping = false

    fun submit(
        connection: BridgeConnection,
        text: String,
        control: Boolean,
        subscription: String? = null,
        afterEmit: (() -> Unit)? = null,
        callbackId: String? = null,
        topic: String? = null,
    ) {
        if (connection.isClosed) return
        val bytes = BridgeCodec.size(text)
        val queue = queues[connection] ?: Queue()
        // 保留原构造参数；单连接控制预算不能吃掉其他连接的全局保留配额。
        val full =
            if (control) {
                queue.control.size >= minOf(32, limits.reservedControlMessages) ||
                    bytes > minOf(256 * 1024, limits.reservedControlBytes) - queue.controlBytes ||
                    controlCount >= limits.reservedControlMessages ||
                    bytes > limits.reservedControlBytes - controlBytes
            } else {
                queue.data.size >= limits.maxConnectionMessages ||
                    bytes > limits.maxConnectionBytes - queue.dataBytes ||
                    dataCount >= limits.maxQueuedMessages ||
                    bytes > limits.maxQueuedBytes - dataBytes
            }
        if (full || bytes > BridgeCodec.MAX_BYTES) {
            connection.fail("BACKPRESSURE", "Native 出站队列超过预算")
            return
        }
        if (queue.isEmpty) ready.addLast(connection)
        queues[connection] = queue
        val frame =
            Frame(
                connection,
                text,
                bytes,
                control,
                subscription,
                afterEmit,
                callbackId,
                topic,
                diagnostics.now(),
            )
        if (control) {
            queue.control.addLast(frame)
            queue.controlBytes += bytes
            controlCount++
            controlBytes += bytes
        } else {
            queue.data.addLast(frame)
            queue.dataBytes += bytes
            dataCount++
            dataBytes += bytes
        }
        diagnostics.change(BridgeDiagnosticGauge.QUEUED_MESSAGES, 1)
        diagnostics.change(BridgeDiagnosticGauge.QUEUED_BYTES, bytes)
        if (control) diagnostics.change(BridgeDiagnosticGauge.PENDING_CONTROL, 1)
        schedule()
        diagnostics.record(
            if (subscription == null) BridgeDiagnosticStage.RESPONSE_ENQUEUE
            else BridgeDiagnosticStage.EVENT_ENQUEUE,
            connection,
            callbackId,
            subscription,
            topic = topic,
        )
    }

    fun remove(connection: BridgeConnection, subscription: String? = null) {
        val queue = queues[connection] ?: return
        listOf(queue.control, queue.data).forEach { frames ->
            val iterator = frames.iterator()
            while (iterator.hasNext()) {
                val frame = iterator.next()
                if (subscription == null || frame.subscription == subscription) {
                    iterator.remove()
                    release(queue, frame)
                }
            }
        }
        if (queue.isEmpty) {
            queues.remove(connection)
            ready.remove(connection)
        }
        if (ready.isEmpty()) {
            drain?.cancel()
            drain = null
        }
    }

    private fun release(queue: Queue, frame: Frame) {
        diagnostics.change(BridgeDiagnosticGauge.QUEUED_MESSAGES, -1)
        diagnostics.change(BridgeDiagnosticGauge.QUEUED_BYTES, -frame.bytes)
        if (frame.control) diagnostics.change(BridgeDiagnosticGauge.PENDING_CONTROL, -1)
        if (frame.control) {
            queue.controlBytes -= frame.bytes
            controlCount--
            controlBytes -= frame.bytes
        } else {
            queue.dataBytes -= frame.bytes
            dataCount--
            dataBytes -= frame.bytes
        }
    }

    private fun schedule() {
        if (pumping || drain != null || ready.isEmpty()) return
        drain =
            dispatcher.schedule(0) {
                drain = null
                pumping = true
                try {
                    repeat(limits.drainBatch) {
                        if (ready.isEmpty()) return@repeat
                        val connection = ready.removeFirst()
                        val queue = queues[connection] ?: return@repeat
                        val frame =
                            if (
                                queue.control.isNotEmpty() &&
                                    (queue.controlsServed < 4 || queue.data.isEmpty())
                            ) {
                                queue.controlsServed++
                                queue.control.removeFirst()
                            } else {
                                queue.controlsServed = 0
                                queue.data.removeFirst()
                            }
                        // 回调可能同步发布、关闭或退订；先摘队扣账，再进入外部代码。
                        release(queue, frame)
                        if (queue.isEmpty) queues.remove(connection) else ready.addLast(connection)
                        if (!connection.isClosed) {
                            try {
                                diagnostics.observe(BridgeDiagnosticLatency.QUEUE, frame.enqueued)
                                connection.emit(frame.text)
                                diagnostics.record(
                                    if (frame.subscription == null)
                                        BridgeDiagnosticStage.RESPONSE_EMIT
                                    else BridgeDiagnosticStage.EVENT_EMIT,
                                    connection,
                                    frame.callbackId,
                                    frame.subscription,
                                    topic = frame.topic,
                                )
                                if (!connection.isClosed) frame.afterEmit?.invoke()
                            } catch (_: Exception) {
                                connection.fail("DISCONNECTED", "Native 发送器不可用")
                            }
                        }
                    }
                } finally {
                    pumping = false
                }
                schedule()
            }
    }
}
