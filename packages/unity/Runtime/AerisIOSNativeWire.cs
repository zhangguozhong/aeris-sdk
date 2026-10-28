using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace Aeris
{
/// 通过通用 C ABI 连接 iOS；业务协议仍由 Client Core 和 Adapter 处理。
public sealed class AerisIOSNativeWire : IUnityBridgeWire, IUnityBridgeDisconnectSource, IDisposable
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void MessageCallback(long context, IntPtr bytes, int length);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    delegate void ClosedCallback(long context, int reason);

    // 静态强引用保证 IL2CPP/GC 不回收反向回调。卸载前仍必须清空 Native 的函数指针。
    static readonly MessageCallback NativeMessage = ReceiveMessage;
    static readonly ClosedCallback NativeClosed = ReceiveClosed;
    static readonly object RoutesLock = new object();
    static readonly Dictionary<long, AerisIOSNativeWire> Routes =
        new Dictionary<long, AerisIOSNativeWire>();
    static readonly Encoding Utf8 = new UTF8Encoding(false, true);
    static long nextContext;
    readonly long contextId;
    readonly int ownerThread;
    long handle;
    int closed;

    public event Action<string> PayloadReceived;
    public event Action<Exception> Disconnected;
    public bool IsClosed
    {
        get {
            return Volatile.Read(ref closed) != 0;
        }
    }

    public AerisIOSNativeWire(string channel)
    {
        if (string.IsNullOrEmpty(channel))
            throw new ArgumentException("Expected channel name");
        if (SynchronizationContext.Current == null)
            throw new InvalidOperationException("Create the iOS wire on Unity's main thread");
        var channelBytes = Utf8.GetBytes(channel);
        if (channelBytes.Length > 128)
            throw new ArgumentException("Channel name too long");
        ownerThread = Thread.CurrentThread.ManagedThreadId;
        contextId = Interlocked.Increment(ref nextContext);
        if (contextId <= 0)
            throw new InvalidOperationException("Native context identifiers exhausted");
        lock (RoutesLock)
        {
            if (Routes.Count >= 128)
                throw new InvalidOperationException("Too many iOS channels");
            Routes.Add(contextId, this);
        }
        try
        {
            long opened;
            int status = Native.Open(channelBytes, channelBytes.Length, contextId, NativeMessage,
                                     NativeClosed, out opened);
            if (status != 0 || opened <= 0)
                throw new InvalidOperationException("Cannot open Aeris iOS channel: " + status);
            handle = opened;
        }
        catch
        {
            lock (RoutesLock) Routes.Remove(contextId);
            Interlocked.Exchange(ref closed, 1);
            throw;
        }
    }

    void AssertThread()
    {
        if (Thread.CurrentThread.ManagedThreadId != ownerThread)
            throw new InvalidOperationException("Use the iOS wire on its Unity main thread");
    }

    public void SendPayload(string payload)
    {
        AssertThread();
        if (IsClosed)
            throw new ObjectDisposedException(nameof(AerisIOSNativeWire));
        UnityBridgeCodecLimits.ValidateRequest(payload);
        var bytes = Utf8.GetBytes(payload);
        int status = Native.Send(handle, bytes, bytes.Length);
        if (status != 0)
        {
            var error = new InvalidOperationException("Aeris iOS send failed: " + status);
            Fail(error, true);
            throw error;
        }
    }

#if UNITY_IOS && !UNITY_EDITOR
    [AOT.MonoPInvokeCallback(typeof(MessageCallback))]
#endif
    static void ReceiveMessage(long context, IntPtr bytes, int length)
    {
        AerisIOSNativeWire wire = null;
        try
        {
            lock (RoutesLock) Routes.TryGetValue(context, out wire);
            if (wire == null || wire.IsClosed)
                return;
            if (bytes == IntPtr.Zero || length < 1 || length > UnityBridgeCodecLimits.OuterBytes)
                throw new FormatException("Invalid native callback buffer");
            // 指针仅在本次 C 回调期间有效，必须在返回 Native 前复制。
            var copy = new byte[length];
            Marshal.Copy(bytes, copy, 0, length);
            var callback = wire.PayloadReceived;
            if (callback != null)
                callback(Utf8.GetString(copy));
        }
        catch (Exception error)
        {
            // 不允许托管异常穿过反向 P/Invoke 边界。
            try
            {
                if (wire != null)
                    wire.Fail(error, true);
            }
            catch (Exception)
            { /* 错误报告本身同样不能跨越 C 边界。 */
            }
        }
    }

#if UNITY_IOS && !UNITY_EDITOR
    [AOT.MonoPInvokeCallback(typeof(ClosedCallback))]
#endif
    static void ReceiveClosed(long context, int reason)
    {
        try
        {
            AerisIOSNativeWire wire;
            lock (RoutesLock) Routes.TryGetValue(context, out wire);
            if (wire != null)
                wire.Fail(new InvalidOperationException("Native channel closed: " + reason), false);
        }
        catch (Exception)
        { /* 关闭通知不能跨 C 边界抛出异常。 */
        }
    }

    void Fail(Exception error, bool closeNative)
    {
        if (Interlocked.Exchange(ref closed, 1) != 0)
            return;
        lock (RoutesLock) Routes.Remove(contextId);
        long nativeHandle = Interlocked.Exchange(ref handle, 0);
        if (closeNative && nativeHandle != 0)
        {
            try
            {
                Native.Close(nativeHandle);
            }
            catch (Exception)
            {
            }
        }
        var notify = Disconnected;
        PayloadReceived = null;
        Disconnected = null;
        if (notify == null)
            return;
        foreach (Action<Exception> callback in notify.GetInvocationList())
        {
            try
            {
                callback(error);
            }
            catch (Exception)
            {
            }
        }
    }

    public void Dispose()
    {
        AssertThread();
        Fail(new ObjectDisposedException(nameof(AerisIOSNativeWire)), true);
    }

    static class Native
    {
#if UNITY_IOS && !UNITY_EDITOR
        const string Library = "__Internal";
#elif AERIS_UNITY_NATIVE_TESTS
        // 仅供 macOS ABI 回归加载同一份 Foundation 原生实现。
        const string Library = "UnityFramework";
#endif
#if (UNITY_IOS && !UNITY_EDITOR) || AERIS_UNITY_NATIVE_TESTS
        [DllImport(Library, EntryPoint = "AerisUnity_Open",
                   CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Open(byte[] channel, int length, long context,
                                        MessageCallback message, ClosedCallback closed,
                                        out long handle);
        [DllImport(Library, EntryPoint = "AerisUnity_Send",
                   CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Send(long handle, byte[] bytes, int length);
        [DllImport(Library, EntryPoint = "AerisUnity_Close",
                   CallingConvention = CallingConvention.Cdecl)]
        internal static extern int Close(long handle);
#else
        internal static int Open(byte[] channel, int length, long context, MessageCallback message,
                                 ClosedCallback closed, out long handle)
        {
            handle = 0;
            throw new PlatformNotSupportedException(
                "Aeris iOS native channel requires an iOS Player");
        }
        internal static int Send(long handle, byte[] bytes, int length)
        {
            throw new PlatformNotSupportedException(
                "Aeris iOS native channel requires an iOS Player");
        }
        internal static int Close(long handle)
        {
            throw new PlatformNotSupportedException(
                "Aeris iOS native channel requires an iOS Player");
        }
#endif
    }
}
}
