package com.aeris.sdk.reactnative

/** 公共契约不依赖 React Native Codegen 类型；宿主负责创建各容器的接收器。 */
interface AerisMessageReceiver {
    fun receiveMessage(message: String)
    fun beginClosing()
    fun close()
}

interface AerisRNModuleBinding {
    fun bindReceiver(receiver: AerisMessageReceiver)
    fun emitMessageToJS(message: String)
}

fun interface AerisRNReceiverFactory {
    fun create(binding: AerisRNModuleBinding): AerisMessageReceiver
}
