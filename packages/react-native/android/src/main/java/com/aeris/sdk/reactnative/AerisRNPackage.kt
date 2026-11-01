package com.aeris.sdk.reactnative

import com.facebook.react.BaseReactPackage
import com.facebook.react.bridge.NativeModule
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.module.model.ReactModuleInfo
import com.facebook.react.module.model.ReactModuleInfoProvider
import com.aeris.sdk.AndroidBridgeDispatcher
import com.aeris.sdk.BridgeDispatcher

/** 无参构造支持自动链接；配置过的 Package 为每个 RN Context 单独调用 factory。 */
class AerisRNPackage constructor(
    private val factory: AerisRNReceiverFactory? = null,
    private val dispatcher: BridgeDispatcher = AndroidBridgeDispatcher(),
) : BaseReactPackage() {
    override fun getModule(name: String, reactContext: ReactApplicationContext): NativeModule? =
        if (name == AerisRNModule.NAME) AerisRNModule(reactContext, factory, dispatcher) else null

    override fun getReactModuleInfoProvider() = ReactModuleInfoProvider {
        mapOf(AerisRNModule.NAME to ReactModuleInfo(
            AerisRNModule.NAME, AerisRNModule::class.java.name, false, false, false, true,
        ))
    }
}
