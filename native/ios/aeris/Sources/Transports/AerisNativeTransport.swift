import AerisContracts
import Foundation

/// 处理共用协议和连接生命周期，每个实例持有独立端点。
/// 公开类型供具体 Transport 引用，构造和继承仍限制在 Aeris 内部。
@MainActor @objc(AerisNativeTransport)
public class AerisNativeTransport: NSObject, AerisClosingMessageReceiver {
    private let engine: BridgeEngine
    private let source: BridgeSource
    private let allowedPermissions: Set<String>
    private let allowedEventTopics: Set<String>?
    private let uiContextProvider: @MainActor () -> BridgeUIContext?
    private let emit: (String) -> Void
    private var connection: BridgeConnection?
    private var invalidated = false
    private var closing = false
    private var notifyingDisconnect = false
    private var retiredPrefixes: Set<String> = []

    // 平台子类提供固定的原生 source，客户端无法构造任意来源的基类实例，
    // 也无法覆盖入站和关闭流程。
    init(
        engine: BridgeEngine, source: BridgeSource, allowedPermissions: Set<String> = [],
        allowedEventTopics: Set<String>?,
        uiContextProvider: @escaping @MainActor () -> BridgeUIContext?,
        emit: @escaping (String) -> Void
    ) {
        self.engine = engine
        self.source = source
        self.allowedPermissions = allowedPermissions
        self.allowedEventTopics = allowedEventTopics
        self.uiContextProvider = uiContextProvider
        self.emit = emit
        super.init()
        connection = openConnection()
    }

    private func openConnection() -> BridgeConnection {
        engine.makeConnection(
            source: source, uiContext: uiContextProvider(), allowedPermissions: allowedPermissions,
            allowedEventTopics: allowedEventTopics
        ) { [weak self] text in self?.emit(text) }
    }

    @objc public final func receiveMessage(_ text: String) {
        guard !invalidated, !notifyingDisconnect else { return }
        do {
            let message = try BridgeCodec.decode(text)
            if connection?.isClosed != false {
                // 两阶段关闭期间，关闭或错误后的连接不能被新 hello 自动重开。
                guard !closing else { return }
                if let old = connection?.clientPrefix { retiredPrefixes.insert(old) }
                guard message.fields["method"] as? String == "bridge.hello",
                    let id = message.fields["callbackId"] as? String,
                    let prefix = BridgeConnection.prefix(of: id), !retiredPrefixes.contains(prefix)
                else { return }
                // 已失效的命名空间属于当前物理端点，不能移除记录后重新启用。
                // 达到既有限额时关闭当前 Transport。
                guard retiredPrefixes.count < 128 else {
                    close()
                    return
                }
                let replacement = openConnection()
                // connectionOpen 诊断回调可以同步重入关闭；新连接不能丢失退出状态。
                guard !invalidated else {
                    replacement.close()
                    return
                }
                if closing { replacement.beginClosing() }
                connection = replacement
            }
            guard let connection else { return }
            connection.updateUIContext(uiContextProvider())
            let session = BridgeSession(message: message, connection: connection)
            engine.handle(session)
        } catch {
            // 故障通知与清理返回前，不允许同步重入的 hello 抢占本次逻辑连接。
            notifyingDisconnect = true
            defer { notifyingDisconnect = false }
            connection?.failDisconnected()  // 仅通知并清理当前逻辑连接，保留新前缀重连。
        }
    }

    @objc public final func beginClosing() {
        guard !invalidated else { return }
        closing = true
        connection?.beginClosing()
    }

    @objc public final func close() {
        invalidated = true
        connection?.close()
        connection = nil
    }
}
