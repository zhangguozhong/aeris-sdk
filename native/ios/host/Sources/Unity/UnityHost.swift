import Aeris
import Foundation

/// 保留原有 Entry 的容器管理逻辑，实际 Unity 接线由宿主注入。
@MainActor public final class UnityHost {
    private let entry: UnityIOSNativeHostEntry
    public var isClosed: Bool { entry.isClosed }

    public init(
        configuration: AerisHostConfiguration, channel: String, unityChannel: any AerisUnityChannel,
        uiContext: BridgeUIContext? = nil
    ) throws {
        entry = try UnityIOSNativeHostEntry(
            channel: channel, engine: configuration.engine, unityChannel: unityChannel,
            uiContext: uiContext, allowedPermissions: configuration.allowedPermissions,
            allowedEventTopics: configuration.allowedEventTopics)
    }

    public func close() { entry.close() }

    public static func prepareForUnityUnload(using channel: any AerisUnityChannel) throws {
        try UnityIOSNativeHostEntry.prepareForUnityUnload(using: channel)
    }
}

#if canImport(UIKit)
    import UIKit

    extension UnityHost {
        public convenience init(
            configuration: AerisHostConfiguration, channel: String,
            unityChannel: any AerisUnityChannel, containerViewController: UIViewController
        ) throws {
            try self.init(
                configuration: configuration, channel: channel, unityChannel: unityChannel,
                uiContext: BridgeUIContext(containerViewController: containerViewController))
        }
    }
#endif
