package com.aeris.sdk

import com.google.gson.JsonObject

interface BridgeEventProvider {
    fun start(publish: (JsonObject) -> Unit)

    fun stop()
}

/** 可选的同步状态快照供每个新订阅使用；后续变化仍通过 start 注入的 publish 回调发送。 */
interface BridgeSnapshotEventProvider : BridgeEventProvider {
    fun snapshot(): JsonObject
}

/** 按上下文观察，在保持原有全局 start/stop 契约兼容的前提下扩展。 */
interface BridgeContextEventProvider : BridgeEventProvider {
    fun observe(context: BridgeUIContext?, publish: (JsonObject) -> Unit): BridgeEventObservation

    override fun start(publish: (JsonObject) -> Unit) {
        throw BridgeFailure("UI_UNAVAILABLE", "Context required")
    }

    override fun stop() = Unit
}

class BridgeEventObservation(val initial: JsonObject, cancel: () -> Unit) {
    private var cancellation: (() -> Unit)? = cancel

    fun cancel() {
        val action = cancellation
        cancellation = null
        action?.invoke()
    }
}

enum class BridgeEventScope {
    GLOBAL,
    CONTEXT,
}

/** 状态快照合并为最新值；业务事实保持发布顺序，沿用同一事件协议。 */
enum class BridgeEventDelivery {
    LATEST,
    ORDERED,
}

/** 只暂存已经校验的数据；确认窗口和同步重入均有独立的数量、字节预算。 */
internal class BridgeEventBuffer(private val delivery: BridgeEventDelivery) {
    private val values = java.util.ArrayDeque<Pair<JsonObject, Int>>()
    private var bytes = 0
    val isEmpty
        get() = values.isEmpty()

    fun append(data: JsonObject): Boolean {
        val size = BridgeCodec.size(data.toString())
        if (delivery == BridgeEventDelivery.LATEST) clear()
        if (values.size >= 32 || size > 1024 * 1024 - bytes) return false
        values.addLast(data to size)
        bytes += size
        return true
    }

    fun pop(): JsonObject? {
        val value = values.pollFirst() ?: return null
        bytes -= value.second
        return value.first
    }

    fun clear() {
        values.clear()
        bytes = 0
    }
}

internal class BridgeSubscription(
    val id: String,
    val topic: String,
    val connection: BridgeConnection,
    delivery: BridgeEventDelivery,
) {
    var sequence = 0L
    var activated = false
    var activating = false
    val pending = BridgeEventBuffer(delivery)
}

internal class BridgeEventHub(private val engine: BridgeEngine) {
    private class Topic(
        val provider: BridgeEventProvider?,
        val scope: BridgeEventScope,
        val permissions: Set<String>,
        val delivery: BridgeEventDelivery,
    ) {
        val groups = mutableMapOf<String?, Group>()
    }

    private class Group(val context: BridgeUIContext?, val delivery: BridgeEventDelivery) {
        val subscribers = mutableSetOf<BridgeSubscription>()
        var started = false
        var epoch = 0L
        var observation: BridgeEventObservation? = null
        var invalidation: BridgeCancellation? = null
        var latest: JsonObject? = null
        var failure: BridgeFailure? = null
        var publishing = false
        val pending = BridgeEventBuffer(delivery)
    }

    private val topics = mutableMapOf<String, Topic>()

    fun register(
        topic: String,
        provider: BridgeEventProvider?,
        scope: BridgeEventScope,
        permissions: Set<String>,
        delivery: BridgeEventDelivery? = null,
    ) {
        if (topic.length !in 1..256 || !Regex("^[A-Za-z][A-Za-z0-9_.-]*$").matches(topic))
            throw BridgeFailure("INVALID_ARGUMENT", "无效事件 topic")
        if (
            scope == BridgeEventScope.CONTEXT &&
                provider != null &&
                provider !is BridgeContextEventProvider
        )
            throw BridgeFailure("INVALID_ARGUMENT", "CONTEXT topic 请使用带 uiContext 的显式发布")
        if (topics.containsKey(topic)) throw BridgeFailure("DUPLICATE_TOPIC", topic)
        topics[topic] =
            Topic(
                provider,
                scope,
                permissions.toSet(),
                delivery
                    ?: if (provider == null) BridgeEventDelivery.ORDERED
                    else BridgeEventDelivery.LATEST,
            )
    }

    fun subscribe(connection: BridgeConnection, params: JsonObject): Pair<String, () -> Unit> {
        val topic =
            BridgeCodec.string(params, "topic")
                ?: throw BridgeFailure("INVALID_ARGUMENT", "缺少 topic")
        val id =
            BridgeCodec.string(params, "subscriptionId")
                ?: throw BridgeFailure("INVALID_ARGUMENT", "缺少 subscriptionId")
        if (params.keySet() != setOf("topic", "subscriptionId") || !connection.accepts(id))
            throw BridgeFailure("INVALID_ARGUMENT", "无效订阅参数")
        val entry = topics[topic] ?: throw BridgeFailure("TOPIC_NOT_FOUND", topic)
        if (
            connection.allowedTopics?.contains(topic) == false ||
                !connection.permissions.containsAll(entry.permissions)
        )
            throw BridgeFailure("PERMISSION_DENIED", "连接无权订阅 topic")
        val context = if (entry.scope == BridgeEventScope.CONTEXT) connection.uiContext else null
        if (entry.scope == BridgeEventScope.CONTEXT && context?.isValid != true)
            throw BridgeFailure("UI_UNAVAILABLE", "缺少有效容器上下文")
        if (connection.subscriptions.containsKey(id))
            throw BridgeFailure("DUPLICATE_SUBSCRIPTION", id)
        if (connection.subscriptions.size >= 128)
            throw BridgeFailure("TOO_MANY_SUBSCRIPTIONS", "订阅超过预算")
        val key = context?.identity
        val group =
            entry.groups[key] ?: Group(context, entry.delivery).also { entry.groups[key] = it }
        group.failure?.let { throw it }
        val subscription = BridgeSubscription(id, topic, connection, entry.delivery)
        connection.subscriptions[id] = subscription
        group.subscribers.add(subscription)
        engine.diagnostics.change(BridgeDiagnosticGauge.SUBSCRIPTIONS, 1)
        if (context != null && group.invalidation == null) {
            val cancellation =
                context.observeInvalidation {
                    engine.dispatcher.execute {
                        if (entry.groups[key] === group)
                            fail(entry, group, BridgeFailure("UI_UNAVAILABLE", "原事件容器已失效"))
                    }
                }
            if (entry.groups[key] === group && group.failure == null)
                group.invalidation = cancellation
            else cancellation.cancel()
        }
        return id to { activate(entry, group, subscription) }
    }

    private fun activate(entry: Topic, group: Group, subscription: BridgeSubscription) {
        val connection = subscription.connection
        if (!current(entry, group, subscription) || connection.isClosed || subscription.activated)
            return
        subscription.activated = true
        subscription.activating = true
        try {
            group.failure?.let {
                terminate(subscription, it)
                return
            }
            if (group.context?.isValid == false) {
                fail(entry, group, BridgeFailure("UI_UNAVAILABLE", "原事件容器已失效"))
                return
            }
            startProvider(entry, group, subscription)
            if (!current(entry, group, subscription)) return
            group.failure?.let {
                terminate(subscription, it)
                return
            }
            val snapshot =
                entry.provider is BridgeSnapshotEventProvider ||
                    entry.provider is BridgeContextEventProvider
            if (subscription.pending.isEmpty && snapshot)
                group.latest?.let { sendData(subscription, it) }
            while (current(entry, group, subscription) && !connection.isClosed) {
                val data = subscription.pending.pop() ?: break
                sendData(subscription, data)
            }
        } finally {
            subscription.activating = false
        }
    }

    private fun startProvider(entry: Topic, group: Group, subscription: BridgeSubscription) {
        val provider = entry.provider ?: return
        if (group.started) return
        group.started = true
        val epoch = ++group.epoch
        val publish: (JsonObject) -> Unit = { data ->
            // 原生对象可能有环或极深嵌套，先限制深度再复制；状态变更仍回到 dispatcher。
            val failure = validationError(data)
            val copy = if (failure == null) data.deepCopy() else null
            engine.dispatcher.execute {
                if (
                    entry.groups[group.context?.identity] === group &&
                        group.started &&
                        group.epoch == epoch &&
                        group.failure == null &&
                        group.context?.isValid != false
                ) {
                    if (failure != null) rejectProvider(entry, group, subscription, failure)
                    else if (copy != null) engine.publish(subscription.topic, copy, group.context)
                }
            }
        }
        try {
            val initial =
                if (provider is BridgeContextEventProvider) {
                    val observation = provider.observe(group.context, publish)
                    if (
                        entry.groups[group.context?.identity] !== group ||
                            !group.started ||
                            group.epoch != epoch
                    ) {
                        observation.cancel()
                        return
                    }
                    group.observation = observation
                    observation.initial
                } else {
                    provider.start(publish)
                    if (provider is BridgeSnapshotEventProvider) provider.snapshot() else null
                }
            if (
                initial != null &&
                    entry.groups[group.context?.identity] === group &&
                    group.started &&
                    group.epoch == epoch
            ) {
                val failure = validationError(initial)
                if (failure != null) rejectProvider(entry, group, subscription, failure)
                else if (group.latest == null) group.latest = initial.deepCopy()
            }
        } catch (_: Exception) {
            // 旧启动栈不能结束同步退订后创建的新分组。
            if (
                entry.groups[group.context?.identity] === group &&
                    group.started &&
                    group.epoch == epoch
            )
                rejectProvider(
                    entry,
                    group,
                    subscription,
                    BridgeFailure("PROVIDER_ERROR", "事件源启动失败"),
                )
        }
    }

    private fun rejectProvider(
        entry: Topic,
        group: Group,
        subscription: BridgeSubscription,
        failure: BridgeFailure,
    ) {
        // 先结束旧分组并提交摘表、计数和终态；观察者可同步关闭或重订，返回后不再触碰旧分组。
        fail(entry, group, failure)
        engine.diagnostics.record(
            BridgeDiagnosticStage.PROVIDER_REJECT,
            connection = subscription.connection,
            topic = subscription.topic,
            code = failure.code,
        )
    }

    fun publish(topic: String, data: JsonObject, context: BridgeUIContext?): Boolean {
        val entry = topics[topic] ?: return false
        if (entry.scope == BridgeEventScope.CONTEXT && context?.isValid != true) return false
        val key = if (entry.scope == BridgeEventScope.CONTEXT) context?.identity else null
        val group = entry.groups[key]
        if (group?.failure != null) return false
        val failure = validationError(data)
        if (failure != null) {
            if (group != null) fail(entry, group, failure)
            return false
        }
        if (group != null) distribute(entry, group, data.deepCopy())
        return true
    }

    private fun validationError(data: JsonObject): BridgeFailure? {
        try {
            BridgeCodec.validatePayload(data)
        } catch (_: Exception) {
            return BridgeFailure("INVALID_EVENT", "无效事件数据")
        }
        return try {
            if (BridgeCodec.size(BridgeCodec.encode(data)) > 250 * 1024)
                BridgeFailure("PAYLOAD_TOO_LARGE", "事件数据超过字节预算")
            else null
        } catch (_: Exception) {
            BridgeFailure("PAYLOAD_TOO_LARGE", "事件数据超过字节预算")
        }
    }

    private fun distribute(entry: Topic, group: Group, data: JsonObject) {
        if (entry.groups[group.context?.identity] !== group || group.failure != null) return
        if (group.publishing) {
            if (!group.pending.append(data))
                fail(entry, group, BridgeFailure("BACKPRESSURE", "事件暂存超过预算"))
            return
        }
        group.publishing = true
        try {
            var next: JsonObject? = data
            while (
                next != null &&
                    entry.groups[group.context?.identity] === group &&
                    group.failure == null
            ) {
                val value = next
                if (entry.delivery != BridgeEventDelivery.LATEST || group.latest != value) {
                    if (entry.provider != null || entry.delivery == BridgeEventDelivery.LATEST)
                        group.latest = value
                    group.subscribers.toList().forEach { subscription ->
                        if (
                            group.failure == null &&
                                current(entry, group, subscription) &&
                                !subscription.connection.isClosed &&
                                !subscription.connection.isClosing
                        ) {
                            if (subscription.activated && !subscription.activating)
                                sendData(subscription, value)
                            else if (!subscription.pending.append(value))
                                fail(entry, group, BridgeFailure("BACKPRESSURE", "事件暂存超过预算"))
                        }
                    }
                }
                next = group.pending.pop()
            }
        } finally {
            group.pending.clear()
            group.publishing = false
        }
    }

    private fun current(entry: Topic, group: Group, subscription: BridgeSubscription) =
        entry.groups[group.context?.identity] === group &&
            group.subscribers.contains(subscription) &&
            subscription.connection.subscriptions[subscription.id] === subscription

    private fun sendData(subscription: BridgeSubscription, data: JsonObject) {
        if (
            subscription.connection.subscriptions[subscription.id] !== subscription ||
                subscription.connection.isClosed
        )
            return
        if (subscription.sequence >= 9_007_199_254_740_990L) {
            terminate(subscription, BridgeFailure("PROTOCOL_ERROR", "事件序号耗尽"))
            return
        }
        subscription.connection.sendEvent(
            jsonObject(
                "subscriptionId" to subscription.id,
                "seq" to ++subscription.sequence,
                "data" to data.deepCopy(),
            ),
            subscription.id,
            subscription.topic,
        )
    }

    private fun fail(entry: Topic, group: Group, failure: BridgeFailure) {
        if (entry.groups[group.context?.identity] !== group || group.failure != null) return
        group.failure = failure
        group.pending.clear()
        stopProvider(entry, group)
        group.subscribers.toList().forEach { terminate(it, failure) }
    }

    private fun terminate(subscription: BridgeSubscription, failure: BridgeFailure) {
        if (subscription.connection.subscriptions[subscription.id] !== subscription) return
        subscription.pending.clear()
        // 成功确认尚未发出时保留条目；激活后再发送唯一终态，不分配被合并数据的序号。
        if (!subscription.activated) return
        val sequence = subscription.sequence + 1
        remove(subscription, discardQueued = false)
        subscription.connection.sendEvent(
            jsonObject(
                "subscriptionId" to subscription.id,
                "seq" to sequence,
                "error" to jsonObject("code" to failure.code, "message" to failure.message),
            ),
            subscription.id,
            subscription.topic,
        )
    }

    fun unsubscribe(connection: BridgeConnection, id: String): Boolean {
        val subscription = connection.subscriptions[id] ?: return false
        remove(subscription)
        return true
    }

    private fun stopProvider(entry: Topic, group: Group) {
        val observation = group.observation
        group.observation = null
        val wasStarted = group.started
        group.started = false
        group.epoch++
        runCatching { observation?.cancel() }
        if (wasStarted && entry.provider !is BridgeContextEventProvider)
            runCatching { entry.provider?.stop() }
    }

    private fun remove(subscription: BridgeSubscription, discardQueued: Boolean = true) {
        val connection = subscription.connection
        if (connection.subscriptions[subscription.id] !== subscription) return
        connection.subscriptions.remove(subscription.id)
        engine.diagnostics.change(BridgeDiagnosticGauge.SUBSCRIPTIONS, -1)
        subscription.pending.clear()
        if (discardQueued) engine.outbound.remove(connection, subscription.id)
        val entry = topics[subscription.topic] ?: return
        val key =
            if (entry.scope == BridgeEventScope.CONTEXT) connection.uiContext?.identity else null
        val group = entry.groups[key] ?: return
        group.subscribers.remove(subscription)
        if (group.subscribers.isEmpty()) {
            // 先摘除分组，再调用可能同步退订、重订或发布的宿主清理函数。
            entry.groups.remove(key)
            group.pending.clear()
            group.invalidation?.cancel()
            group.invalidation = null
            stopProvider(entry, group)
        }
    }

    fun detach(connection: BridgeConnection) {
        connection.subscriptions.values.toList().forEach { remove(it) }
    }
}
