package com.aeris.sdk.reactnative

import com.aeris.sdk.BridgeDispatcher
import java.util.concurrent.atomic.AtomicBoolean

/** 每个模块一个绑定；立即封闭发送入口，再到主线程释放宿主接收器。 */
internal class AerisRNBinding(
    private val dispatcher: BridgeDispatcher,
    factory: AerisRNReceiverFactory?,
    private val emit: (String) -> Unit,
) : AerisRNModuleBinding, AerisMessageReceiver {
    private val closed = AtomicBoolean(false)
    private var receiver: AerisMessageReceiver? = null

    init {
        dispatcher.execute {
            if (!closed.get() && factory != null) {
                try {
                    val created = factory.create(this)
                    try { bindReceiver(created) }
                    catch (error: Exception) {
                        // invalidate 可在 factory 执行期间从 RN 线程立即封闭模块。
                        runCatching { created.close() }
                        throw error
                    }
                }
                catch (error: Exception) { disconnect() }
            }
        }
    }

    override fun bindReceiver(receiver: AerisMessageReceiver) {
        dispatcher.checkThread()
        check(!closed.get() && this.receiver == null) { "接收器只能绑定一次且必须先于 RN 获取模块" }
        this.receiver = receiver
    }

    override fun receiveMessage(message: String) {
        if (closed.get()) return
        dispatcher.execute {
            if (!closed.get()) {
                val target = receiver
                if (target == null) disconnect()
                else try { target.receiveMessage(message) } catch (error: Exception) { disconnect() }
            }
        }
    }

    override fun emitMessageToJS(message: String) {
        if (closed.get()) return
        dispatcher.execute {
            if (!closed.get()) try { emit(message) } catch (error: Exception) { close() }
        }
    }

    override fun beginClosing() {
        dispatcher.execute { if (!closed.get()) receiver?.beginClosing() }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        dispatcher.execute {
            val target = receiver
            receiver = null
            runCatching { target?.close() }
        }
    }

    private fun disconnect() {
        if (closed.get()) return
        runCatching { emit("{\"method\":\"bridge.close\",\"params\":{\"code\":\"DISCONNECTED\",\"reason\":\"Native receiver unavailable\"}}") }
        close()
    }
}
