using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
namespace Aeris
{
public sealed class BridgeDiagnosticRecord
{
    public double ElapsedMilliseconds { get; internal set; }
    public string Stage { get; internal set; }
    public string ClientId { get; internal set; }
    public string CallbackId { get; internal set; }
    public string SubscriptionId { get; internal set; }
    public string Method { get; internal set; }
    public string Topic { get; internal set; }
    public string ErrorCode { get; internal set; }
    internal BridgeDiagnosticRecord Copy()
    {
        return (BridgeDiagnosticRecord)MemberwiseClone();
    }
}
public sealed class BridgeDiagnosticsSnapshot
{
    public IDictionary<string, long> Counters { get; internal set; }
    public IDictionary<string, long> Gauges { get; internal set; }
    public IDictionary<string, long> Peaks { get; internal set; }
    public BridgeDiagnosticRecord[] Records { get; internal set; }
    public long LatencyCount { get; internal set; }
    public double LatencySumMilliseconds { get; internal set; }
    public double LatencyMaxMilliseconds { get; internal set; }
    public long[] LatencyBuckets { get; internal set; }
}
/// 诊断不含载荷；快照与观察者记录不暴露活动可变状态。
public sealed class BridgeDiagnostics
{
    static readonly HashSet<string> stages = new HashSet<string>(
        "ready start send receive callback.enqueue callback.deliver end error timeout cancel close backpressure callback.exception observer.error callback.discard"
            .Split(' '));
    static readonly HashSet<string> gaugesAllowed = new HashSet<string>(
        "queued.messages queued.bytes urgent.messages urgent.bytes pending.business pending.control active.calls active.subscriptions"
            .Split(' '));
    static readonly HashSet<string> codes = new HashSet<string>(
        "BACKPRESSURE DISCONNECTED PROTOCOL_ERROR INVALID_ARGUMENT INVALID_METHOD PAYLOAD_TOO_LARGE NOT_READY TOO_MANY_REQUESTS TOO_MANY_SUBSCRIPTIONS TIMEOUT CANCELLED BRIDGE_UNAVAILABLE HOST_NOT_READY INVALID_EVENT METHOD_NOT_FOUND PERMISSION_DENIED INTERNAL_ERROR UNSUPPORTED BUSY EVENT_NOT_FOUND EVENT_UNAVAILABLE UI_UNAVAILABLE"
            .Split(' '));
    readonly int capacity;
    readonly Action<BridgeDiagnosticRecord> observer;
    readonly Func<double> clock;
    readonly Queue<BridgeDiagnosticRecord> records = new Queue<BridgeDiagnosticRecord>();
    readonly Dictionary<string, long> counters = new Dictionary<string, long>(),
                                      gauges = new Dictionary<string, long>(),
                                      peaks = new Dictionary<string, long>();
    readonly long[] buckets = new long[9];
    readonly double[] boundaries = { 1, 5, 10, 50, 100, 500, 1000, 5000 };
    double last, sum, max;
    long count;
    bool notifying;
    public BridgeDiagnostics(int capacity = 128, Action<BridgeDiagnosticRecord> observer = null,
                             Func<double> monotonicMilliseconds = null)
    {
        if (capacity < 0 || capacity > 1024)
            throw new ArgumentOutOfRangeException(nameof(capacity));
        this.capacity = capacity;
        this.observer = observer;
        var watch = Stopwatch.StartNew();
        clock = monotonicMilliseconds ?? (() => watch.Elapsed.TotalMilliseconds);
        foreach (var stage in stages)
            counters[stage] = 0;
        foreach (var key in gaugesAllowed)
        {
            gauges[key] = 0;
            peaks[key] = 0;
        }
    }
    internal double Now
    {
        get {
            double n;
            try
            {
                n = clock();
            }
            catch
            {
                n = last;
            }
            if (double.IsNaN(n) || double.IsInfinity(n) || n < last)
                n = last;
            last = n;
            return n;
        }
    }
    internal static string SafeMethod(string value, int limit = 256)
    {
        if (value == null || Encoding.UTF8.GetByteCount(value) > limit ||
            !Regex.IsMatch(value, @"\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*\z"))
            return null;
        foreach (var p in value.Split('.'))
            if (p == "constructor" || p == "prototype" || p == "__proto__")
                return null;
        return value;
    }
    static string SafeId(string value)
    {
        return value != null && Encoding.UTF8.GetByteCount(value) <= 256 &&
                       Regex.IsMatch(value, @"\A[A-Za-z0-9_-]+:[A-Za-z0-9_-]+\z")
                   ? value
                   : null;
    }
    internal void Record(string stage, string client = null, string id = null, string method = null,
                         string topic = null, string code = null, string subscriptionId = null)
    {
        if (!stages.Contains(stage))
            return;
        counters[stage]++;
        var r = new BridgeDiagnosticRecord { ElapsedMilliseconds = Now,
                                             Stage = stage,
                                             ClientId = client != null && client.Length <= 256 &&
                                                                Regex.IsMatch(client,
                                                                              @"\A[A-Za-z0-9_-]+\z")
                                                            ? client
                                                            : null,
                                             CallbackId = SafeId(id),
                                             SubscriptionId = SafeId(subscriptionId),
                                             Method = SafeMethod(method),
                                             Topic = SafeMethod(topic, 128),
                                             ErrorCode = code == null           ? null
                                                         : codes.Contains(code) ? code
                                                                                : "OTHER" };
        if (capacity > 0)
        {
            if (records.Count == capacity)
                records.Dequeue();
            records.Enqueue(r);
        }
        if (observer == null || notifying)
            return;
        notifying = true;
        try
        {
            observer(r.Copy());
        }
        catch
        {
            counters["observer.error"]++;
        }
        finally
        {
            notifying = false;
        }
    }
    internal void Delta(string key, long delta)
    {
        if (!gaugesAllowed.Contains(key))
            return;
        gauges[key] += delta;
        if (gauges[key] > peaks[key])
            peaks[key] = gauges[key];
    }
    internal void Latency(double started)
    {
        double elapsed = Math.Max(0, Now - started);
        count++;
        sum += elapsed;
        max = Math.Max(max, elapsed);
        int i = 0;
        while (i < boundaries.Length && elapsed > boundaries[i])
            i++;
        buckets[i]++;
    }
    public BridgeDiagnosticsSnapshot Snapshot()
    {
        var copy = new List<BridgeDiagnosticRecord>();
        foreach (var r in records)
            copy.Add(r.Copy());
        return new BridgeDiagnosticsSnapshot { Counters = new Dictionary<string, long>(counters),
                                               Gauges = new Dictionary<string, long>(gauges),
                                               Peaks = new Dictionary<string, long>(peaks),
                                               Records = copy.ToArray(),
                                               LatencyCount = count,
                                               LatencySumMilliseconds = sum,
                                               LatencyMaxMilliseconds = max,
                                               LatencyBuckets = (long[])buckets.Clone() };
    }
    public void Reset()
    {
        foreach (var key in new List<string>(counters.Keys))
            counters[key] = 0;
        foreach (var key in gauges.Keys)
            peaks[key] = gauges[key];
        records.Clear();
        Array.Clear(buckets, 0, buckets.Length);
        count = 0;
        sum = max = 0;
    }
}
}
