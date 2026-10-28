import Aeris

/// 每个容器单独配置权限；Engine 由 App 注入，生产通常使用 shared。
@MainActor public struct AerisHostConfiguration {
    public let engine: BridgeEngine
    public let allowedPermissions: Set<String>
    public let allowedEventTopics: Set<String>?

    public init(
        engine: BridgeEngine, allowedPermissions: Set<String> = [],
        allowedEventTopics: Set<String>? = nil
    ) {
        self.engine = engine
        self.allowedPermissions = allowedPermissions
        self.allowedEventTopics = allowedEventTopics
    }
}
