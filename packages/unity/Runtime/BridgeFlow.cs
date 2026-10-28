using System;
using System.Collections.Generic;
namespace Aeris
{
public sealed class FlowLimits
{
    public int MaxMessages { get; set; } = 256;
    public int MaxBytes { get; set; } = 4 * 1024 * 1024;
    public int UrgentMessages { get; set; } = 512;
    public int UrgentBytes { get; set; } = 512 * 1024;
    public int BatchSize { get; set; } = 32;
    internal FlowLimits Copy()
    {
        if (MaxMessages < 1 || MaxBytes < 1 || UrgentMessages < 1 || UrgentBytes < 1 ||
            BatchSize < 1 || BatchSize > 32)
            throw new ArgumentOutOfRangeException("flowLimits");
        return (FlowLimits)MemberwiseClone();
    }
}
// 每个保留的业务回调都是有界任务；交付或丢弃前先释放资源。
internal sealed class BridgeFlow
{
    sealed class Job
    {
        public Action Run, Release, Pressure, PressureOwner;
        public int Bytes;
    }
    readonly Queue<Job> normal = new Queue<Job>(), urgent = new Queue<Job>();
    readonly IBridgeScheduler scheduler;
    readonly FlowLimits limits;
    readonly BridgeDiagnostics diagnostics;
    readonly Action pressure;
    bool posted, faulted;
    int normalBytes, urgentBytes;
    internal BridgeFlow(IBridgeScheduler scheduler, FlowLimits limits,
                        BridgeDiagnostics diagnostics, Action pressure)
    {
        this.scheduler = scheduler;
        this.limits = limits.Copy();
        this.diagnostics = diagnostics;
        this.pressure = pressure;
    }
    internal bool UrgentFull
    {
        get {
            return urgent.Count >= limits.UrgentMessages || 128 > limits.UrgentBytes - urgentBytes;
        }
    }
    internal bool Enqueue(Action run, int bytes, bool emergency = false, Action release = null,
                          Action converted = null, Action pressureOwner = null)
    {
        bytes = Math.Max(1, bytes);
        if (emergency || faulted)
            return AddUrgent(run, bytes, release);
        if (normal.Count >= limits.MaxMessages || bytes > limits.MaxBytes - normalBytes)
        {
            faulted = true;
            var owners = new List<Action>();
            var pendingOwners = new List<Action>();
            while (normal.Count > 0)
            {
                var old = normal.Dequeue();
                Free(old, false);
                if (old.Release != null)
                    old.Release();
                if (old.Pressure != null)
                    owners.Add(old.Pressure);
                if (old.PressureOwner != null)
                    pendingOwners.Add(old.PressureOwner);
            }
            if (release != null)
                release();
            if (converted != null)
                owners.Add(converted);
            if (pressureOwner != null)
                pendingOwners.Add(pressureOwner);
            pressure();
            // 这些钩子仅替换被丢弃的所有者状态；业务交付仍经队列执行。
            foreach (var owner in pendingOwners)
                owner();
            foreach (var owner in owners)
                AddUrgent(owner, 128, null);
            diagnostics.Record("backpressure");
            return false;
        }
        normal.Enqueue(new Job { Run = run, Bytes = bytes, Release = release, Pressure = converted,
                                 PressureOwner = pressureOwner });
        normalBytes += bytes;
        diagnostics.Delta("queued.messages", 1);
        diagnostics.Delta("queued.bytes", bytes);
        diagnostics.Record("callback.enqueue");
        Post();
        return true;
    }
    bool AddUrgent(Action run, int bytes, Action release)
    {
        if (urgent.Count >= limits.UrgentMessages || bytes > limits.UrgentBytes - urgentBytes)
        {
            if (release != null)
                release();
            if (!faulted)
            {
                faulted = true;
                pressure();
            }
            diagnostics.Record("callback.discard");
            return false;
        }
        urgent.Enqueue(new Job { Run = run, Bytes = bytes, Release = release });
        urgentBytes += bytes;
        diagnostics.Delta("urgent.messages", 1);
        diagnostics.Delta("urgent.bytes", bytes);
        diagnostics.Record("callback.enqueue");
        Post();
        return true;
    }
    void Free(Job job, bool emergency)
    {
        if (emergency)
        {
            urgentBytes -= job.Bytes;
            diagnostics.Delta("urgent.messages", -1);
            diagnostics.Delta("urgent.bytes", -job.Bytes);
        }
        else
        {
            normalBytes -= job.Bytes;
            diagnostics.Delta("queued.messages", -1);
            diagnostics.Delta("queued.bytes", -job.Bytes);
        }
    }
    void Post()
    {
        if (posted)
            return;
        posted = true;
        scheduler.Post(Drain);
    }
    void Drain()
    {
        int n = 0;
        while (n++ < limits.BatchSize && (urgent.Count > 0 || normal.Count > 0))
        {
            bool emergency = urgent.Count > 0;
            var job = emergency ? urgent.Dequeue() : normal.Dequeue();
            Free(job, emergency);
            if (job.Release != null)
                job.Release();
            diagnostics.Record("callback.deliver");
            job.Run();
        }
        posted = false;
        if (urgent.Count > 0 || normal.Count > 0)
            Post();
    }
}
}
