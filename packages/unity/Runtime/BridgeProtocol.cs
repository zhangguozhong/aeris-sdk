using System;
using System.Threading.Tasks;

namespace Aeris
{
// 仅涉及传输；实现必须在 Core 所属线程交付。
public interface IBridgeAdapter : IDisposable
{
    void Connect(Action<string> receive, Action<Exception> disconnected);
    void Send(string protocolText);
}
// 可选的终态发送能力：仅由 Core 在本地封闭后清理旧逻辑连接。
public interface IBridgeTerminalSender
{
    void SendTerminal(string protocolText);
}
public sealed class BridgeError : Exception
{
    public string Code { get; private set; }
    public BridgeError(string code, string message) : base(message)
    {
        Code = code;
    }
}
public sealed class CancelAcknowledgement
{
    public bool Accepted { get; private set; }
    internal CancelAcknowledgement(bool accepted)
    {
        Accepted = accepted;
    }
}
public sealed class BridgeSubscription
{
    readonly Func<Task<bool>> unsubscribe;
    public string SubscriptionId { get; private set; }
    internal BridgeSubscription(string id, Func<Task<bool>> unsubscribe)
    {
        SubscriptionId = id;
        this.unsubscribe = unsubscribe;
    }
    public Task<bool> UnsubscribeAsync()
    {
        return unsubscribe();
    }
}
public sealed class CallHandle
{
    readonly Func<string, Task<CancelAcknowledgement>> cancel;
    public string CallbackId { get; private set; }
    internal CallHandle(string id, Func<string, Task<CancelAcknowledgement>> cancel)
    {
        CallbackId = id;
        this.cancel = cancel;
    }
    public Task<CancelAcknowledgement> CancelAsync(string reason = "user cancelled")
    {
        return cancel(reason);
    }
}
}
