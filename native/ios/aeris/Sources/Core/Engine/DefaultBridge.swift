import Foundation

/// 可选的中立默认对象，由宿主注册，也可通过扩展添加 @objc 方法。
/// 当前类型及 Engine 都不会自动安装业务服务或授予业务权限。
@MainActor public final class DefaultBridge: NSObject, BridgeModule {
    public static let name = "DefaultBridge"
    public let moduleName = DefaultBridge.name

    public override init() { super.init() }
}
