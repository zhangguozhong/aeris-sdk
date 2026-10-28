import Foundation

@MainActor public final class BridgeEventObservation {
    public let initial: [String: Any]
    private var stop: (() -> Void)?
    public init(initial: [String: Any], cancel: @escaping () -> Void) {
        self.initial = initial
        stop = cancel
    }
    public func cancel() {
        let action = stop
        stop = nil
        action?()
    }
}
@MainActor public protocol BridgeEventProvider: AnyObject {
    /// 仅生成快照，注入的数据接收器通过所属 Engine 发布变化。
    func observe(context: BridgeUIContext?, emit: @escaping @MainActor ([String: Any]) -> Void)
        throws -> BridgeEventObservation
}

/// 注册元数据独立于业务 topic 名称及客户端协议字段。
public enum BridgeEventScope: Sendable { case global, uiContext }
/// 状态变化可合并，业务事实按序保留；均沿用同一事件协议。
public enum BridgeEventDelivery: Sendable { case latest, ordered }

/// 只暂存已经校验的数据；重入和订阅确认窗口均有数量与字节上限。
@MainActor private final class BridgeEventBuffer {
    let delivery: BridgeEventDelivery
    private var values: [([String: Any], Int)] = []
    private var bytes = 0
    init(_ delivery: BridgeEventDelivery) { self.delivery = delivery }
    var isEmpty: Bool { values.isEmpty }
    func append(_ data: [String: Any]) -> Bool {
        guard
            let size = try? JSONSerialization.data(
                withJSONObject: data, options: [.withoutEscapingSlashes]
            ).count
        else { return false }
        if delivery == .latest { clear() }
        guard values.count < 32, size <= 1024 * 1024 - bytes else { return false }
        values.append((data, size))
        bytes += size
        return true
    }
    func pop() -> [String: Any]? {
        guard !values.isEmpty else { return nil }
        let value = values.removeFirst()
        bytes -= value.1
        return value.0
    }
    func clear() {
        values.removeAll()
        bytes = 0
    }
}

enum BridgeEventTopic {
    static func isValid(_ topic: String) -> Bool {
        guard !topic.isEmpty, topic.utf8.count <= 128 else { return false }
        let match = topic.range(
            of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)*$", options: .regularExpression)
        return match == topic.startIndex..<topic.endIndex  // 即使末尾只有换行符也要拒绝。
    }
}

/// 供协议测试或自定义原生数据源使用的确定性实现，系统 Provider 位于 UIKit/Network 层。
@MainActor public final class ManualBridgeEventProvider: BridgeEventProvider {
    private var current: [String: Any]
    private var listeners: [UUID: @MainActor ([String: Any]) -> Void] = [:]
    public init(initial: [String: Any]) { current = initial }
    public func update(_ data: [String: Any]) {
        current = data
        for callback in Array(listeners.values) { callback(data) }
    }
    public func observe(
        context: BridgeUIContext?, emit: @escaping @MainActor ([String: Any]) -> Void
    ) throws -> BridgeEventObservation {
        let id = UUID()
        listeners[id] = emit
        return BridgeEventObservation(initial: current) { [weak self] in
            self?.listeners.removeValue(forKey: id)
        }
    }
}

@MainActor final class BridgeEventHub {
    private struct Registration {
        let provider: (any BridgeEventProvider)?
        let scope: BridgeEventScope
        let delivery: BridgeEventDelivery
    }
    private struct GroupKey: Hashable {
        let topic: String
        let context: ObjectIdentifier?
    }
    private struct Key: Hashable {
        let connection: ObjectIdentifier
        let id: String
    }
    @MainActor private final class Entry {
        weak var connection: BridgeConnection?
        let key: Key, group: GroupKey
        var seq = 0, ready = false, acknowledgementQueued = false, activating = false
        let pending: BridgeEventBuffer
        init(
            _ c: BridgeConnection, _ id: String, _ group: GroupKey, _ delivery: BridgeEventDelivery
        ) {
            pending = BridgeEventBuffer(delivery)
            connection = c
            key = Key(connection: ObjectIdentifier(c), id: id)
            self.group = group
        }
    }
    @MainActor private final class Group {
        let key: GroupKey, context: BridgeUIContext?, snapshot: Bool
        var entries: Set<Key> = [], latest: [String: Any]?
        var observation: BridgeEventObservation?, invalidation: UUID?
        var publishing = false, startupFailure: BridgeFailure?
        let pending: BridgeEventBuffer
        var delivery: BridgeEventDelivery { pending.delivery }
        init(
            _ key: GroupKey, _ context: BridgeUIContext?, snapshot: Bool,
            delivery: BridgeEventDelivery
        ) {
            pending = BridgeEventBuffer(delivery)
            self.key = key
            self.context = context
            self.snapshot = snapshot
        }
    }
    private var registrations: [String: Registration] = [:]
    private var groups: [GroupKey: Group] = [:]
    private var entries: [Key: Entry] = [:]
    private let publishToEngine: @MainActor (String, [String: Any], BridgeUIContext?) -> Void
    init(publishToEngine: @escaping @MainActor (String, [String: Any], BridgeUIContext?) -> Void) {
        self.publishToEngine = publishToEngine
    }
    func register(
        topic: String, provider: (any BridgeEventProvider)? = nil,
        scope: BridgeEventScope = .global, delivery: BridgeEventDelivery? = nil
    ) throws {
        guard BridgeEventTopic.isValid(topic) else {
            throw BridgeFailure("INVALID_ARGUMENT", "Invalid event topic")
        }
        guard registrations[topic] == nil else {
            throw BridgeFailure(provider == nil ? "DUPLICATE_EVENT" : "DUPLICATE_PROVIDER", topic)
        }
        registrations[topic] = Registration(
            provider: provider, scope: scope,
            delivery: delivery ?? (provider == nil ? .ordered : .latest))
    }
    func subscribe(_ c: BridgeConnection, params: [String: Any]) throws -> String {
        guard !c.isClosed else { throw BridgeFailure("DISCONNECTED", "Connection closed") }
        guard let topic = params["topic"] as? String, let id = params["subscriptionId"] as? String,
            c.accepts(id)
        else {
            throw BridgeFailure(
                "INVALID_ARGUMENT", "Expected topic and this client's subscriptionId")
        }
        guard BridgeEventTopic.isValid(topic) else {
            throw BridgeFailure("INVALID_ARGUMENT", "Invalid event topic")
        }
        guard let registration = registrations[topic] else {
            throw BridgeFailure("EVENT_NOT_FOUND", "Native event topic is not registered")
        }
        guard c.allowedEventTopics?.contains(topic) ?? true else {
            throw BridgeFailure("PERMISSION_DENIED", "Event topic denied by host")
        }
        guard c.eventSubscriptionIDs.count < 32 else {
            throw BridgeFailure("TOO_MANY_SUBSCRIPTIONS", "Subscription limit reached")
        }
        let context = registration.scope == .uiContext ? c.uiContext : nil
        if registration.scope == .uiContext, context?.isValid != true {
            throw BridgeFailure("UI_UNAVAILABLE", "Event needs the calling UI context")
        }
        let key = Key(connection: ObjectIdentifier(c), id: id)
        guard entries[key] == nil else {
            throw BridgeFailure("DUPLICATE_SUBSCRIPTION", "Subscription already exists")
        }
        let groupKey = GroupKey(topic: topic, context: context.map(ObjectIdentifier.init))
        let group =
            groups[groupKey]
            ?? Group(
                groupKey, context, snapshot: registration.provider != nil,
                delivery: registration.delivery)
        // 结束消息分发会同步调用 App 接收器，已失败的分组不能接纳新订阅。
        if let failure = group.startupFailure { throw failure }
        let isNew = groups[groupKey] == nil
        groups[groupKey] = group
        let entry = Entry(c, id, groupKey, registration.delivery)
        entries[key] = entry
        group.entries.insert(key)
        c.eventSubscriptionIDs.insert(id)
        c.diagnostics.change(.subscriptions, 1)
        if isNew {
            do {
                if let provider = registration.provider {
                    let observation = try provider.observe(context: context) {
                        [weak self, weak group] data in
                        guard let self, let group, self.groups[group.key] === group else { return }
                        // 进入 Engine 统一发布入口前，先拦截已失效监听的回调。
                        self.publishToEngine(group.key.topic, data, group.context)
                    }
                    guard groups[groupKey] === group, entries[key] === entry else {
                        observation.cancel()  // observe 可能在返回令牌前同步失败或解除绑定。
                        throw group.startupFailure
                            ?? BridgeFailure("EVENT_UNAVAILABLE", "Provider stopped during startup")
                    }
                    group.observation = observation
                    if let error = validationError(observation.initial) { throw error }
                    if group.latest == nil { group.latest = observation.initial }
                }
                // 仅注册 topic 的事件与监听型数据源同样受上下文生命周期约束。
                group.invalidation = context?.observeInvalidation { [weak self, weak group] in
                    guard let self, let group else { return }
                    self.fail(
                        group,
                        error: BridgeFailure(
                            "UI_UNAVAILABLE", "Original event UI context was detached"))
                }
                guard entries[key] === entry else {
                    throw BridgeFailure(
                        "UI_UNAVAILABLE", "Context was detached during subscription")
                }
                if let latest = group.latest, let error = validationError(latest) { throw error }
            } catch {
                remove(key)
                throw error
            }
        }
        return id
    }
    /// 捕获确切条目，避免延迟确认激活具有相同 id 的替代订阅。
    func activation(_ c: BridgeConnection, id: String) -> @MainActor () -> Void {
        let key = Key(connection: ObjectIdentifier(c), id: id)
        let entry = entries[key]
        entry?.acknowledgementQueued = true
        return { [weak self, weak c, weak entry] in
            guard let self, let c, let entry, self.entries[key] === entry else { return }
            self.activate(c, id: id)
        }
    }
    func activate(_ c: BridgeConnection, id: String) {
        let key = Key(connection: ObjectIdentifier(c), id: id)
        guard !c.isClosed, let entry = entries[key], !entry.ready, let group = groups[entry.group]
        else { return }
        entry.ready = true
        entry.activating = true
        defer { entry.activating = false }
        if let error = group.startupFailure {
            terminate(entry, error: error)
            return
        }
        let initial = entry.pending.isEmpty && group.snapshot ? group.latest : nil
        if let initial { emit(entry, data: initial) }
        while let data = entry.pending.pop(), entries[key] === entry, !c.isClosed {
            emit(entry, data: data)
        }  // 必须在当前这条订阅的确认回包之后发送。
    }
    func unsubscribe(_ c: BridgeConnection, id: String) -> Bool {
        let key = Key(connection: ObjectIdentifier(c), id: id)
        guard entries[key] != nil else { return false }
        remove(key)
        return true
    }
    func detach(_ c: BridgeConnection) {
        for id in Array(c.eventSubscriptionIDs) { _ = unsubscribe(c, id: id) }
    }
    @discardableResult func distribute(
        topic: String, data: [String: Any], context: BridgeUIContext?
    ) -> Bool {
        guard BridgeEventTopic.isValid(topic), let registration = registrations[topic] else {
            return false
        }
        guard registration.scope != .uiContext || context?.isValid == true else { return false }
        let key = GroupKey(
            topic: topic,
            context: registration.scope == .uiContext ? context.map(ObjectIdentifier.init) : nil)
        if let group = groups[key], group.startupFailure != nil { return false }
        if let error = validationError(data) {
            if let group = groups[key] { fail(group, error: error) }
            return false
        }
        if let group = groups[key] { distribute(group, data: data) }
        return true
    }
    private func validationError(_ data: [String: Any]) -> BridgeFailure? {
        guard BridgePayloadValidator.valid(data) else {
            return BridgeFailure("INVALID_EVENT", "Invalid event data")
        }
        guard
            let size = try? JSONSerialization.data(
                withJSONObject: data, options: [.withoutEscapingSlashes]
            ).count, size <= 250 * 1024
        else { return BridgeFailure("PAYLOAD_TOO_LARGE", "Event data too large") }
        return nil
    }
    private func distribute(_ group: Group, data: [String: Any]) {
        guard groups[group.key] === group, group.startupFailure == nil else { return }
        // 先完成当前一轮分发；重入数据按注册策略排队，再统一编号。
        if group.publishing {
            if !group.pending.append(data) {
                fail(group, error: BridgeFailure("BACKPRESSURE", "Event pending queue exceeded"))
            }
            return
        }
        group.publishing = true
        var next: [String: Any]? = data
        while let value = next, groups[group.key] === group, group.startupFailure == nil {
            let unchanged =
                group.delivery == .latest
                && (group.latest.map { NSDictionary(dictionary: $0).isEqual(to: value) } ?? false)
            if !unchanged {
                if group.snapshot || group.delivery == .latest { group.latest = value }
                for key in Array(group.entries) {
                    guard let entry = entries[key] else { continue }
                    if entry.ready && !entry.activating {
                        emit(entry, data: value)
                    } else if !entry.pending.append(value) {
                        fail(
                            group,
                            error: BridgeFailure("BACKPRESSURE", "Event pending queue exceeded"))
                        break
                    }
                }
            }
            next = group.pending.pop()
        }
        group.pending.clear()
        group.publishing = false
    }
    private func emit(_ entry: Entry, data: [String: Any]) {
        guard let c = entry.connection, !c.isClosed, entries[entry.key] === entry else {
            remove(entry.key)
            return
        }
        guard entry.seq < 9_007_199_254_740_990 else {
            terminate(entry, error: BridgeFailure("PROTOCOL_ERROR", "Event sequence exhausted"))
            return
        }
        entry.seq += 1
        c.send(
            ["subscriptionId": entry.key.id, "seq": entry.seq, "data": data],
            topic: entry.group.topic)
    }
    private func fail(_ group: Group, error: BridgeFailure) {
        guard groups[group.key] === group, group.startupFailure == nil else { return }
        group.startupFailure = error
        group.pending.clear()
        group.observation?.cancel()
        group.observation = nil
        for key in Array(group.entries) {
            if let entry = entries[key] { terminate(entry, error: error) }
        }
    }
    private func terminate(_ entry: Entry, error: BridgeFailure) {
        // 成功确认已入队时，失败消息必须排在同一确认之后，避免客户端一直等待。
        if !entry.ready, entry.acknowledgementQueued {
            entry.pending.clear()
            return
        }
        let c = entry.connection
        let seq = entry.seq + 1
        let ready = entry.ready
        remove(entry.key)
        if ready {
            c?.send(
                [
                    "subscriptionId": entry.key.id, "seq": seq,
                    "error": ["code": error.code, "message": error.message],
                ], topic: entry.group.topic)
        }
    }
    private func remove(_ key: Key) {
        guard let entry = entries.removeValue(forKey: key) else { return }
        entry.pending.clear()
        entry.connection?.eventSubscriptionIDs.remove(key.id)
        entry.connection?.diagnostics.change(.subscriptions, -1)
        guard let group = groups[entry.group] else { return }
        group.entries.remove(key)
        if group.entries.isEmpty {
            groups.removeValue(forKey: group.key)
            group.context?.removeInvalidationObserver(group.invalidation)
            group.observation?.cancel()
            group.observation = nil
        }
    }
}
