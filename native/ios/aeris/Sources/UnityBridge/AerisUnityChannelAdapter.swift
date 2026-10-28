import AerisContracts

/// 通用接收器及绑定管理归 Pod；App 只注入实际运行时 Driver。
@MainActor public final class AerisUnityChannelAdapter: AerisUnityChannel {
    private let driver: any AerisUnityChannelDriver

    public init(driver: any AerisUnityChannelDriver) { self.driver = driver }

    public func bind(factory: any AerisMessageReceiverFactory, channel: String) throws
        -> any AerisUnityChannelBinding
    {
        let scope = ReceiverScope(factory: factory)
        do {
            let closeNative = try driver.bind(channel: channel) { [scope] emitter in
                scope.makeReceiver(emitter: emitter)
            }
            return Binding(scope: scope, closeNative: closeNative)
        } catch {
            scope.close()
            throw error
        }
    }

    public func prepareForUnityUnload() throws { try driver.prepareForUnityUnload() }

    @MainActor private final class ReceiverScope {
        private var factory: (any AerisMessageReceiverFactory)?
        private var receivers: [ObjectIdentifier: AerisUnityReceiver] = [:]
        private var isSealed = false

        init(factory: any AerisMessageReceiverFactory) { self.factory = factory }

        func makeReceiver(emitter: @escaping (String) -> Void) -> AerisUnityReceiver? {
            guard !isSealed, let factory else { return nil }
            let wrapper = AerisUnityReceiver(emitter: emitter)
            let key = ObjectIdentifier(wrapper)
            receivers[key] = wrapper
            let receiver = factory.makeReceiver { [weak wrapper] in wrapper?.emit($0) }
            // 创建期间可能重入关闭；attach 会立即关闭迟到返回的业务接收器。
            wrapper.attach(receiver) { [weak self] in self?.receivers.removeValue(forKey: key) }
            return isSealed ? nil : wrapper
        }

        func seal() {
            isSealed = true
            for receiver in receivers.values { receiver.seal() }
        }

        func close() {
            seal()
            let current = Array(receivers.values)
            receivers.removeAll()
            factory = nil
            for receiver in current { receiver.close() }
        }
    }

    @MainActor private final class Binding: AerisUnityChannelBinding {
        private let scope: ReceiverScope
        private var closeNative: (@MainActor () -> Void)?

        init(scope: ReceiverScope, closeNative: @escaping @MainActor () -> Void) {
            self.scope = scope
            self.closeNative = closeNative
        }

        func close() {
            guard let closeNative else { return }
            self.closeNative = nil
            scope.seal()
            // 先撤销物理回调；插件可以在此同步关闭部分接收器。
            closeNative()
            // 再兜底关闭剩余接收器，并释放 Factory；重复 close 不会重复清理。
            scope.close()
        }
    }
}
