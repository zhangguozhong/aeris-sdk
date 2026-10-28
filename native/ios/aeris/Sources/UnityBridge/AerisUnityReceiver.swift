import AerisContracts

/// 一次物理连接对应一个接收器；Pod 统一处理幂等关闭、迟到消息和引用释放。
@MainActor public final class AerisUnityReceiver {
    private var receiver: (any AerisMessageReceiver)?
    private var emitter: ((String) -> Void)?
    private var onClose: (() -> Void)?
    private var isClosed = false
    private var isSealed = false

    init(emitter: @escaping (String) -> Void) { self.emitter = emitter }

    func attach(_ receiver: any AerisMessageReceiver, onClose: @escaping () -> Void) {
        guard !isClosed else {
            receiver.close()
            return
        }
        self.receiver = receiver
        self.onClose = onClose
    }

    func emit(_ message: String) { emitter?(message) }

    /// 先停止回传，业务接收器仍在物理通道关闭后才清理。
    func seal() {
        isSealed = true
        emitter = nil
    }

    public func receiveMessage(_ message: String) {
        guard !isClosed, !isSealed else { return }
        receiver?.receiveMessage(message)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let current = receiver
        let completion = onClose
        receiver = nil
        emitter = nil
        onClose = nil
        completion?()
        current?.close()
    }
}
