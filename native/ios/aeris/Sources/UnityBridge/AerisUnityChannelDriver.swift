/// 向实际运行时提供接收器；绑定关闭后返回 nil，不再创建连接。
public typealias AerisUnityReceiverBuilder =
    @MainActor (@escaping (String) -> Void) -> AerisUnityReceiver?

/// App 只实现实际 UnityFramework 的绑定、关闭及卸载接口接线。
@MainActor public protocol AerisUnityChannelDriver: AnyObject {
    /// 成功返回物理关闭闭包；失败须先回滚本次物理资源再抛错。
    func bind(channel: String, makeReceiver: @escaping AerisUnityReceiverBuilder) throws
        -> @MainActor () -> Void

    /// App 完成全部容器及业务资源清理后，显式执行全局卸载屏障。
    func prepareForUnityUnload() throws
}
