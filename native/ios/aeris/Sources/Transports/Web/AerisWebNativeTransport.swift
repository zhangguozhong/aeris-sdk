import Foundation

/// Web 端点，共用协议和生命周期逻辑由 AerisNativeTransport 实现。
@MainActor @objc(AerisWebNativeTransport)
public final class AerisWebNativeTransport: AerisNativeTransport {
    public init(
        engine: BridgeEngine, allowedPermissions: Set<String> = [],
        allowedEventTopics: Set<String>? = nil,
        uiContextProvider: @escaping @MainActor () -> BridgeUIContext? = { nil },
        emit: @escaping (String) -> Void
    ) {
        super.init(
            engine: engine, source: .web, allowedPermissions: allowedPermissions,
            allowedEventTopics: allowedEventTopics, uiContextProvider: uiContextProvider, emit: emit
        )
    }
}
