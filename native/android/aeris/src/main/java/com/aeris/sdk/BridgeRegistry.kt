package com.aeris.sdk

import java.lang.reflect.InvocationTargetException
import java.lang.reflect.Method
import java.lang.reflect.Modifier

internal data class ResolvedBridgeInvocation(
    val target: BridgeModule,
    val method: Method,
    val permissions: Set<String>,
) {
    fun invoke(session: BridgeSession) {
        try {
            method.invoke(target, session)
        } catch (error: InvocationTargetException) {
            val reason = error.targetException
            if (reason is BridgeFailure) session.fail(reason.code, reason.message)
            else session.fail("INTERNAL_ERROR", "业务 Bridge 执行失败")
        } catch (error: Exception) {
            session.fail("INTERNAL_ERROR", "业务 Bridge 调用失败")
        }
    }
}

internal class BridgeRegistry {
    var defaultModuleName = "DefaultBridge"
        private set
    var revision = 0
        private set
    private val modules = mutableMapOf<String, Map<String, ResolvedBridgeInvocation>>()

    fun configureDefaultModule(name: String) {
        if (!BridgeCodec.validName(name) || name == "bridge") throw BridgeFailure("INVALID_MODULE", "无效默认模块名")
        defaultModuleName = name
    }

    fun register(module: BridgeModule) {
        val name = module.moduleName
        if (!BridgeCodec.validName(name) || name == "bridge") throw BridgeFailure("INVALID_MODULE", "无效模块名")
        if (modules.containsKey(name)) throw BridgeFailure("DUPLICATE_MODULE", name)
        val exported = mutableMapOf<String, ResolvedBridgeInvocation>()
        module.javaClass.methods.forEach { method ->
            val annotation = method.getAnnotation(BridgeMethod::class.java) ?: return@forEach
            if (!BridgeCodec.validName(method.name) || Modifier.isStatic(method.modifiers) ||
                method.parameterTypes.toList() != listOf(BridgeSession::class.java) || method.returnType != Void.TYPE)
                throw BridgeFailure("INVALID_SELECTOR", "需要单个 BridgeSession 参数并返回 Unit")
            if (exported.containsKey(method.name)) throw BridgeFailure("INVALID_SELECTOR", "重复导出方法")
            method.isAccessible = true
            exported[method.name] = ResolvedBridgeInvocation(
                module, method, module.requiredPermissions.toSet() + annotation.permission.takeIf { it.isNotEmpty() }.let { setOfNotNull(it) },
            )
        }
        modules[name] = exported.toMap()
        revision++
    }

    fun resolve(raw: String): Pair<String, ResolvedBridgeInvocation> {
        if (!BridgeCodec.validMethod(raw)) throw BridgeFailure("INVALID_METHOD", "无效方法名")
        val module = if (raw.contains('.')) raw.substringBefore('.') else defaultModuleName
        val name = raw.substringAfterLast('.')
        val canonical = "$module.$name"
        return canonical to (modules[module]?.get(name) ?: throw BridgeFailure("METHOD_NOT_FOUND", canonical))
    }
}
