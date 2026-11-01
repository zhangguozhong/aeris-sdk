package com.aeris.sdk

/** 仅显式注解的方法可被远端调用，不导出普通 public 方法和 Object 成员。 */
@Target(AnnotationTarget.FUNCTION)
@Retention(AnnotationRetention.RUNTIME)
annotation class BridgeMethod(val permission: String = "")

interface BridgeModule {
    val moduleName: String
    val requiredPermissions: Set<String> get() = emptySet()
}

/** 默认模块不内置拍照、登录或任何项目业务，宿主自行注册并扩展。 */
open class DefaultBridge : BridgeModule {
    override val moduleName = "DefaultBridge"
}

interface BridgeUIContext {
    val identity: String
    val isValid: Boolean
    /** 可选的失效通知；既有宿主上下文保持源码兼容。 */
    fun observeInvalidation(action: () -> Unit): BridgeCancellation = BridgeCancellation {}
}

class BridgeFailure(val code: String, override val message: String) : Exception(message)

enum class BridgeSource(val value: Int) {
    UNKNOWN(0), WEB(1), REACT_NATIVE(2), FLUTTER(3), UNITY(4), COCOS(5)
}

/** 上下文生命周期从属于单个容器，不使用进程级 Activity 单例；状态仅在 dispatcher 上访问。 */
open class ManagedBridgeUIContext(override val identity: String = java.util.UUID.randomUUID().toString()) : BridgeUIContext {
    private var valid = true
    private val observers = mutableSetOf<() -> Unit>()
    override val isValid get() = valid
    override fun observeInvalidation(action: () -> Unit): BridgeCancellation {
        if (!valid) { action(); return BridgeCancellation {} }
        observers.add(action)
        return BridgeCancellation { observers.remove(action) }
    }
    open fun invalidate() {
        if (!valid) return
        valid = false
        val callbacks = observers.toList()
        observers.clear()
        callbacks.forEach { it() }
    }
}
