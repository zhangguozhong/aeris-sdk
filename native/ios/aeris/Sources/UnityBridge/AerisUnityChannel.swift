import AerisContracts
import Foundation

/// 宿主实现的 Unity 通道服务；每次 bind 返回独立绑定，不保存业务请求。
@MainActor public protocol AerisUnityChannel: AnyObject {
    /// 绑定失败须回滚本次资源；重复 channel 失败不得影响已经存在的绑定。
    func bind(factory: any AerisMessageReceiverFactory, channel: String) throws
        -> any AerisUnityChannelBinding

    /// 全部 C# owner、容器及业务资源清理完成后，由 App 执行全局卸载屏障。
    func prepareForUnityUnload() throws
}

/// 每个容器独立持有；close 须幂等，先封闭物理收发，再关闭 receiver 并释放工厂。
@MainActor public protocol AerisUnityChannelBinding: AnyObject { func close() }
