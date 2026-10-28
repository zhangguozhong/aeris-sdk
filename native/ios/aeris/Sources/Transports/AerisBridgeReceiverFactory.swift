import AerisContracts
import Foundation

/// 每个实际容器独立持有工厂，Engine 由宿主注入，source 不读取协议数据。
/// 每次 makeReceiver 均创建新的具体 Transport 和独立 Connection。
@MainActor @objc(AerisBridgeReceiverFactory)
public final class AerisBridgeReceiverFactory: NSObject, AerisMessageReceiverFactory {
    public let source: BridgeSource
    private let engine: BridgeEngine
    private let allowedPermissions: Set<String>
    private let allowedEventTopics: Set<String>?
    private var uiContext: BridgeUIContext?

    public init(
        engine: BridgeEngine, source: BridgeSource, allowedPermissions: Set<String> = [],
        allowedEventTopics: Set<String>? = nil
    ) throws {
        switch source {
        case .web, .reactNative, .flutter, .unity: break
        case .unknown, .cocos:
            throw BridgeFailure(
                "UNSUPPORTED_SOURCE", "No Transport is implemented for source \(source.rawValue)")
        }
        self.engine = engine
        self.source = source
        self.allowedPermissions = allowedPermissions
        self.allowedEventTopics = allowedEventTopics
        super.init()
    }

    public func bindUIContext(_ context: BridgeUIContext?) {
        if uiContext !== context {
            uiContext?.invalidate()
            uiContext = context
        }
    }

    @objc(makeReceiverWithEmitter:) public func makeReceiver(emitter: @escaping (String) -> Void)
        -> any AerisMessageReceiver
    {
        // 已有 Session 保留原上下文，新请求通过此弱引用提供器获取最新绑定。
        let contextProvider: @MainActor () -> BridgeUIContext? = { [weak self] in self?.uiContext }
        switch source {
        case .reactNative:
            return AerisRNNativeTransport(
                engine: engine, allowedPermissions: allowedPermissions,
                allowedEventTopics: allowedEventTopics, uiContextProvider: contextProvider,
                emit: emitter)
        case .flutter:
            return AerisFlutterNativeTransport(
                engine: engine, allowedPermissions: allowedPermissions,
                allowedEventTopics: allowedEventTopics, uiContextProvider: contextProvider,
                emit: emitter)
        case .web:
            return AerisWebNativeTransport(
                engine: engine, allowedPermissions: allowedPermissions,
                allowedEventTopics: allowedEventTopics, uiContextProvider: contextProvider,
                emit: emitter)
        case .unity:
            return AerisUnityNativeTransport(
                engine: engine, allowedPermissions: allowedPermissions,
                allowedEventTopics: allowedEventTopics, uiContextProvider: contextProvider,
                emit: emitter)
        case .unknown, .cocos:
            // 构造工厂之前已经校验不可变的 source。
            preconditionFailure("Unsupported source escaped factory construction validation")
        }
    }
}
