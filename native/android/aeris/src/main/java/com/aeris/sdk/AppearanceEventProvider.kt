package com.aeris.sdk

import android.content.res.Configuration
import android.view.View
import android.view.ViewGroup
import com.google.gson.JsonObject

/** 观察原始容器的 Resources，包括 Activity 和主题的配置覆盖。 */
class AppearanceEventProvider : BridgeContextEventProvider {
    override fun observe(context: BridgeUIContext?, publish: (JsonObject) -> Unit): BridgeEventObservation {
        val androidContext = context as? AndroidContainerBridgeUIContext
            ?: throw BridgeFailure("UI_UNAVAILABLE", "Appearance requires an Android container ViewGroup")
        val root = androidContext.containerView
            ?: throw BridgeFailure("UI_UNAVAILABLE", "Appearance requires an Android container ViewGroup")
        var active = true
        fun snapshot(): JsonObject {
            val style = root.resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
            return SystemEventSnapshots.appearance(when (style) {
                Configuration.UI_MODE_NIGHT_YES -> true
                Configuration.UI_MODE_NIGHT_NO -> false
                else -> null
            })
        }
        val observer = object : View(root.context) {
            override fun onConfigurationChanged(newConfig: Configuration) {
                super.onConfigurationChanged(newConfig)
                if (active && androidContext.isValid) publish(snapshot())
            }
        }
        observer.visibility = View.GONE
        root.addView(observer, ViewGroup.LayoutParams(0, 0))
        return BridgeEventObservation(snapshot()) {
            active = false
            root.removeView(observer)
        }
    }
}

/** 宿主启动且尚未订阅时调用一次；所有事件经 Engine.publish/EventHub 统一发送。 */
fun BridgeEngine.installSystemEventProviders(context: android.content.Context) {
    registerEvent("network.changed", NetworkStatusEventProvider(context))
    registerEvent("appearance.changed", AppearanceEventProvider(), BridgeEventScope.CONTEXT)
}
