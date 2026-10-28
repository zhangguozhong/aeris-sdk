import Aeris
import AerisRN
import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// RN 运行时、bundle 和项目 DependencyProvider 由 App 创建。
@MainActor public final class ReactNativeHost: NSObject {
    public let receiverFactory: AerisHostReceiverFactory

    public init(configuration: AerisHostConfiguration, uiContext: BridgeUIContext? = nil) throws {
        receiverFactory = try AerisHostReceiverFactory(
            configuration: configuration, source: .reactNative, uiContext: uiContext)
        super.init()
    }

    #if canImport(UIKit)
        public convenience init(
            configuration: AerisHostConfiguration, containerViewController: UIViewController
        ) throws {
            try self.init(
                configuration: configuration,
                uiContext: BridgeUIContext(containerViewController: containerViewController))
        }
    #endif

    /// 由当前 RN 工厂委托调用，返回的就是当前运行时实际使用的模块实例。
    @objc public func makeModule() -> any AerisRNModuleBinding {
        let module = AerisCreateUnifiedBridgeModule()
        let receiver = receiverFactory.makeReceiver { [weak module] text in
            module?.emitMessage(toJS: text)
        }
        module.bindReceiver(receiver)
        return module
    }

    public func close() { receiverFactory.close() }
}
