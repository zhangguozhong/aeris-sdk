using System;
using System.Collections.Generic;
using System.Text;
using System.Threading;

namespace Aeris
{
/// 通过 UnityEngine JNI 接通用 Java 插件，回调经 Unity 主线程交付。
public sealed class AerisAndroidNativeWire : IUnityBridgeWire, IUnityBridgeDisconnectSource, IDisposable
{
    // 内部边界允许独立 .NET 测试生命周期；Player 入口始终使用真实 AndroidJavaClass。
    internal interface INativeChannel : IDisposable
    {
        long Open(string channel, Action<string> message, Action<string> closed);
        void Send(long handle, string payload);
        void Close(long handle);
    }
    sealed class Pending
    {
        internal string Text;
        internal int Bytes;
    }
    readonly object gate = new object();
    readonly HashSet<Pending> pending = new HashSet<Pending>();
    readonly SynchronizationContext context;
    readonly int ownerThread;
    readonly INativeChannel native;
    readonly UnityReceiveLimits limits;
    long handle, queuedBytes;
    int closed;
    static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    public event Action<string> PayloadReceived;
    public event Action<Exception> Disconnected;
    public bool IsClosed { get { return Volatile.Read(ref closed) != 0; } }

    public AerisAndroidNativeWire(string channel)
        : this(channel, null, new UnityReceiveLimits()) {}

    internal AerisAndroidNativeWire(string channel, INativeChannel native, UnityReceiveLimits limits)
    {
        if (string.IsNullOrEmpty(channel) || channel.Length > 128)
            throw new ArgumentException("Expected channel name of 1..128 ASCII characters");
        foreach (char item in channel)
            if (!((item >= 'a' && item <= 'z') || (item >= 'A' && item <= 'Z') ||
                  (item >= '0' && item <= '9') || item == '_' || item == '.' || item == ':' || item == '-'))
                throw new ArgumentException("Invalid channel name");
        context = SynchronizationContext.Current ??
            throw new InvalidOperationException("Create the Android wire on Unity's main thread");
        ownerThread = Thread.CurrentThread.ManagedThreadId;
        this.limits = limits ?? throw new ArgumentNullException(nameof(limits));
        this.native = native ?? CreateNative();
        native = this.native;
        try
        {
            long opened = native.Open(channel, OnMessage, OnClosed);
            if (opened <= 0) throw new InvalidOperationException("Cannot open Aeris Android channel");
            lock (gate)
            {
                if (IsClosed) native.Close(opened);
                else handle = opened;
            }
            if (IsClosed) throw new InvalidOperationException("Native channel closed during open");
        }
        catch
        {
            Interlocked.Exchange(ref closed, 1);
            native.Dispose();
            throw;
        }
    }
    void AssertThread()
    {
        if (Thread.CurrentThread.ManagedThreadId != ownerThread)
            throw new InvalidOperationException("Use the Android wire on its Unity main thread");
    }
    public void SendPayload(string payload)
    {
        AssertThread();
        if (IsClosed) throw new ObjectDisposedException(nameof(AerisAndroidNativeWire));
        UnityBridgeCodecLimits.ValidatePayload(payload);
        try { native.Send(handle, payload); }
        catch (Exception error) { Fail(error, true); throw; }
    }
    void OnMessage(string payload)
    {
        try
        {
            if (IsClosed) return;
            int bytes = payload == null ? 0 : Utf8.GetByteCount(payload);
            if (bytes < 1 || bytes > UnityBridgeCodecLimits.OuterBytes)
                throw new FormatException("Invalid native envelope");
            Pending item;
            lock (gate)
            {
                if (IsClosed) return;
                if (pending.Count >= limits.MaxMessages || bytes > limits.MaxBytes - queuedBytes)
                    throw new InvalidOperationException("Android receive queue exceeded");
                item = new Pending { Text = payload, Bytes = bytes };
                pending.Add(item); queuedBytes += bytes;
            }
            context.Post(_ => Deliver(item), null);
        }
        catch (Exception error) { Fail(error, true); }
    }
    void Deliver(Pending item)
    {
        string text;
        lock (gate)
        {
            if (!pending.Remove(item)) return;
            text = item.Text; item.Text = null;
            queuedBytes -= item.Bytes; item.Bytes = 0;
            if (IsClosed) return;
        }
        try
        {
            var callback = PayloadReceived;
            if (callback != null) callback(text);
        }
        catch (Exception error) { Fail(error, true); }
    }
    void OnClosed(string reason)
    {
        Fail(new InvalidOperationException("Android native channel closed: " + reason), false);
    }
    void Fail(Exception error, bool closeNative)
    {
        if (Interlocked.Exchange(ref closed, 1) != 0) return;
        long previous;
        lock (gate)
        {
            previous = handle; handle = 0;
            foreach (var item in pending) { item.Text = null; item.Bytes = 0; }
            pending.Clear(); queuedBytes = 0;
        }
        if (closeNative && previous != 0)
        {
            try { native.Close(previous); } catch (Exception) {}
        }
        // AndroidJavaClass 的释放和事件分发统一回到创建线程。
        try
        {
            context.Post(_ => {
                try { native.Dispose(); } catch (Exception) {}
                var notify = Disconnected;
                PayloadReceived = null; Disconnected = null;
                if (notify == null) return;
                foreach (Action<Exception> callback in notify.GetInvocationList())
                    try { callback(error); } catch (Exception) {}
            }, null);
        }
        catch (Exception) { /* Unity 同步上下文已结束时不能向 Java 抛出托管异常。 */ }
    }
    public void Dispose() { AssertThread(); Fail(new ObjectDisposedException(nameof(AerisAndroidNativeWire)), true); }

    static INativeChannel CreateNative()
    {
#if UNITY_ANDROID && !UNITY_EDITOR
        return new AndroidChannel();
#else
        throw new PlatformNotSupportedException("Aeris Android native channel requires an Android Player");
#endif
    }
#if UNITY_ANDROID && !UNITY_EDITOR
    sealed class AndroidChannel : INativeChannel
    {
        readonly UnityEngine.AndroidJavaClass channel = new UnityEngine.AndroidJavaClass("com.aeris.unity.AerisUnityChannel");
        Callback proxy;
        public long Open(string name, Action<string> message, Action<string> closed)
        {
            proxy = new Callback(message, closed);
            return channel.CallStatic<long>("open", name, proxy);
        }
        public void Send(long handle, string payload) { channel.CallStatic("send", handle, payload); }
        public void Close(long handle) { channel.CallStatic("close", handle); }
        public void Dispose() { if (proxy != null) proxy.Clear(); proxy = null; channel.Dispose(); }
    }
    // Java 接口名称及方法大小写必须与插件一致，link.xml 阻止 IL2CPP 裁剪回调。
    sealed class Callback : UnityEngine.AndroidJavaProxy
    {
        Action<string> message, closed;
        internal Callback(Action<string> message, Action<string> closed)
            : base("com.aeris.unity.AerisUnityChannel$Callback") { this.message = message; this.closed = closed; }
        public void onMessage(string payload) { var action = message; if (action != null) action(payload); }
        public void onClosed(string reason) { var action = closed; if (action != null) action(reason); }
        internal void Clear() { message = null; closed = null; }
    }
#endif
}
}
