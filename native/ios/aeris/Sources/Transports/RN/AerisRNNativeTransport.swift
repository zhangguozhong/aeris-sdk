import Foundation

/// RN 端点，共用协议和生命周期逻辑由 AerisNativeTransport 实现。
@MainActor @objc(AerisRNNativeTransport)
public final class AerisRNNativeTransport: AerisNativeTransport {
    public init(
        engine: BridgeEngine, allowedPermissions: Set<String> = [],
        allowedEventTopics: Set<String>? = nil,
        uiContextProvider: @escaping @MainActor () -> BridgeUIContext? = { nil },
        emit: @escaping (String) -> Void
    ) {
        super.init(
            engine: engine, source: .reactNative, allowedPermissions: allowedPermissions,
            allowedEventTopics: allowedEventTopics, uiContextProvider: uiContextProvider, emit: emit
        )
    }
}
