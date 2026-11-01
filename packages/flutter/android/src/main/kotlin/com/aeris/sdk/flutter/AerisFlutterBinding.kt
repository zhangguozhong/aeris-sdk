package com.aeris.sdk.flutter

import com.aeris.sdk.*
import com.google.gson.JsonParser
import java.util.concurrent.atomic.AtomicBoolean

interface AerisFlutterModuleBinding {
    fun bindReceiver(receiver: AerisMessageReceiver)

    fun emitMessageToDart(message: String)

    fun close()
}

/** 每个 BinaryMessenger 独占绑定，不保存进程级接收器或 Engine 引用。 */
class AerisFlutterBinding(
    private val dispatcher: BridgeDispatcher,
    private val emit: (String) -> Unit,
    private val releaseChannel: () -> Unit,
) : AerisFlutterModuleBinding, AerisMessageReceiver {
    private val closed = AtomicBoolean(false)
    private var bound = false
    private var receiver: AerisMessageReceiver? = null
    private var closedObservation: BridgeCancellation? = null
    private var startupMessage: String? = null
    private var closeResult: Result<Unit>? = null
    private val closeWaiters = mutableListOf<(Result<Unit>) -> Unit>()

    override fun bindReceiver(receiver: AerisMessageReceiver) {
        dispatcher.checkThread()
        check(!closed.get() && !bound) { "Bind exactly once per FlutterEngine" }
        bound = true
        // 由共用宿主区分逻辑断开与物理关闭，保留同一 channel 的新前缀恢复。
        val host = AerisHostBinding(dispatcher, ::emitMessageToDart)
        host.bindReceiver(receiver)
        this.receiver = host
        closedObservation = host.observeClosed { dispatcher.execute { close() } }
        val startup = startupMessage
        startupMessage = null
        if (startup != null)
            try {
                receiver.receiveMessage(startup)
            } catch (_: Exception) {
                close()
            }
    }

    fun bind(factory: AerisReceiverFactory) {
        dispatcher.checkThread()
        check(!closed.get() && !bound) { "Bind exactly once per FlutterEngine" }
        val created = factory.create(::emitMessageToDart)
        try {
            bindReceiver(created)
        } catch (error: Exception) {
            created.close()
            throw error
        }
    }

    /** StringCodec 框架确认恒为 null，包括无效输入及已解除的绑定。 */
    fun handleFrameworkMessage(message: String?, reply: (String?) -> Unit) {
        reply(null)
        if (message == null) close() else receiveMessage(message)
    }

    override fun receiveMessage(message: String) {
        if (closed.get()) return
        dispatcher.execute {
            if (closed.get()) return@execute
            if (message.toByteArray(Charsets.UTF_8).size > 256 * 1024) {
                close()
                return@execute
            }
            val target = receiver
            if (target != null) {
                try {
                    target.receiveMessage(message)
                } catch (_: Exception) {
                    close()
                }
            } else {
                // Dart 可能在 Engine.run 与宿主注入之间发起 hello；此处不缓冲业务请求。
                val hello = runCatching {
                    JsonParser.parseString(message).asJsonObject.get("method")?.asString ==
                        "bridge.hello"
                }
                    .getOrDefault(false)
                if (startupMessage != null || !hello) close() else startupMessage = message
            }
        }
    }

    override fun emitMessageToDart(message: String) {
        if (closed.get()) return
        dispatcher.execute {
            if (!closed.get())
                try {
                    emit(message)
                } catch (_: Exception) {
                    close()
                }
        }
    }

    override fun beginClosing() {
        dispatcher.execute { if (!closed.get()) receiver?.beginClosing() }
    }

    /** 仅保证通道已解绑且宿主 close 已提交；接收器真实清理由其关闭观察者确认。 */
    fun close(completion: (Result<Unit>) -> Unit) {
        dispatcher.execute {
            val result = closeResult
            if (result != null) runCatching { completion(result) } else closeWaiters.add(completion)
        }
        // 与无参关闭保持一致：返回前封闭入口，排队消息不能趁解绑前继续通过。
        close()
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        dispatcher.execute {
            val target = receiver
            receiver = null
            startupMessage = null
            closedObservation?.cancel()
            closedObservation = null
            val release = runCatching { releaseChannel() }
            val targetClose = runCatching {
                target?.close()
                Unit
            }
            val result = if (release.isFailure) release else targetClose
            closeResult = result
            val callbacks = closeWaiters.toList()
            closeWaiters.clear()
            callbacks.forEach { callback -> runCatching { callback(result) } }
        }
    }
}
