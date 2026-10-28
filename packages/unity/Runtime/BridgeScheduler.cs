using System;
using System.Threading;

namespace Aeris
{
// 保持内部可见：确定性测试通过可控时钟使用相同状态机。
internal interface IBridgeScheduler
{
    void AssertThread();
    void Post(Action action);
    IDisposable Schedule(Action action, int milliseconds);
}
internal sealed class MainThreadScheduler : IBridgeScheduler
{
    readonly SynchronizationContext context;
    readonly int thread;
    public MainThreadScheduler()
    {
        context = SynchronizationContext.Current ??
                  throw new InvalidOperationException("Create ClientCore on Unity main thread");
        thread = Thread.CurrentThread.ManagedThreadId;
    }
    public void AssertThread()
    {
        if (Thread.CurrentThread.ManagedThreadId != thread)
            throw new InvalidOperationException("Use Bridge on its Unity main thread");
    }
    public void Post(Action action)
    {
        context.Post(
            _ => action(), null);
    }
    public IDisposable Schedule(Action action, int milliseconds)
    {
        return new Scheduled(context, action, milliseconds);
    }
    sealed class Scheduled : IDisposable
    {
        Action callback;
        Timer timer;
        public Scheduled(SynchronizationContext context, Action action, int milliseconds)
        {
            callback = action;
            timer = new Timer(
                _ => context.Post(
                    __ =>
                    {
                        var run = Interlocked.Exchange(ref callback, null);
                        if (run != null)
                            run();
                    },
                    null),
                null, milliseconds, Timeout.Infinite);
        }
        public void Dispose()
        {
            Interlocked.Exchange(ref callback, null);
            var old = Interlocked.Exchange(ref timer, null);
            if (old != null)
                old.Dispose();
        }
    }
}
}
