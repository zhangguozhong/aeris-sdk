using System;
using System.Collections.Generic;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;

namespace Aeris
{
public sealed partial class ClientCore
{
    // 每个业务请求对应一个生命周期所有者。Core 提供路由、配额与
    // 共享回调队列；槽位释放后，所有者继续存活直到交付被隔离。
    internal sealed class PendingCall
    {
        readonly ClientCore core;
        readonly IBridgeScheduler scheduler;
        internal readonly string Id;
        Action<JObject> data, complete;
        Action<BridgeError> error;
        internal bool Active { get; private set; } = true;
        bool localTerminal, slotHeld, released, hasProgress;
        long last;
        int generation, queued;
        double started;
        IDisposable startup, gap;
        Task<CancelAcknowledgement> cancellation;
        readonly SortedDictionary<long, JObject> buffer = new SortedDictionary<long, JObject>();

        internal PendingCall(ClientCore core, string id, Action<JObject> onData,
                             Action<JObject> onComplete, Action<BridgeError> onError)
        {
            this.core = core;
            scheduler = core.scheduler;
            Id = id;
            data = onData;
            complete = onComplete;
            error = onError;
            core.calls.Add(id, this);
        }
        internal void Start(int timeoutMs)
        {
            scheduler.AssertThread();
            core.AcquireSlot(false);
            slotHeld = true;
            started = core.Diagnostics.Now;
            startup = scheduler.Schedule(
                () =>
                {
                    core.Diagnostics.Record("timeout", core.prefix, Id);
                    if (!Active)
                        return;
                    End(new BridgeError(
                            "TIMEOUT",
                            "Request timed out; native side effects may still have occurred"),
                        null, false);
                    if (core.state == State.Ready)
                        core.ControlCancel(Id, "client timeout",
                                           Completion<CancelAcknowledgement>());
                },
                timeoutMs);
        }
        internal void Accept(JObject frame)
        {
            scheduler.AssertThread();
            if (!Active)
                return;
            try
            {
                long seq = BridgeResponseValidation.Validate(frame, "call");
                if (seq <= last || buffer.ContainsKey(seq))
                    return;
                if (seq != last + 1)
                {
                    if (buffer.Count >= 32)
                    {
                        Fail();
                        return;
                    }
                    buffer.Add(seq, frame);
                    StartGap();
                    return;
                }
                Consume(seq, frame);
                JObject next;
                while (Active && buffer.TryGetValue(last + 1, out next))
                {
                    buffer.Remove(last + 1);
                    Consume(last + 1, next);
                }
                // C# 每次按序推进后重置缺帧截止时间。
                if (gap != null)
                {
                    gap.Dispose();
                    gap = null;
                }
                if (Active && buffer.Count > 0)
                    StartGap();
            }
            catch
            {
                Fail();
            }
        }
        void StartGap()
        {
            if (gap == null)
                gap = scheduler.Schedule(
                    () =>
                    {
                        if (Active)
                            Fail();
                    },
                    2000);
        }
        void Consume(long seq, JObject frame)
        {
            last = seq;
            // 缓冲中的后续帧不停止启动计时；首个按序帧才会停止。
            if (startup != null)
            {
                startup.Dispose();
                startup = null;
            }
            if ((bool)frame["finished"])
            {
                End(frame.Property("error") != null ? ReadError(frame["error"]) : null,
                    frame["result"] as JObject, false, core.PayloadBytes(frame));
            }
            else
            {
                // 在回调准入或观察者可能同步关闭此所有者前发布状态。
                hasProgress = true;
                var callback = data;
                if (callback != null)
                {
                    var result = (JObject)frame["result"];
                    Enqueue(() => callback(result), false,
                            Math.Max(core.receiveBytes, core.PayloadBytes(frame)));
                }
            }
        }
        internal Task<CancelAcknowledgement> Cancel(string reason)
        {
            scheduler.AssertThread();
            if (core.state != State.Ready)
                return Task.FromResult(new CancelAcknowledgement(false));
            if (cancellation != null)
                return cancellation;
            if (released || localTerminal || (!Active && !hasProgress))
                return Task.FromResult(new CancelAcknowledgement(false));
            // 在入队观察者可能重入 Cancel 前，先提交共享完成任务。
            var done = Completion<CancelAcknowledgement>();
            cancellation = done.Task;
            End(new BridgeError("CANCELLED", reason ?? "user cancelled"), null, true);
            if (core.state != State.Ready)
                done.TrySetResult(new CancelAcknowledgement(false));
            else
                core.ControlCancel(Id, reason ?? "user cancelled", done);
            return cancellation;
        }
        internal void Close(BridgeError failure, bool preserveFinal = false)
        {
            if (released || (preserveFinal && !Active && !hasProgress && !localTerminal) ||
                (preserveFinal && localTerminal && failure.Code == "BACKPRESSURE"))
                return;
            localTerminal = false;
            End(failure, null, true);
        }
        internal void Fail(BridgeError failure = null)
        {
            if (failure != null)
            {
                End(failure, null, true);
                return;
            }
            End(new BridgeError("PROTOCOL_ERROR", "Invalid native business request"), null, true);
            if (core.state == State.Ready)
                core.ControlCancel(Id, "invalid response", Completion<CancelAcknowledgement>());
        }
        void End(BridgeError failure, JObject result, bool local, int frameBytes = 0)
        {
            if (released || localTerminal || (!Active && !local))
                return;
            if (local)
            {
                localTerminal = true;
                generation++;
                failure = BoundedDeliveryError(failure);
            }
            ReleaseSlot();
            if (failure != null)
            {
                var callback = error;
                Enqueue(() => callback(failure), true,
                        Math.Max(local ? 0 : Math.Max(frameBytes, core.receiveBytes),
                                 core.ErrorBytes(failure)),
                        local);
            }
            else
            {
                var callback = complete;
                Enqueue(
                    () => callback(result), true,
                    Math.Max(frameBytes, Math.Max(core.receiveBytes, core.PayloadBytes(result))));
            }
            core.Diagnostics.Record(failure == null ? "end" : "error", core.prefix, Id,
                                    code: failure == null ? null : failure.Code);
        }
        void ReleaseSlot()
        {
            if (slotHeld)
            {
                slotHeld = false;
                core.ReleaseSlot(false, started);
            }
            Active = false;
            buffer.Clear();
            core.SyncGauges();
            if (startup != null)
            {
                startup.Dispose();
                startup = null;
            }
            if (gap != null)
            {
                gap.Dispose();
                gap = null;
            }
        }
        void Enqueue(Action callback, bool terminal = false, int bytes = 128, bool urgent = false)
        {
            int token = generation;
            queued++;
            bool accepted = core.flow.Enqueue(
                () =>
                {
                    try
                    {
                        if (generation == token)
                        {
                            if (terminal)
                                ReleaseCallbacks();
                            core.Callback(callback);
                        }
                    }
                    finally
                    {
                        Release();
                    }
                },
                bytes, urgent,
                () =>
                { queued--; },
                pressureOwner: urgent ? null : PressureClose());
            if (!accepted)
                Release();
        }
        // 隔离回退闭包，防止其保留被丢弃的载荷。
        Action PressureClose()
        {
            int token = generation;
            return () =>
            {
                if (generation == token)
                    Close(new BridgeError("BACKPRESSURE", "Callback queue exceeded"));
            };
        }
        void Release()
        {
            if (!Active && queued == 0)
                ReleaseCallbacks();
        }
        void ReleaseCallbacks()
        {
            released = true;
            core.calls.Remove(Id);
            data = null;
            complete = null;
            error = null;
            core.SyncGauges();
        }
    }
}
}
