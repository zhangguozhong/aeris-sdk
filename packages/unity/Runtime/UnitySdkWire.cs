using System;
using System.Threading;

namespace Aeris
{
/// 绑定现有 SDK 字符串 API 与原始 Native 回调事件，不假定新增原生导出。
public sealed class UnitySdkWire : IUnityBridgeWire, IDisposable
{
    Action<string> send;
    Action<Action<string>> unsubscribe;
    int closed;
    public event Action<string> PayloadReceived;
    public UnitySdkWire(Action<string> sendPayload, Action<Action<string>> subscribeNative,
                        Action<Action<string>> unsubscribeNative)
    {
        if (sendPayload == null || subscribeNative == null || unsubscribeNative == null)
            throw new ArgumentNullException("SDK delegates");
        send = sendPayload;
        unsubscribe = unsubscribeNative;
        try
        {
            subscribeNative(OnNativePayload);
        }
        catch
        {
            Dispose();
            throw;
        }
    }
    public void SendPayload(string payload)
    {
        if (Volatile.Read(ref closed) != 0)
            throw new ObjectDisposedException(nameof(UnitySdkWire));
        send(payload);
    }
    void OnNativePayload(string payload)
    {
        if (Volatile.Read(ref closed) != 0)
            return;
        var receiver = PayloadReceived;
        if (receiver != null)
            receiver(payload);
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0)
            return;
        var remove = unsubscribe;
        unsubscribe = null;
        send = null;
        PayloadReceived = null;
        if (remove != null)
            remove(OnNativePayload); // 仅移除此 Wire 自身的处理器。
    }
}
}
