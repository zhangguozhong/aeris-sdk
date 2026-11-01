package com.aeris.sdk

import android.os.Handler
import android.os.Looper

/** 不使用 coroutine；Handler 接入支持普通 callback 风格的原生项目。 */
class AndroidBridgeDispatcher : BridgeDispatcher {
    private val handler = Handler(Looper.getMainLooper())

    override fun checkThread() {
        check(Looper.myLooper() == Looper.getMainLooper()) { "请在 Android 主线程组装 Aeris" }
    }

    override fun execute(action: () -> Unit) {
        handler.post { action() }
    }

    override fun schedule(delayMs: Long, action: () -> Unit): BridgeCancellation {
        val work = Runnable { action() }
        handler.postDelayed(work, delayMs)
        return BridgeCancellation { handler.removeCallbacks(work) }
    }
}
