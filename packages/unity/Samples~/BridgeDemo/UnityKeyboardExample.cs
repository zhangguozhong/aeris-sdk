using Aeris;
using System;
using System.Threading.Tasks;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace Aeris.Samples
{
/// 页面借用已完成 ReadyAsync 的应用级 Core。
/// 在 Unity 主线程初始化；将 OpenKeyboard/CancelKeyboard 绑定到页面 UI。
[UnityEngine.Scripting.APIUpdating.MovedFrom("UnifiedBridgeExample")]
public sealed class UnityKeyboardExample : MonoBehaviour
{
    ClientCore bridge;
    CallHandle current;
    bool visible = true, destroyed;
    int generation;
    public void Initialize(ClientCore sharedCore)
    {
        if (destroyed || bridge != null)
            throw new InvalidOperationException("Keyboard page already initialized/closed");
        bridge = sharedCore ?? throw new ArgumentNullException(nameof(sharedCore));
    }
    public void OpenKeyboard(string text = "", int maxLength = 20)
    {
        if (!visible || destroyed || bridge == null)
            return;
        StopOwnedRequest();
        int owner = ++generation;
        current = bridge.Call(
            "keyboard.open", new JObject { ["text"] = text, ["maxLength"] = maxLength },
            data =>
            {
                if (!Current(owner))
                    return;
                // Native 展示 UI 后才发送 opened；change 携带完整快照。
                Debug.Log("Keyboard " + (string)data["action"] + ": " + (string)data["text"] +
                          ", remaining=" + (int?)data["remainingChars"]);
            },
            result =>
            {
                if (!Current(owner))
                    return;
                current = null;
                Debug.Log("Keyboard complete: " + result.ToString(Newtonsoft.Json.Formatting.None));
            },
            error =>
            {
                if (!Current(owner))
                    return;
                current = null;
                Debug.LogError("Keyboard " + error.Code + ": " + error.Message);
            },
            extra: "unity.page.keyboard");
    }
    bool Current(int owner)
    {
        return visible && !destroyed && generation == owner;
    }
    public async void CancelKeyboard()
    {
        if (!visible || destroyed || current == null)
            return;
        int owner = generation;
        // Task 返回 CancelAcknowledgement.Accepted，不代表原生 UI 已关闭。
        // 本地 CANCELLED 可能先到达。Native 停止监听，但保留租约
        // 直到关闭完成；立即 OpenKeyboard 可能返回 BUSY。
        try
        {
            await current.CancelAsync("keyboard cancel button");
        }
        catch (Exception error)
        {
            if (Current(owner))
                LogException(error);
        }
    }
    void StopOwnedRequest()
    {
        generation++;
        var request = current;
        current = null;
        if (request != null)
            ObserveCancel(request);
    }
    async void ObserveCancel(CallHandle request)
    {
        // 在确认可能到达前，页面已隔离其处理器。
        // 离开页面不等待 UIKit；Session 触发取消，
        // 此操作负责等待关闭完成，然后仅释放自己的租约。
        try
        {
            await request.CancelAsync("keyboard page left or replaced");
        }
        catch
        {
        }
    }
    static void LogException(Exception error)
    {
        try
        {
            Debug.LogException(error);
        }
        catch
        {
        }
    }
    void OnEnable()
    {
        if (!destroyed)
            visible = true;
    }
    void OnDisable()
    {
        visible = false;
        StopOwnedRequest();
    }
    void OnDestroy()
    {
        destroyed = true;
        visible = false;
        StopOwnedRequest();
        bridge = null;
    }
}
}
