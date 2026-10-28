import AerisContracts
import Foundation

/// 每个 Unity 容器独立持有；物理通道由 App 注入，通用层不依赖实际 Unity 产物。
@MainActor public final class UnityIOSNativeHostEntry {
    private let factory: AerisBridgeReceiverFactory
    private let uiContext: BridgeUIContext?
    private var binding: (any AerisUnityChannelBinding)?
    public private(set) var isClosed = false

    public init(
        channel: String, engine: BridgeEngine, unityChannel: any AerisUnityChannel,
        uiContext: BridgeUIContext? = nil, allowedPermissions: Set<String> = [],
        allowedEventTopics: Set<String>? = nil
    ) throws {
        let factory = try AerisBridgeReceiverFactory(
            engine: engine, source: .unity, allowedPermissions: allowedPermissions,
            allowedEventTopics: allowedEventTopics)
        factory.bindUIContext(uiContext)
        do { binding = try unityChannel.bind(factory: factory, channel: channel) } catch {
            factory.bindUIContext(nil)
            uiContext?.invalidate()
            throw error
        }
        self.factory = factory
        self.uiContext = uiContext
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let current = binding
        binding = nil
        current?.close()
        factory.bindUIContext(nil)
        uiContext?.invalidate()
    }

    /// 在实际运行时卸载前调用；App 必须持有并显式提供同一通道服务。
    public static func prepareForUnityUnload(using channel: any AerisUnityChannel) throws {
        try channel.prepareForUnityUnload()
    }
}

#if canImport(UIKit)
    import UIKit

    extension UnityIOSNativeHostEntry {
        public convenience init(
            channel: String, engine: BridgeEngine, unityChannel: any AerisUnityChannel,
            containerViewController: UIViewController, allowedPermissions: Set<String> = [],
            allowedEventTopics: Set<String>? = nil
        ) throws {
            try self.init(
                channel: channel, engine: engine, unityChannel: unityChannel,
                uiContext: BridgeUIContext(containerViewController: containerViewController),
                allowedPermissions: allowedPermissions, allowedEventTopics: allowedEventTopics)
        }
    }
#endif
