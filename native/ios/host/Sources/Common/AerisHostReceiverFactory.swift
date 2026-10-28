import Aeris
import AerisContracts
import Foundation

/// 每个容器独立持有；只组装现有工厂并管理生命周期，不新增引擎或注册表。
@MainActor @objc(AerisHostReceiverFactory)
public final class AerisHostReceiverFactory: NSObject, AerisMessageReceiverFactory {
    private let factory: AerisBridgeReceiverFactory
    private let uiContext: BridgeUIContext?
    // 工厂持有可关闭的接收器，调用方提前丢弃引用也不会遗留连接。
    private var receivers: [UUID: ManagedReceiver] = [:]
    public private(set) var isClosed = false

    public init(
        configuration: AerisHostConfiguration, source: BridgeSource,
        uiContext: BridgeUIContext? = nil
    ) throws {
        factory = try AerisBridgeReceiverFactory(
            engine: configuration.engine, source: source,
            allowedPermissions: configuration.allowedPermissions,
            allowedEventTopics: configuration.allowedEventTopics)
        self.uiContext = uiContext
        super.init()
        factory.bindUIContext(uiContext)
    }

    @objc(makeReceiverWithEmitter:) public func makeReceiver(emitter: @escaping (String) -> Void)
        -> any AerisMessageReceiver
    {
        // 接口不能抛错，关闭后返回无效接收器，不再创建连接。
        guard !isClosed else { return ManagedReceiver(nil) }
        let token = UUID()
        let receiver = ManagedReceiver(
            factory.makeReceiver { [weak self] text in
                guard let self, !self.isClosed else { return }
                emitter(text)
            }, onClose: { [weak self] in self?.receivers.removeValue(forKey: token) })
        // 诊断观察器等同步调用可能在创建连接时重入关闭宿主。
        guard !isClosed else {
            receiver.close()
            return receiver
        }
        receivers[token] = receiver
        return receiver
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let current = Array(receivers.values)
        receivers.removeAll()
        for receiver in current { receiver.close() }
        factory.bindUIContext(nil)
        uiContext?.invalidate()
    }

    @MainActor private final class ManagedReceiver: NSObject, AerisClosingMessageReceiver {
        private var receiver: (any AerisMessageReceiver)?
        private var onClose: (() -> Void)?
        init(_ receiver: (any AerisMessageReceiver)?, onClose: (() -> Void)? = nil) {
            self.receiver = receiver
            self.onClose = onClose
        }
        func receiveMessage(_ message: String) { receiver?.receiveMessage(message) }
        func beginClosing() { (receiver as? any AerisClosingMessageReceiver)?.beginClosing() }
        func close() {
            let current = receiver
            let completion = onClose
            receiver = nil
            onClose = nil
            current?.close()
            // 插件正常关闭时立即移除，重载不积累已关闭的接收器。
            completion?()
        }
    }
}
