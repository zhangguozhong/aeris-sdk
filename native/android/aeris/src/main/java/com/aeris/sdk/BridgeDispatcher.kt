package com.aeris.sdk

fun interface BridgeCancellation {
    fun cancel()
}

/** 可变协议状态只在同一个 dispatcher 中访问；业务结果允许从后台线程提交。 */
interface BridgeDispatcher {
    fun checkThread()
    fun execute(action: () -> Unit)
    fun schedule(delayMs: Long, action: () -> Unit): BridgeCancellation
}
