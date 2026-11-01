package com.aeris.sdk

import android.view.ViewGroup

/** 宿主可通过接口暴露原始容器，无需继承 SDK 的实现类。
 * isValid/observeInvalidation 始终对应同一次 View 生命周期，Activity 重建后也不改变归属。
 */
interface AndroidContainerBridgeUIContext : BridgeUIContext {
    val containerView: ViewGroup?
}
