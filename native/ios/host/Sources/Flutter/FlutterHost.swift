import Aeris
import Flutter
import Foundation
import aeris_flutter

#if canImport(UIKit)
    import UIKit
#endif

/// 绑定已经启动并注册插件的实际 Registry，不启动或销毁项目的 FlutterEngine。
@MainActor public final class FlutterHost {
    public let receiverFactory: AerisHostReceiverFactory
    private var binding: (any AerisFlutterModuleBinding)?

    public init(
        configuration: AerisHostConfiguration, registry: any FlutterPluginRegistry,
        uiContext: BridgeUIContext? = nil
    ) throws {
        receiverFactory = try AerisHostReceiverFactory(
            configuration: configuration, source: .flutter, uiContext: uiContext)
        let key =
            registry.hasPlugin(AerisFlutterBridgePluginKey)
            ? AerisFlutterBridgePluginKey : AerisFlutterLegacyBridgePluginKey
        guard registry.hasPlugin(key),
            let plugin = registry.valuePublished(byPlugin: key) as? any AerisFlutterModuleBinding
        else {
            receiverFactory.close()
            throw BridgeFailure("PLUGIN_NOT_REGISTERED", "Register the plugin on this engine first")
        }
        let receiver = receiverFactory.makeReceiver { [weak plugin] text in
            plugin?.emitMessage(toDart: text)
        }
        plugin.bindReceiver(receiver)
        binding = plugin
    }

    #if canImport(UIKit)
        public convenience init(
            configuration: AerisHostConfiguration, registry: any FlutterPluginRegistry,
            containerViewController: UIViewController
        ) throws {
            try self.init(
                configuration: configuration, registry: registry,
                uiContext: BridgeUIContext(containerViewController: containerViewController))
        }
    #endif

    public func close() {
        receiverFactory.close()
        binding?.close()
        binding = nil
    }
}
