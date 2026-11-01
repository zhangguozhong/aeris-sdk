package com.aeris.sdk

import android.view.View
import android.view.ViewGroup
import java.lang.ref.WeakReference

/** 不持有 Activity；原始容器脱离后永久失效，不会转而指向新容器。 */
class AndroidBridgeUIContext(container: ViewGroup) : ManagedBridgeUIContext(), AndroidContainerBridgeUIContext {
    private val root = WeakReference(container)
    override val containerView: ViewGroup? get() = root.get()?.takeIf { isValid }
    private val listener = object : View.OnAttachStateChangeListener {
        override fun onViewAttachedToWindow(view: View) = Unit
        override fun onViewDetachedFromWindow(view: View) { invalidate() }
    }
    init { container.addOnAttachStateChangeListener(listener) }
    override val isValid get() = super.isValid && root.get() != null
    override fun invalidate() {
        root.get()?.removeOnAttachStateChangeListener(listener)
        super.invalidate()
        root.clear()
    }
}
