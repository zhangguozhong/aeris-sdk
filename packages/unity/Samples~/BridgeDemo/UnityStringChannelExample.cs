using Aeris;
using System;
using System.Threading.Tasks;

namespace Aeris.Samples
{
/// 拥有宿主提供的字符串通道；在 Unity 主线程创建、初始化及销毁。
public sealed class UnityStringChannelExample : IDisposable
{
    readonly UnitySdkWire wire;
    public ClientCore Bridge { get; private set; }
    bool closed;

    // 绑定任意现有宿主发送或事件 API；默认接受原始协议字符串，
    // 宿主通道使用其他封装时传入自定义 IUnityBridgeCodec。
    public UnityStringChannelExample(Action<string> send, Action<Action<string>> subscribe,
                                     Action<Action<string>> unsubscribe,
                                     IUnityBridgeCodec codec = null)
    {
        wire = new UnitySdkWire(send, subscribe, unsubscribe);
        try
        {
            Bridge =
                new ClientCore(new UnityAdapter(wire, codec ?? new UnityProtocolStringCodec()));
        }
        catch
        {
            wire.Dispose();
            throw;
        }
    }
    public async Task ReadyAsync()
    {
        try
        {
            await Bridge.ReadyAsync();
        }
        catch
        {
            Dispose();
            throw;
        }
    }
    public void Dispose()
    {
        if (closed)
            return;
        closed = true;
        try
        {
            Bridge.Dispose();
        }
        finally
        {
            wire.Dispose();
        }
    }
}
}
