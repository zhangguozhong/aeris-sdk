using Aeris;
using System;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Aeris.Samples
{
/// 现有 SDK 启动流程在原生 API 就绪后，于 Unity 主线程调用 Initialize。
/// 此组件拥有绑定；共享的应用级 SDK 应放在持久启动组件中。
[UnityEngine.Scripting.APIUpdating.MovedFrom("UnifiedBridgeExample")]
public sealed class UnityBridgeExample : MonoBehaviour
{
    ClientCore bridge;
    UnitySdkWire wire;
    CallHandle current;
    bool destroyed;
    bool eventsStarted;
    int eventGeneration;
    BridgeSubscription networkEvents, appearanceEvents;
    // 面向 Unity 的入口捕获异步失败；启动流程可直接等待 InitializeAsync。
    public async void Initialize(Action<string> sdkSend, Action<Action<string>> subscribeNative,
                                 Action<Action<string>> unsubscribeNative)
    {
        try
        {
            await InitializeAsync(sdkSend, subscribeNative, unsubscribeNative);
        }
        catch (Exception error)
        {
            if (!destroyed)
                Debug.LogException(error);
        }
    }
    public async Task InitializeAsync(Action<string> sdkSend,
                                      Action<Action<string>> subscribeNative,
                                      Action<Action<string>> unsubscribeNative)
    {
        // 异步 Task 捕获此拒绝；重复初始化时不要关闭现有健康绑定。
        if (destroyed || bridge != null)
            throw new InvalidOperationException("Bridge owner already initialized/closed");
        try
        {
            wire = new UnitySdkWire(sdkSend, subscribeNative, unsubscribeNative);
            bridge = new ClientCore(new UnityAdapter(wire), Debug.LogException);
            await bridge.ReadyAsync(); // Unity SynchronizationContext 恢复到主线程。
            if (destroyed)
                return;
            TakePhoto();
        }
        catch
        {
            Close();
            throw;
        }
    }
    public void TakePhoto()
    {
        if (destroyed || bridge == null)
            return;
        current = bridge.Call("takePhoto", new JObject { ["quality"] = 80 },
                              (error, photo) =>
                              {
                                  if (destroyed)
                                      return; // 所有者销毁时，终态回调可能已经入队。
                                  if (error != null)
                                  {
                                      Debug.LogError(error.Code + ": " + error.Message);
                                      return;
                                  }
                                  Debug.Log("Photo result: " + (string)photo["resourceId"] +
                                            ", source=" + (string)photo["source"]);
                              },
                              extra: "unity.feature.takePhoto");
    }
    public async void CancelPhoto()
    {
        if (current == null || destroyed)
            return;
        try
        {
            var ack = await current.CancelAsync();
            if (!destroyed)
                Debug.Log("Cancel accepted: " + ack.Accepted);
        }
        catch (Exception error)
        {
            if (!destroyed)
                Debug.LogException(error);
        }
    }
    // 原生 UI 与桥接初始化后，将这两个入口绑定到 Unity UI 按钮。
    // 事件仍需主动启用；InitializeAsync 继续演示原有拍照流程。
    public async void StartEvents()
    {
        if (destroyed || bridge == null || eventsStarted)
            return;
        eventsStarted = true;
        int generation = ++eventGeneration;
        var owner = bridge;
        try
        {
            await StartEventAsync(owner, "network.changed", generation);
            if (EventOwnerCurrent(owner, generation))
                await StartEventAsync(owner, "appearance.changed", generation);
        }
        catch (Exception error)
        {
            ReportEventError(error);
        }
    }
    bool EventOwnerCurrent(ClientCore owner, int generation)
    {
        return !destroyed && eventsStarted && eventGeneration == generation &&
               ReferenceEquals(bridge, owner);
    }
    async Task StartEventAsync(ClientCore owner, string topic, int generation)
    {
        try
        {
            var subscription = await owner.SubscribeAsync(
                topic,
                data =>
                {
                    if (EventOwnerCurrent(owner, generation))
                        LogEvent(() => Debug.Log(topic + ": " +
                                                 data.ToString(Newtonsoft.Json.Formatting.None)));
                },
                error =>
                {
                    if (EventOwnerCurrent(owner, generation))
                        LogEvent(
                            () => Debug.LogError(topic + ": " + error.Code + ": " + error.Message));
                },
                () =>
                {
                    if (EventOwnerCurrent(owner, generation))
                        LogEvent(() => Debug.Log(topic + ": complete"));
                });
            if (!EventOwnerCurrent(owner, generation))
            {
                // Native 仍在确认订阅时，stop/destroy 可能先执行。
                await subscription.UnsubscribeAsync();
                return;
            }
            if (topic == "network.changed")
                networkEvents = subscription;
            else
                appearanceEvents = subscription;
        }
        catch (Exception error)
        {
            if (EventOwnerCurrent(owner, generation))
                ReportEventError(error);
        }
    }
    public void StopEvents()
    {
        eventsStarted = false;
        eventGeneration++;
        var network = networkEvents;
        var appearance = appearanceEvents;
        networkEvents = null;
        appearanceEvents = null;
        if (network != null)
            StopEvent(network);
        if (appearance != null)
            StopEvent(appearance);
    }
    async void StopEvent(BridgeSubscription subscription)
    {
        try
        {
            await subscription.UnsubscribeAsync();
        }
        catch (Exception)
        {
            // 示例层最多重试一次；暂停时仍需等待 Unity 主线程恢复。
            await Task.Delay(250);
            try
            {
                await subscription.UnsubscribeAsync();
            }
            catch (Exception error)
            {
                ReportEventError(error);
            }
        }
    }
    static void LogEvent(Action log)
    {
        try
        {
            log();
        }
        catch
        {
        }
    }
    void ReportEventError(Exception error)
    {
        if (!destroyed)
            LogEvent(() => Debug.LogException(error));
    }
    void OnDestroy()
    {
        destroyed = true;
        Close();
    }
    void Close()
    {
        // Core.Dispose 负责最终传输与订阅清理，包括尚未确认的启动。
        eventsStarted = false;
        eventGeneration++;
        networkEvents = null;
        appearanceEvents = null;
        if (bridge != null)
        {
            bridge.Dispose();
            bridge = null;
        }
        if (wire != null)
        {
            wire.Dispose();
            wire = null;
        }
        current = null;
    }
}
}
