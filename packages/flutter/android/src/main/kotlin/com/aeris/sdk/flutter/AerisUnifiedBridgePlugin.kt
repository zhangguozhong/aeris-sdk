package com.aeris.sdk.flutter

import com.aeris.sdk.*
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.BasicMessageChannel
import io.flutter.plugin.common.StringCodec

/** 注册后通过 engine.plugins.get(AerisUnifiedBridgePlugin::class.java) 获取对应实例。 */
class AerisUnifiedBridgePlugin : FlutterPlugin, AerisFlutterModuleBinding {
    companion object { const val CHANNEL_NAME = "aeris_bridge" }
    private val dispatcher: BridgeDispatcher = AndroidBridgeDispatcher()
    private var binding: AerisFlutterBinding? = null

    override fun onAttachedToEngine(flutterBinding: FlutterPlugin.FlutterPluginBinding) {
        dispatcher.checkThread()
        check(binding == null) { "Already attached to a FlutterEngine" }
        val channel = BasicMessageChannel<String?>(flutterBinding.binaryMessenger, CHANNEL_NAME, StringCodec.INSTANCE)
        val owner = AerisFlutterBinding(dispatcher, { channel.send(it) }, { channel.setMessageHandler(null) })
        binding = owner
        channel.setMessageHandler { message, reply ->
            owner.handleFrameworkMessage(message) { reply.reply(it) }
        }
    }
    fun bind(
        engine: BridgeEngine,
        uiContext: BridgeUIContext? = null,
        allowedPermissions: Set<String> = emptySet(),
        allowedEventTopics: Set<String>? = null,
    ) = bind(AerisBridgeReceiverFactory(engine, BridgeSource.FLUTTER, uiContext, allowedPermissions, allowedEventTopics))

    fun bind(factory: AerisReceiverFactory) {
        dispatcher.checkThread()
        checkNotNull(binding) { "Register the plugin before binding" }.bind(factory)
    }
    override fun bindReceiver(receiver: AerisMessageReceiver) {
        dispatcher.checkThread()
        checkNotNull(binding) { "Register the plugin before binding" }.bindReceiver(receiver)
    }
    override fun emitMessageToDart(message: String) { binding?.emitMessageToDart(message) }
    override fun close() { binding?.close() }
    override fun onDetachedFromEngine(flutterBinding: FlutterPlugin.FlutterPluginBinding) {
        binding?.close()
        binding = null
    }
}
