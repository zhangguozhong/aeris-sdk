package com.aeris.sdk

import java.util.concurrent.atomic.AtomicBoolean

/** 不依赖业务 SDK 的容器契约；每个实际宿主容器单独创建工厂。 */
interface AerisMessageReceiver {
    fun receiveMessage(message: String)
    fun beginClosing()
    fun close()
    fun observeClosed(listener: (BridgeFailure?) -> Unit): BridgeCancellation = BridgeCancellation {}
}

fun interface AerisReceiverFactory {
    fun create(emit: (String) -> Unit): AerisMessageReceiver
}

class AerisBridgeReceiverFactory(
    private val engine: BridgeEngine,
    val source: BridgeSource,
    private val uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
) : AerisReceiverFactory {
    private val permissions = allowedPermissions.toSet()
    private val topics = allowedEventTopics?.toSet()
    init {
        if (source !in setOf(BridgeSource.WEB, BridgeSource.REACT_NATIVE, BridgeSource.FLUTTER, BridgeSource.UNITY))
            throw BridgeFailure("UNSUPPORTED_SOURCE", "No transport for source ${source.value}")
    }
    override fun create(emit: (String) -> Unit): AerisMessageReceiver {
        engine.dispatcher.checkThread()
        return when (source) {
            BridgeSource.WEB -> AerisWebNativeTransport(engine, uiContext, permissions, topics, emit)
            BridgeSource.REACT_NATIVE -> AerisRNNativeTransport(engine, uiContext, permissions, topics, emit)
            BridgeSource.FLUTTER -> AerisFlutterNativeTransport(engine, uiContext, permissions, topics, emit)
            BridgeSource.UNITY -> AerisUnityNativeTransport(engine, uiContext, permissions, topics, emit)
            else -> throw BridgeFailure("UNSUPPORTED_SOURCE", "Unsupported source")
        }
    }
}

/** 独占一个接收器；关闭时立即封闭排队发送，再通过 dispatcher 释放。 */
class AerisHostBinding(
    private val dispatcher: BridgeDispatcher,
    private val emit: (String) -> Unit,
) : AerisMessageReceiver {
    private val closed = AtomicBoolean(false)
    private var bound = false
    private var receiver: AerisMessageReceiver? = null
    private var closedObservation: BridgeCancellation? = null
    private var terminalError: BridgeFailure? = null
    private val closeObservers = mutableSetOf<(BridgeFailure?) -> Unit>()
    fun bindReceiver(value: AerisMessageReceiver) {
        dispatcher.checkThread()
        check(!closed.get() && !bound) { "Bind exactly once per container" }
        bound = true
        receiver = value
        val listener: (BridgeFailure?) -> Unit = { error -> dispatcher.execute { closeWithFailure(error) } }
        closedObservation = if (value is AerisNativeTransport) value.observePhysicalClosed(listener)
            else value.observeClosed(listener)
    }
    fun bind(factory: AerisReceiverFactory) {
        dispatcher.checkThread()
        check(!closed.get() && !bound) { "Bind exactly once per container" }
        val created = factory.create(::emitMessage)
        try { bindReceiver(created) } catch (error: Exception) { created.close(); throw error }
    }
    fun emitMessage(message: String) {
        if (closed.get()) return
        dispatcher.execute { if (!closed.get()) try { emit(message) } catch (_: Exception) { close() } }
    }
    override fun receiveMessage(message: String) {
        if (closed.get()) return
        dispatcher.execute {
            if (!closed.get()) try { receiver?.receiveMessage(message) ?: close() } catch (_: Exception) { close() }
        }
    }
    override fun beginClosing() { dispatcher.execute { if (!closed.get()) receiver?.beginClosing() } }
    override fun observeClosed(listener: (BridgeFailure?) -> Unit): BridgeCancellation {
        dispatcher.checkThread()
        if (closed.get()) { listener(terminalError); return BridgeCancellation {} }
        closeObservers.add(listener)
        return BridgeCancellation { closeObservers.remove(listener) }
    }
    override fun close() = closeWithFailure(null)
    private fun closeWithFailure(error: BridgeFailure?) {
        if (!closed.compareAndSet(false, true)) return
        terminalError = error
        dispatcher.execute {
            val old = receiver; receiver = null
            closedObservation?.cancel(); closedObservation = null
            val observers = closeObservers.toList()
            closeObservers.clear()
            runCatching { old?.close() }
            observers.forEach { observer -> runCatching { observer(error) } }
        }
    }
}
