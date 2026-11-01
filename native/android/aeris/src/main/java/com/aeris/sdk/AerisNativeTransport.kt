package com.aeris.sdk

/** Native 唯一收发入口，反序列化后只创建 Session 并交给 Engine。 */
open class AerisNativeTransport(
    private val engine: BridgeEngine,
    private val source: BridgeSource,
    private val uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
    private val emit: (String) -> Unit,
) : AerisMessageReceiver {
    private val permissions = allowedPermissions.toSet()
    private val topics = allowedEventTopics?.toSet()
    private var invalidated = false
    private var closing = false
    @Volatile private var notifyingDisconnect = false
    @Volatile private var replacingConnection = false
    private var physicalError: BridgeFailure? = null
    private val physicalCloseObservers = mutableSetOf<(BridgeFailure?) -> Unit>()
    private val retiredPrefixes = mutableSetOf<String>()
    @Volatile private var currentConnection = openConnection()
    val connection
        get() = currentConnection

    private fun openConnection() =
        engine.makeConnection(source, uiContext, permissions, topics) { text ->
            try {
                emit(text)
            } catch (error: Exception) {
                // 发送器异常表示物理通道已失效，不允许通过新 hello 恢复。
                closePhysical(BridgeFailure("DISCONNECTED", "Native 发送器不可用"))
                throw error
            }
        }

    /** 保留既有语义：仅观察注册时的逻辑连接，重连后需重新注册。 */
    override fun observeClosed(listener: (BridgeFailure?) -> Unit): BridgeCancellation =
        connection.observeClosed(listener)

    /** 宿主组合层仅订阅物理终态，避免逻辑故障误销毁容器。 */
    internal fun observePhysicalClosed(listener: (BridgeFailure?) -> Unit): BridgeCancellation {
        engine.dispatcher.checkThread()
        if (invalidated) {
            listener(physicalError)
            return BridgeCancellation {}
        }
        physicalCloseObservers.add(listener)
        return BridgeCancellation { physicalCloseObservers.remove(listener) }
    }

    override fun receiveMessage(message: String) = receive(message)

    fun receive(message: String) {
        // 在关闭通知内提交到排队 dispatcher 的 hello 也必须被拒绝。
        if (notifyingDisconnect || replacingConnection || connection.isNotifyingClose) return
        engine.dispatcher.execute {
            if (
                invalidated ||
                    notifyingDisconnect ||
                    replacingConnection ||
                    connection.isNotifyingClose
            )
                return@execute
            var receivingConnection = connection
            try {
                val decoded = BridgeCodec.decode(message)
                if (connection.isClosed) {
                    if (closing) return@execute
                    connection.clientPrefix?.let(retiredPrefixes::add)
                    if (BridgeCodec.string(decoded, "method") != "bridge.hello") return@execute
                    val prefix =
                        BridgeCodec.string(decoded, "callbackId")?.let(BridgeCodec::prefix)
                            ?: return@execute
                    if (prefix in retiredPrefixes) return@execute
                    // 失效命名空间不淘汰；达到边界后物理端点进入终态。
                    if (retiredPrefixes.size >= 128) {
                        closePhysical(null)
                        return@execute
                    }
                    // 创建期间的诊断允许回调，但不能重入创建另一条未被持有的连接。
                    replacingConnection = true
                    try {
                        val replacement = openConnection()
                        if (invalidated) {
                            replacement.close()
                            return@execute
                        }
                        if (closing) replacement.beginClosing()
                        currentConnection = replacement
                    } finally {
                        replacingConnection = false
                    }
                }
                receivingConnection = connection
                engine.handle(BridgeSession(decoded, receivingConnection))
            } catch (error: Exception) {
                // 固定本次入站所属连接，并在诊断观察者重入前封住恢复入口。
                notifyingDisconnect = true
                try {
                    engine.diagnostics.record(
                        BridgeDiagnosticStage.REQUEST_REJECT,
                        receivingConnection,
                        code = (error as? BridgeFailure)?.code ?: "INVALID_ARGUMENT",
                    )
                    receivingConnection.fail("DISCONNECTED", "Native Transport 拒绝无效输入")
                } finally {
                    notifyingDisconnect = false
                }
            }
        }
    }

    override fun beginClosing() {
        engine.dispatcher.execute {
            if (!invalidated) {
                closing = true
                connection.beginClosing()
            }
        }
    }

    override fun close() {
        engine.dispatcher.execute { closePhysical(null) }
    }

    private fun closePhysical(error: BridgeFailure?) {
        if (invalidated) return
        invalidated = true
        physicalError = error
        val observers = physicalCloseObservers.toList()
        physicalCloseObservers.clear()
        if (error == null) connection.close()
        else connection.fail(error.code, error.message ?: "Native 发送器不可用")
        observers.forEach { observer -> runCatching { observer(error) } }
    }
}

class AerisRNNativeTransport(
    engine: BridgeEngine,
    uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
    emit: (String) -> Unit,
) :
    AerisNativeTransport(
        engine,
        BridgeSource.REACT_NATIVE,
        uiContext,
        allowedPermissions,
        allowedEventTopics,
        emit,
    )

class AerisWebNativeTransport(
    engine: BridgeEngine,
    uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
    emit: (String) -> Unit,
) :
    AerisNativeTransport(
        engine,
        BridgeSource.WEB,
        uiContext,
        allowedPermissions,
        allowedEventTopics,
        emit,
    )

class AerisFlutterNativeTransport(
    engine: BridgeEngine,
    uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
    emit: (String) -> Unit,
) :
    AerisNativeTransport(
        engine,
        BridgeSource.FLUTTER,
        uiContext,
        allowedPermissions,
        allowedEventTopics,
        emit,
    )

class AerisUnityNativeTransport(
    engine: BridgeEngine,
    uiContext: BridgeUIContext? = null,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
    emit: (String) -> Unit,
) :
    AerisNativeTransport(
        engine,
        BridgeSource.UNITY,
        uiContext,
        allowedPermissions,
        allowedEventTopics,
        emit,
    )
