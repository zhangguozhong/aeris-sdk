using Aeris;
using System;
using System.Threading.Tasks;

namespace Aeris.Samples
{
/// 在 Unity 主线程创建，channel 必须与 App 为该容器注册的名称一致。
public sealed class UnityIOSChannelExample : IDisposable
{
    readonly AerisIOSNativeWire wire;
    public ClientCore Bridge { get; private set; }
    bool closed;

    public UnityIOSChannelExample(string channel)
    {
        wire = new AerisIOSNativeWire(channel);
        try
        {
            Bridge = new ClientCore(new UnityAdapter(wire, new UnityProtocolStringCodec()));
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

    // 页面销毁和 Unity 卸载前均应先调用，先结束 Core，再撤销原生通道。
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
