package com.aeris.sdk.unity

import android.os.Handler
import android.os.Looper
import com.aeris.sdk.AerisHostBinding
import com.aeris.sdk.AerisBridgeReceiverFactory
import com.aeris.sdk.BridgeSource
import com.aeris.sdk.BridgeEngine
import com.aeris.sdk.BridgeUIContext
import com.aeris.unity.AerisUnityChannel
import java.util.concurrent.Executor
import java.util.concurrent.RejectedExecutionException

/** 每个 Unity 容器一条独立连接；宿主先创建 Driver，再让 Unity 打开同名 channel。 */
class AerisUnityChannelDriver(
    channel: String,
    engine: BridgeEngine,
    uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
) : AutoCloseable {
    private val binding = AerisUnityChannel.bind(channel, { emitter ->
        val transport = AerisHostBinding(engine.dispatcher) { text -> emitter.emit(text) }
        transport.bind(AerisBridgeReceiverFactory(engine, BridgeSource.UNITY, uiContext, allowedPermissions, allowedEventTopics))
        transport.observeClosed { failure -> emitter.disconnect(failure?.code ?: "HOST_CLOSED") }
        object : AerisUnityChannel.Receiver {
            override fun receive(payload: String) { transport.receiveMessage(payload) }
            override fun close() { transport.close() }
        }
    }, MainExecutor)

    override fun close() { binding.close() }

    companion object {
        /** 必须在 UnityPlayer.unload/destroy 之前调用；先撤销 JNI 代理，再卸载运行时。 */
        @JvmStatic fun prepareUnload() {
            check(Looper.myLooper() == Looper.getMainLooper()) { "Unload Unity from Android main thread" }
            AerisUnityChannel.prepareUnload()
        }
        /** 新的 UnityPlayer 启动前恢复注册；旧 Driver 必须已经关闭。 */
        @JvmStatic fun resume() {
            check(Looper.myLooper() == Looper.getMainLooper()) { "Resume Unity from Android main thread" }
            AerisUnityChannel.resume()
        }
    }
}

private object MainExecutor : Executor {
    private val handler = Handler(Looper.getMainLooper())
    override fun execute(command: Runnable) {
        if (Looper.myLooper() == Looper.getMainLooper()) command.run()
        else if (!handler.post(command)) throw RejectedExecutionException("Android main looper stopped")
    }
}
