using System;
using System.Threading;
using System.Runtime.CompilerServices;
using System.Collections.Generic;
using System.Text;

namespace Aeris
{
// 由内置 iOS Wire 或宿主自定义通道实现，Adapter 不直接调用平台入口。
public interface IUnityBridgeWire
{
    void SendPayload(string payload);
    event Action<string> PayloadReceived;
}

// 支持宿主主动关闭的可选扩展，既有 Wire 无需实现。
public interface IUnityBridgeDisconnectSource
{
    bool IsClosed { get; }
    event Action<Exception> Disconnected;
}

// Client Core 调用 Connect/Send/Dispose；此类不解释业务方法或回调。
public sealed class UnityAdapter : IBridgeAdapter, IBridgeTerminalSender
{
    private static readonly object OwnerLock = new object();
    private static readonly ConditionalWeakTable<object, UnityAdapter> Owners =
        new ConditionalWeakTable<object, UnityAdapter>();
    private readonly IUnityBridgeWire wire;
    private readonly IUnityBridgeCodec codec;
    private SynchronizationContext context;
    private Action<string> receive;
    private Action<Exception> disconnected;
    private int closed, disconnectQueued, wireDisconnected, admissionClosed;
    private readonly object queueLock = new object();
    private readonly HashSet<QueuedPayload> queued = new HashSet<QueuedPayload>();
    private readonly UnityReceiveLimits receiveLimits;
    private long queuedBytes;
    private sealed class QueuedPayload
    {
        public string Text;
        public int Bytes;
    }
    public int QueuedReceiveMessages { get { lock (queueLock) return queued.Count; } }
    public long QueuedReceiveBytes { get { lock (queueLock) return queuedBytes; } }
    private int terminalSent;
    private bool connected;
    private IUnityBridgeDisconnectSource disconnectSource;
    public UnityAdapter(IUnityBridgeWire wire, IUnityBridgeCodec codec = null)
        : this(wire, codec, new UnityReceiveLimits())
    {
    }
    public UnityAdapter(IUnityBridgeWire wire, IUnityBridgeCodec codec, UnityReceiveLimits limits)
    {
        this.wire = wire ?? throw new ArgumentNullException(nameof(wire));
        this.codec = codec ?? new LegacyUnityBridgeCodec();
        receiveLimits = limits ?? throw new ArgumentNullException(nameof(limits));
    }

    public void Connect(Action<string> onMessage, Action<Exception> onDisconnect)
    {
        if (connected || Volatile.Read(ref closed) != 0)
            throw new InvalidOperationException("Adapter already initialized");
        context = SynchronizationContext.Current ??
                  throw new InvalidOperationException("Initialize on Unity main thread");
        lock (OwnerLock)
        {
            UnityAdapter other;
            if (Owners.TryGetValue(wire, out other))
                throw new InvalidOperationException("One adapter per Unity wire");
            Owners.Add(wire, this);
        }
        receive = onMessage;
        disconnected = onDisconnect;
        connected = true;
        try
        {
            wire.PayloadReceived += OnPayload;
            disconnectSource = wire as IUnityBridgeDisconnectSource;
            if (disconnectSource != null)
            {
                disconnectSource.Disconnected += OnWireDisconnected;
                if (disconnectSource.IsClosed)
                    throw new InvalidOperationException("Native wire already closed");
            }
        }
        catch
        {
            Dispose();
            throw;
        }
    }
    public void Send(string protocolText)
    {
        if (!connected || Volatile.Read(ref closed) != 0 ||
            Volatile.Read(ref wireDisconnected) != 0 || Volatile.Read(ref admissionClosed) != 0)
            throw new InvalidOperationException("Adapter closed");
        UnityBridgeCodecLimits.ValidateRequest(protocolText);
        string payload;
        try
        {
            payload = codec.EncodeRequest(protocolText);
            UnityBridgeCodecLimits.ValidatePayload(payload);
        }
        catch (Exception error)
        {
            Disconnect(error);
            throw;
        }
        wire.SendPayload(payload);
    }
    public void SendTerminal(string protocolText)
    {
        if (Volatile.Read(ref wireDisconnected) != 0 || Interlocked.Exchange(ref terminalSent, 1) != 0)
            return;
        lock (OwnerLock)
        {
            UnityAdapter owner;
            if (Owners.TryGetValue(wire, out owner) && !ReferenceEquals(owner, this))
                return;
        }
        // 本地入站已封闭仍可清理旧 Native 连接，物理 Wire 仍归 owner 管理。
        UnityBridgeCodecLimits.ValidateRequest(protocolText);
        var payload = codec.EncodeRequest(protocolText);
        UnityBridgeCodecLimits.ValidatePayload(payload);
        wire.SendPayload(payload);
    }
    private void OnPayload(string payload)
    {
        if (Volatile.Read(ref closed) != 0 || Volatile.Read(ref wireDisconnected) != 0 ||
            Volatile.Read(ref admissionClosed) != 0)
            return;
        int bytes = payload == null ? -1 : Encoding.UTF8.GetByteCount(payload);
        if (bytes < 0 || bytes > UnityBridgeCodecLimits.OuterBytes)
        {
            QueueDisconnect(new FormatException("Invalid native envelope"));
            return;
        }
        QueuedPayload item = null;
        lock (queueLock)
        {
            if (Volatile.Read(ref closed) != 0 || Volatile.Read(ref admissionClosed) != 0)
                return;
            if (queued.Count < receiveLimits.MaxMessages &&
                bytes <= receiveLimits.MaxBytes - queuedBytes)
            {
                item = new QueuedPayload { Text = payload, Bytes = bytes };
                queued.Add(item);
                queuedBytes += bytes;
            }
        }
        if (item == null)
        {
            QueueDisconnect(new InvalidOperationException("Native receive queue exceeded"));
            return;
        }
        try
        {
            context.Post(_ => Deliver(item), null);
        }
        catch
        {
            Take(item);
            throw;
        }
    }
    // Post 只持有可清空的条目；Dispose 不必等待 Unity 下一帧才释放大字符串。
    private string Take(QueuedPayload item)
    {
        lock (queueLock)
        {
            if (!queued.Remove(item))
                return null;
            var text = item.Text;
            queuedBytes -= item.Bytes;
            item.Text = null;
            item.Bytes = 0;
            return text;
        }
    }
    private void DropQueued()
    {
        lock (queueLock)
        {
            Volatile.Write(ref admissionClosed, 1);
            foreach (var item in queued)
            {
                item.Text = null;
                item.Bytes = 0;
            }
            queued.Clear();
            queuedBytes = 0;
        }
    }
    private void QueueDisconnect(Exception error)
    {
        DropQueued();
        if (Interlocked.Exchange(ref disconnectQueued, 1) == 0)
            context.Post(_ => Disconnect(error), null);
    }
    private void Deliver(QueuedPayload item)
    {
        var payload = Take(item);
        if (payload == null || Volatile.Read(ref closed) != 0 ||
            Volatile.Read(ref wireDisconnected) != 0 || Volatile.Read(ref admissionClosed) != 0)
            return;
        string text;
        try
        {
            if (!codec.TryDecodeResponse(payload, out text))
                return;
            // Core 仍在 callbackId 关联后执行内层响应限制和校验。
        }
        catch (Exception error)
        {
            Disconnect(error);
            return;
        }
        receive(text);
    }
    private void OnWireDisconnected(Exception error)
    {
        if (Volatile.Read(ref closed) != 0 || Interlocked.Exchange(ref wireDisconnected, 1) != 0)
            return;
        QueueDisconnect(error);
    }
    private void Disconnect(Exception error)
    {
        if (Volatile.Read(ref closed) != 0)
            return;
        Action<Exception> notify = disconnected;
        Dispose();
        if (notify != null)
            notify(error);
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref closed, 1) != 0)
            return;
        DropQueued();
        if (connected)
            wire.PayloadReceived -= OnPayload;
        if (disconnectSource != null)
            disconnectSource.Disconnected -= OnWireDisconnected;
        disconnectSource = null;
        lock (OwnerLock)
        {
            UnityAdapter owner;
            if (Owners.TryGetValue(wire, out owner) && ReferenceEquals(owner, this))
                Owners.Remove(wire);
        }
        connected = false;
        receive = null;
        disconnected = null;
    }
}
}
