package com.aeris.sdk.reactnative

import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.annotations.ReactModule
import com.aeris.sdk.AndroidBridgeDispatcher
import com.aeris.sdk.BridgeDispatcher
import com.aeris.sdk.reactnative.codegen.NativeUnifiedBridgeSpec

/** 只转接字符串与 Codegen 事件，项目业务通过公共接收器契约注入。 */
@ReactModule(name = AerisRNModule.NAME)
class AerisRNModule @JvmOverloads constructor(
    context: ReactApplicationContext,
    factory: AerisRNReceiverFactory? = null,
    dispatcher: BridgeDispatcher = AndroidBridgeDispatcher(),
) : NativeUnifiedBridgeSpec(context), AerisRNModuleBinding {
    companion object { const val NAME = "NativeUnifiedBridge" }
    private val binding = AerisRNBinding(dispatcher, factory) { message -> emitOnMessage(message) }

    override fun send(message: String) = binding.receiveMessage(message)
    override fun bindReceiver(receiver: AerisMessageReceiver) = binding.bindReceiver(receiver)
    override fun emitMessageToJS(message: String) = binding.emitMessageToJS(message)
    override fun invalidate() {
        binding.close()
        super.invalidate()
    }
}
