using System;
using System.Collections.Generic;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Text;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace Aeris
{
/// 每个 Native 绑定对应一个 Core，在 Unity 主线程创建、调用和销毁。
public sealed partial class ClientCore : IDisposable
{
    sealed class Pending
    {
        public Action<BridgeError, JObject> Finish;
        public IDisposable Timer;
        public bool Internal;
        public double Started;
    }
    sealed class Subscription
    {
        public string Id;
        public Action<JObject> Data;
        public Action<BridgeError> Error;
        public Action Complete;
        public bool Active = true, Suppressed, Acked;
        public bool? OffNeeded;
        public long Last;
        public int Queued;
        public IDisposable Gap;
        public Task<bool> Unsubscribe;
        public readonly SortedDictionary<long, JObject> Buffer =
            new SortedDictionary<long, JObject>();
    }
    enum State
    {
        New,
        Connecting,
        Ready,
        Closed
    }
    readonly IBridgeAdapter adapter;
    readonly IBridgeScheduler scheduler;
    readonly Action<Exception> onCallbackError;
    readonly BridgeFlow flow;
    public BridgeDiagnostics Diagnostics { get; private set; }
    int receiveBytes, observedBusiness, observedControl, observedCalls, observedSubscriptions;
    readonly Dictionary<string, Pending> pending = new Dictionary<string, Pending>();
    readonly Dictionary<string, Subscription> subscriptions =
        new Dictionary<string, Subscription>();
    // 保留订阅，直到已投递回调被隔离。
    readonly HashSet<Subscription> deliveries = new HashSet<Subscription>();
    // 调用在已投递终态执行前释放请求槽位；保留其
    // 所有者直到分发，以便 cancel/dispose 仍可隔离排队的终态。
    readonly Dictionary<string, PendingCall> calls = new Dictionary<string, PendingCall>();
    readonly string prefix = Guid.NewGuid().ToString("N");
    long counter;
    int businessPending, controlPending;
    State state;
    string helloCallbackId;
    TaskCompletionSource<bool> ready;
    IDisposable handshakeTimer;
    internal int PendingCount
    {
        get {
            return businessPending + controlPending;
        }
    }
    public ClientCore(IBridgeAdapter adapter, Action<Exception> onCallbackError = null)
        : this(adapter, new MainThreadScheduler(), onCallbackError, null, null)
    {
    }
    public ClientCore(IBridgeAdapter adapter, Action<Exception> onCallbackError,
                      FlowLimits flowLimits, BridgeDiagnostics diagnostics = null)
        : this(adapter, new MainThreadScheduler(), onCallbackError, flowLimits, diagnostics)
    {
    }
    internal ClientCore(IBridgeAdapter adapter, IBridgeScheduler scheduler,
                        Action<Exception> onCallbackError)
        : this(adapter, scheduler, onCallbackError, null, null)
    {
    }
    internal ClientCore(IBridgeAdapter adapter, IBridgeScheduler scheduler,
                        Action<Exception> onCallbackError, FlowLimits flowLimits,
                        BridgeDiagnostics diagnostics)
    {
        this.adapter = adapter ?? throw new ArgumentNullException(nameof(adapter));
        this.scheduler = scheduler ?? throw new ArgumentNullException(nameof(scheduler));
        Diagnostics = diagnostics ?? new BridgeDiagnostics();
        flow = new BridgeFlow(
            scheduler, flowLimits ?? new FlowLimits(), Diagnostics,
            () => Shutdown(new BridgeError("BACKPRESSURE", "Callback queue exceeded")));
        this.onCallbackError =
            onCallbackError ?? (e => System.Diagnostics.Trace.TraceError(e.ToString()));
    }
    string NextId()
    {
        return prefix + ":" +
               checked(++counter).ToString(System.Globalization.CultureInfo.InvariantCulture);
    }
    static TaskCompletionSource<T> Completion<T>()
    {
        return new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    public Task ReadyAsync()
    {
        scheduler.AssertThread();
        if (state == State.Closed)
            return Task.FromException(new BridgeError("DISCONNECTED", "Bridge is closed"));
        if (ready != null)
            return ready.Task;
        state = State.Connecting;
        helloCallbackId = NextId();
        ready = Completion<bool>();
        handshakeTimer = scheduler.Schedule(
            () => Shutdown(new BridgeError("TIMEOUT", "Handshake timed out")), 5000);
        try
        {
            adapter.Connect(Receive, e =>
                                     {
                                         scheduler.AssertThread();
                                         Shutdown(new BridgeError("DISCONNECTED",
                                                                  "Native transport disconnected"),
                                                  adapter is IBridgeTerminalSender);
                                     });
            if (state == State.Connecting)
                Transmit(new JObject { ["callbackId"] = helloCallbackId,
                                       ["method"] = "bridge.hello", ["params"] = new JObject() });
        }
        catch
        {
            Shutdown(new BridgeError("BRIDGE_UNAVAILABLE", "Cannot connect to native bridge"));
        }
        return ready.Task;
    }
    public CallHandle Call(string method, JObject parameters, Action<BridgeError, JObject> callback,
                           int? timeoutMs = null, string extra = null)
    {
        scheduler.AssertThread();
        if (callback == null)
            throw new ArgumentNullException(nameof(callback));
        return Call(method, parameters, null, result => callback(null, result),
                    error => callback(error, null), timeoutMs, extra);
    }
    public CallHandle Call(string method, JObject parameters, Action<JObject> onData,
                           Action<JObject> onComplete, Action<BridgeError> onError,
                           int? timeoutMs = null, string extra = null)
    {
        scheduler.AssertThread();
        if (onComplete == null || onError == null)
            throw new ArgumentNullException("Call callbacks");
        if (state == State.Closed && flow.UrgentFull)
            throw new BridgeError("BACKPRESSURE", "Callback reserve exhausted");
        string id = NextId();
        var handle = new CallHandle(id, reason => CancelAsync(id, reason));
        var call = new PendingCall(this, id, onData, onComplete, onError);
        try
        {
            int budget = timeoutMs ?? 120000;
            if (state != State.Ready)
                throw new BridgeError(state == State.Closed ? "DISCONNECTED" : "NOT_READY",
                                      "Await ReadyAsync first");
            if (method == null || Encoding.UTF8.GetByteCount(method) > 256 ||
                !Regex.IsMatch(method, @"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)?$"))
                throw new BridgeError("INVALID_METHOD", "Invalid method name");
            foreach (var part in method.Split('.'))
                if (part == "constructor" || part == "prototype" || part == "__proto__")
                    throw new BridgeError("INVALID_METHOD", "Reserved method name");
            if (method.StartsWith("bridge.", StringComparison.Ordinal))
                throw new BridgeError("INVALID_METHOD",
                                      "System methods are reserved for SDK lifecycle APIs");
            if (parameters == null || budget < 1 || budget > 600000)
                throw new BridgeError("INVALID_ARGUMENT",
                                      "Expected params object and valid timeoutMs");
            BridgeJson.ValidateParams(parameters);
            if (extra != null)
                BridgeJson.Stringify(new JObject { ["extra"] = extra }, BridgeJson.MaxBytes - 1024);
            var message = new JObject { ["callbackId"] = id, ["method"] = method,
                                        ["params"] = parameters.DeepClone() };
            if (timeoutMs.HasValue)
                message["timeoutMs"] = budget;
            if (extra != null)
                message["extra"] = extra;
            var raw = BridgeJson.Stringify(message);
            call.Start(budget);
            Diagnostics.Record("start", prefix, id, method);
            Send(raw, id);
        }
        catch (Exception error)
        {
            call.Fail(AsError(error));
        }
        return handle;
    }
    void Callback(Action callback)
    {
        try
        {
            callback();
        }
        catch (Exception error)
        {
            Diagnostics.Record("callback.exception", prefix);
            try
            {
                onCallbackError(error);
            }
            catch
            {
            }
        }
    }
    int PayloadBytes(JObject value)
    {
        return value == null ? 128 : Encoding.UTF8.GetByteCount(value.ToString(Formatting.None));
    }
    static BridgeError BoundedDeliveryError(BridgeError error)
    {
        if (error == null)
            return null;
        string message = error.Message ?? "Bridge error";
        if (message.Length > 256)
        {
            message = message.Substring(0, 256);
            if (char.IsHighSurrogate(message[message.Length - 1]))
                message = message.Substring(0, message.Length - 1);
        }
        return new BridgeError(error.Code, message);
    }
    int ErrorBytes(BridgeError error)
    {
        return Math.Max(
            128,
            PayloadBytes(new JObject { ["error"] = new JObject { ["code"] = error.Code,
                                                                 ["message"] = error.Message } }));
    }
    public Task<BridgeSubscription> SubscribeAsync(string topic, Action<JObject> onData,
                                                   Action<BridgeError> onError = null,
                                                   Action onComplete = null)
    {
        scheduler.AssertThread();
        var done = Completion<BridgeSubscription>();
        Subscription sub = null;
        try
        {
            if (state != State.Ready)
                throw new BridgeError(state == State.Closed ? "DISCONNECTED" : "NOT_READY",
                                      "Await ReadyAsync first");
            if (topic == null || topic.Length < 1 || topic.Length > 128 ||
                !Regex.IsMatch(topic, @"\A[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)*\z"))
                throw new BridgeError("INVALID_ARGUMENT", "Invalid event topic");
            if (onData == null)
                throw new BridgeError("INVALID_ARGUMENT", "Expected data callback");
            if (subscriptions.Count >= 32)
                throw new BridgeError("TOO_MANY_SUBSCRIPTIONS", "Subscription limit reached");
            sub = new Subscription { Id = NextId(), Data = onData, Error = onError,
                                     Complete = onComplete };
            var listener = sub;
            var handle = new BridgeSubscription(sub.Id, () => UnsubscribeAsync(listener));
            subscriptions.Add(sub.Id, sub);
            deliveries.Add(sub);
            SyncGauges(); // 监听器先于控制消息发送与重入初始事件安装。
            Control(
                "bridge.subscribe", new JObject { ["topic"] = topic, ["subscriptionId"] = sub.Id },
                (error, result) =>
                {
                    if (error == null && (result == null ||
                                          BridgeJson.Text(result, "subscriptionId") != listener.Id))
                        error = new BridgeError("PROTOCOL_ERROR",
                                                "Invalid subscription acknowledgement");
                    if (error != null)
                    {
                        RemoveSubscription(listener, true);
                        BestEffortUnsubscribe(listener.Id);
                        done.TrySetException(error);
                    }
                    else
                    {
                        listener.Acked = true;
                        DrainEvents(listener);
                        done.TrySetResult(handle);
                    }
                });
        }
        catch (Exception error)
        {
            if (sub != null)
            {
                RemoveSubscription(sub, true);
                BestEffortUnsubscribe(sub.Id);
            }
            done.TrySetException(AsError(error));
        }
        return done.Task;
    }
    Task<bool> UnsubscribeAsync(Subscription sub)
    {
        scheduler.AssertThread();
        if (sub.Unsubscribe != null)
            return sub.Unsubscribe;
        if (!sub.OffNeeded.HasValue)
            sub.OffNeeded = sub.Active;
        RemoveSubscription(sub, true); // 同步隔离，包括终态前已投递的回调。
        var done = Completion<bool>();
        sub.Unsubscribe = done.Task;
        if (sub.OffNeeded != true || state != State.Ready)
        {
            done.TrySetResult(false);
            return done.Task;
        }
        Control("bridge.unsubscribe", new JObject { ["subscriptionId"] = sub.Id },
                (error, result) =>
                {
                    if (error != null)
                    {
                        sub.Unsubscribe = null;
                        done.TrySetException(error);
                    }
                    else if (result == null || result["accepted"] == null ||
                             result["accepted"].Type != JTokenType.Boolean)
                    {
                        sub.Unsubscribe = null;
                        done.TrySetException(new BridgeError(
                            "PROTOCOL_ERROR", "Invalid unsubscribe acknowledgement"));
                    }
                    else
                    {
                        sub.OffNeeded = false;
                        done.TrySetResult((bool)result["accepted"]);
                    }
                });
        Observe(done.Task);
        return done.Task;
    }
    void Control(string method, JObject parameters, Action<BridgeError, JObject> callback)
    {
        string id = NextId();
        try
        {
            var raw = BridgeJson.Stringify(
                new JObject { ["callbackId"] = id, ["method"] = method, ["params"] = parameters });
            Register(id, callback, 5000, true);
            Send(raw, id);
        }
        catch (Exception error)
        {
            if (pending.ContainsKey(id))
                Finish(id, AsError(error), null);
            else
                callback(AsError(error), null);
        }
    }
    void BestEffortUnsubscribe(string id)
    {
        if (state == State.Ready)
            Control("bridge.unsubscribe", new JObject { ["subscriptionId"] = id },
                    (error, result) =>
                    {});
    }
    void RemoveSubscription(Subscription sub, bool suppress)
    {
        sub.Active = false;
        if (suppress)
            sub.Suppressed = true;
        subscriptions.Remove(sub.Id);
        sub.Buffer.Clear();
        SyncGauges();
        if (sub.Gap != null)
        {
            sub.Gap.Dispose();
            sub.Gap = null;
        }
        if (sub.Queued == 0)
        {
            deliveries.Remove(sub);
            sub.Data = null;
            sub.Error = null;
            sub.Complete = null;
        }
    }
    void FenceSubscriptions()
    {
        foreach (var sub in new List<Subscription>(deliveries))
            RemoveSubscription(sub, true);
    }
    void PostEvent(Subscription sub, Action callback, int bytes = 128)
    {
        if (callback == null)
            return;
        sub.Queued++;
        flow.Enqueue(
            () =>
            {
                try
                {
                    if (!sub.Suppressed && state != State.Closed)
                        Callback(callback);
                }
                finally
                {
                    if (!sub.Active && sub.Queued == 0)
                    {
                        deliveries.Remove(sub);
                        sub.Data = null;
                        sub.Error = null;
                        sub.Complete = null;
                    }
                }
            },
            bytes, false,
            () =>
            { sub.Queued--; });
    }
    void FailSubscription(Subscription sub)
    {
        var callback = sub.Error;
        PostEvent(sub, callback == null ? (Action)null
                                        : () => callback(new BridgeError(
                                              "PROTOCOL_ERROR", "Invalid native event stream")));
        RemoveSubscription(sub, false);
        BestEffortUnsubscribe(sub.Id);
    }
    void ReceiveEvent(string id, JObject frame)
    {
        Subscription sub;
        if (!subscriptions.TryGetValue(id, out sub))
            return;
        try
        {
            if (state != State.Ready)
                throw new FormatException();
            long seq = BridgeResponseValidation.Validate(frame, "event");
            if (seq <= sub.Last || sub.Buffer.ContainsKey(seq))
                return;
            // 订阅响应校验通过前，暂存初始或重入的 Native 事件。
            // 同一个有界重排缓冲也限制确认前的数据保留量。
            if (!sub.Acked)
            {
                if (sub.Buffer.Count >= 32)
                {
                    FailSubscription(sub);
                    return;
                }
                sub.Buffer.Add(seq, frame);
                return;
            }
            if (seq != sub.Last + 1)
            {
                if (sub.Buffer.Count >= 32)
                {
                    FailSubscription(sub);
                    return;
                }
                sub.Buffer.Add(seq, frame);
                StartGap(sub);
                return;
            }
            ConsumeEvent(sub, seq, frame);
            DrainEvents(sub);
        }
        catch
        {
            FailSubscription(sub);
        }
    }
    void DrainEvents(Subscription sub)
    {
        JObject next;
        while (sub.Active && sub.Buffer.TryGetValue(sub.Last + 1, out next))
        {
            sub.Buffer.Remove(sub.Last + 1);
            ConsumeEvent(sub, sub.Last + 1, next);
        }
        if (sub.Gap != null)
        {
            sub.Gap.Dispose();
            sub.Gap = null;
        }
        if (sub.Active && sub.Buffer.Count > 0)
            StartGap(sub);
    }
    void StartGap(Subscription sub)
    {
        if (sub.Gap != null)
            return;
        sub.Gap = scheduler.Schedule(
            () =>
            {
                if (sub.Active)
                    FailSubscription(sub);
            },
            2000);
    }
    void ConsumeEvent(Subscription sub, long seq, JObject frame)
    {
        sub.Last = seq;
        if (frame.Property("data") != null)
        {
            var callback = sub.Data;
            var data = (JObject)frame["data"];
            PostEvent(sub, () => callback(data), Math.Max(receiveBytes, PayloadBytes(frame)));
        }
        else
        {
            if (frame.Property("error") != null)
            {
                var callback = sub.Error;
                var error = ReadError(frame["error"]);
                PostEvent(sub, callback == null ? (Action)null : () => callback(error),
                          Math.Max(receiveBytes, PayloadBytes(frame)));
            }
            else
                PostEvent(sub, sub.Complete, Math.Max(receiveBytes, PayloadBytes(frame)));
            RemoveSubscription(sub, false);
        }
    }
    // 生命周期控制使用独立、轻量的一次性通道。
    void Register(string id, Action<BridgeError, JObject> callback, int timeoutMs,
                  bool internalCallback)
    {
        AcquireSlot(true);
        var p = new Pending { Finish = callback, Internal = internalCallback,
                              Started = Diagnostics.Now };
        pending.Add(id, p);
        p.Timer = scheduler.Schedule(
            () =>
            {
                Diagnostics.Record("timeout", prefix, id);
                Pending current;
                if (!pending.TryGetValue(id, out current) || !ReferenceEquals(current, p))
                    return;
                Finish(id, new BridgeError("TIMEOUT", "Control request timed out"), null);
            },
            timeoutMs);
    }
    Task<CancelAcknowledgement> CancelAsync(string target, string reason)
    {
        scheduler.AssertThread();
        Diagnostics.Record("cancel", prefix, target);
        PendingCall call;
        return calls.TryGetValue(target, out call)
                   ? call.Cancel(reason)
                   : Task.FromResult(new CancelAcknowledgement(false));
    }
    void ControlCancel(string target, string reason,
                       TaskCompletionSource<CancelAcknowledgement> done)
    {
        if (state != State.Ready)
        {
            done.TrySetException(new BridgeError("DISCONNECTED", "Bridge is closed"));
            Observe(done.Task);
            return;
        }
        string id = NextId();
        try
        {
            var raw = BridgeJson.Stringify(
                new JObject { ["callbackId"] = id, ["method"] = "bridge.cancel",
                              ["params"] = new JObject { ["targetCallbackId"] = target,
                                                         ["reason"] = reason } });
            Register(id,
                     (error, result) =>
                     {
                         if (error != null)
                             done.TrySetException(error);
                         else if (result == null || result["accepted"] == null ||
                                  result["accepted"].Type != JTokenType.Boolean)
                             done.TrySetException(new BridgeError(
                                 "PROTOCOL_ERROR", "Invalid cancellation acknowledgement"));
                         else
                             done.TrySetResult(new CancelAcknowledgement((bool)result["accepted"]));
                     },
                     5000, false);
            Send(raw, id);
        }
        catch (Exception error)
        {
            if (pending.ContainsKey(id))
                Finish(id, AsError(error), null);
            else
                done.TrySetException(AsError(error));
        }
        // 读取 Exception 同样可观察尽力执行的 Task；调用方仍可等待同一个错误。
        Observe(done.Task);
    }
    static void Observe(Task task)
    {
        task.ContinueWith(t =>
                          { var ignored = t.Exception; },
                          TaskContinuationOptions.OnlyOnFaulted |
                              TaskContinuationOptions.ExecuteSynchronously);
    }
    void Transmit(JObject message)
    {
        Send(BridgeJson.Stringify(message), null);
    }
    void Send(string raw, string id)
    {
        try
        {
            Diagnostics.Record("send", prefix, id);
            if (state != State.Closed)
                adapter.Send(raw);
        }
        catch
        {
            PendingCall call;
            if (id == null || pending.ContainsKey(id) ||
                (calls.TryGetValue(id, out call) && call.Active))
                Shutdown(new BridgeError("DISCONNECTED", "Native transport send failed"));
        }
    }
    void Receive(string raw)
    {
        scheduler.AssertThread();
        if (state == State.Closed)
            return;
        // 观察者与传输回调可同步嵌套 Receive；每个帧
        // 拥有独立计数上下文，直到其路由和回调准入完成。
        int previousReceiveBytes = receiveBytes;
        try
        {
            // 始终检查语法、重复键、绝对深度与防御性大小限制。
            var route = BridgeJson.ParseResponseObject(raw);
            receiveBytes = Encoding.UTF8.GetByteCount(raw);
            Diagnostics.Record("receive", prefix, BridgeJson.Text(route, "callbackId"),
                               subscriptionId: BridgeJson.Text(route, "subscriptionId"));
            if (BridgeJson.Text(route, "method") == "bridge.close")
            {
                var frame = BridgeJson.ParseObject(raw);
                var parameters = frame["params"] as JObject;
                string code = parameters == null ? null : BridgeJson.Text(parameters, "code"),
                       reason = parameters == null ? null : BridgeJson.Text(parameters, "reason");
                if (frame.Count != 2 || parameters == null || parameters.Count != 2 ||
                    (code != "BACKPRESSURE" && code != "DISCONNECTED") ||
                    string.IsNullOrEmpty(reason) || reason.Length > 256)
                    throw new FormatException();
                Shutdown(new BridgeError(code, "Native bridge closed"), false);
                return;
            }
            string id = BridgeJson.Text(route, "callbackId"),
                   subscriptionId = BridgeJson.Text(route, "subscriptionId");
            if (state == State.Connecting && id == helloCallbackId)
            {
                var helloFrame = BridgeJson.ParseObject(raw);
                BridgeResponseValidation.Validate(helloFrame, "control");
                if (helloFrame.Property("error") != null)
                {
                    Shutdown(ReadError(helloFrame["error"]));
                    return;
                }
                var hello = (JObject)helloFrame["result"];
                if (hello["ready"] == null || hello["ready"].Type != JTokenType.Boolean ||
                    !(bool)hello["ready"])
                    throw new FormatException();
                state = State.Ready;
                handshakeTimer.Dispose();
                handshakeTimer = null;
                ready.TrySetResult(true);
                Diagnostics.Record("ready", prefix);
                return;
            }
            Pending target;
            PendingCall call;
            Subscription subscription;
            // 回调所有权包含已排队调用终态的交付隔离。
            if (id != null && calls.TryGetValue(id, out call))
            {
                if (!call.Active)
                    return;
                try
                {
                    call.Accept(BridgeJson.ParseObject(raw));
                }
                catch
                {
                    call.Fail();
                }
                return;
            }
            if (id != null && pending.TryGetValue(id, out target))
            {
                try
                {
                    var frame = BridgeJson.ParseObject(raw);
                    BridgeResponseValidation.Validate(frame, "control");
                    if (frame.Property("error") != null)
                        Finish(id, ReadError(frame["error"]), null);
                    else
                        Finish(id, null, (JObject)frame["result"]);
                }
                catch
                {
                    Finish(id, new BridgeError("PROTOCOL_ERROR", "Invalid native control response"),
                           null);
                }
                return;
            }
            if (subscriptionId != null &&
                subscriptions.TryGetValue(subscriptionId, out subscription))
            {
                try
                {
                    ReceiveEvent(subscriptionId, BridgeJson.ParseObject(raw));
                }
                catch
                {
                    FailSubscription(subscription);
                }
                return;
            }
            // 只有标识符可靠时，才可忽略未知帧。
            bool callback = route.Property("callbackId") != null,
                 events = route.Property("subscriptionId") != null;
            if (!callback && !events || callback && !BridgeResponseValidation.ValidId(id) ||
                events && !BridgeResponseValidation.ValidId(subscriptionId))
                throw new FormatException();
        }
        catch
        {
            Shutdown(new BridgeError("PROTOCOL_ERROR", "Invalid native message"));
        }
        finally
        {
            receiveBytes = previousReceiveBytes;
        }
    }
    static BridgeError ReadError(JToken token)
    {
        return BridgeResponseValidation.ReadError(token);
    }
    void AcquireSlot(bool control)
    {
        if (control ? controlPending >= 16 : businessPending >= 128)
            throw new BridgeError("TOO_MANY_REQUESTS", "Pending limit reached");
        if (control)
            controlPending++;
        else
            businessPending++;
        SyncGauges();
    }
    void ReleaseSlot(bool control, double started)
    {
        if (control)
            controlPending--;
        else
            businessPending--;
        Diagnostics.Latency(started);
        SyncGauges();
    }
    void ReleaseSlot(Pending p)
    {
        ReleaseSlot(true, p.Started);
    }
    void Finish(string id, BridgeError error, JObject result)
    {
        Pending p;
        if (!pending.TryGetValue(id, out p))
            return;
        pending.Remove(id);
        ReleaseSlot(p);
        if (p.Timer != null)
            p.Timer.Dispose();
        var callback = p.Finish;
        p.Finish = null;
        p.Timer = null;
        if (p.Internal)
            callback(error, result);
        else
            Deliver(callback, error, result, Math.Max(receiveBytes, PayloadBytes(result)),
                    state == State.Closed);
        Diagnostics.Record(error == null ? "end" : "error", prefix, id,
                           code: error == null ? null : error.Code);
    }
    void Deliver(Action<BridgeError, JObject> callback, BridgeError error, JObject result,
                 int bytes = 128, bool urgent = false)
    {
        // 即使没有入站帧上下文，错误回调仍会保留消息；
        // 应独立于封装估算值预留其编码字节数。
        if (urgent && error != null)
        {
            error = BoundedDeliveryError(error);
            bytes = ErrorBytes(error);
        }
        else
            bytes = Math.Max(bytes, error == null ? PayloadBytes(result) : ErrorBytes(error));
        flow.Enqueue(() => Callback(() => callback(error, result)), bytes, urgent,
                     converted: PressureCallback(callback));
    }
    // 独立闭包工厂可防止紧急任务保留原始结果或错误载荷。
    Action PressureCallback(Action<BridgeError, JObject> callback)
    {
        return () =>
                   Callback(() => callback(
                                new BridgeError("BACKPRESSURE", "Callback queue exceeded"), null));
    }
    void SyncGauges()
    {
        int active = 0;
        foreach (var call in calls.Values)
            if (call.Active)
                active++;
        Diagnostics.Delta("pending.business", businessPending - observedBusiness);
        observedBusiness = businessPending;
        Diagnostics.Delta("pending.control", controlPending - observedControl);
        observedControl = controlPending;
        Diagnostics.Delta("active.calls", active - observedCalls);
        observedCalls = active;
        Diagnostics.Delta("active.subscriptions", subscriptions.Count - observedSubscriptions);
        observedSubscriptions = subscriptions.Count;
    }
    static BridgeError AsError(Exception error)
    {
        return error as BridgeError ?? new BridgeError("INVALID_ARGUMENT", "Cannot encode request");
    }
    void Shutdown(BridgeError error, bool notifyNative = true)
    {
        if (state == State.Closed)
            return;
        string close =
            notifyNative && (state == State.Ready || state == State.Connecting)
                ? BridgeJson.Stringify(new JObject {
                      ["callbackId"] = NextId(), ["method"] = "bridge.close",
                      ["params"] = new JObject { ["reason"] = "SDK close" }
                  })
                : null;
        state = State.Closed;
        Diagnostics.Record("close", prefix, code: error.Code);
        FenceSubscriptions();
        foreach (var call in new List<PendingCall>(calls.Values))
            call.Close(new BridgeError(error.Code, "Native transport disconnected"),
                       preserveFinal: true);
        if (handshakeTimer != null)
        {
            handshakeTimer.Dispose();
            handshakeTimer = null;
        }
        if (ready != null && !ready.Task.IsCompleted)
            ready.TrySetException(error);
        foreach (var id in new List<string>(pending.Keys))
            Finish(id, error, null);
        try
        {
            if (close != null)
            {
                var terminal = adapter as IBridgeTerminalSender;
                if (terminal != null)
                    terminal.SendTerminal(close);
                else
                    adapter.Send(close);
            }
        }
        catch
        {
            // 无法通信时由原生宿主兜底关闭。
        }
        try
        {
            adapter.Dispose();
        }
        catch
        {
        }
    }
    public void Dispose()
    {
        scheduler.AssertThread();
        Shutdown(new BridgeError("DISCONNECTED", "Bridge disposed"));
    }
}
}
