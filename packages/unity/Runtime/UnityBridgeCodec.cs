using System;
using System.Text;
using Newtonsoft.Json.Linq;

namespace Aeris
{
/// 在宿主通道载荷与统一协议字符串之间转换。
public interface IUnityBridgeCodec
{
    string EncodeRequest(string protocolText);
    // 其他组件的流量返回 false；格式错误的桥接载荷抛出异常。
    bool TryDecodeResponse(string payload, out string protocolText);
}

/// 现有 SDK 封装仍作为默认 Unity 传输格式。
public sealed class LegacyUnityBridgeCodec : IUnityBridgeCodec
{
    public string EncodeRequest(string protocolText)
    {
        UnityBridgeCodecLimits.ValidateRequest(protocolText);
        return BridgeJson.Stringify(
            new JObject { ["componentName"] = "UnifiedBridge", ["methodName"] = "receive",
                          ["data"] = new JObject { ["message"] = protocolText } },
            UnityBridgeCodecLimits.OuterBytes);
    }
    public bool TryDecodeResponse(string payload, out string protocolText)
    {
        protocolText = null;
        UnityBridgeCodecLimits.ValidatePayload(payload);
        var envelope = BridgeJson.ParseObject(payload, UnityBridgeCodecLimits.OuterBytes);
        // 原生事件也可能服务于无关的旧组件。
        if (BridgeJson.Text(envelope, "componentName") != "UnifiedBridge")
            return false;
        var data = envelope["data"] as JObject;
        if (BridgeJson.Text(envelope, "methodName") != "onMessage" || data == null ||
            BridgeJson.Text(data, "message") == null)
            throw new FormatException("Invalid UnifiedBridge envelope");
        protocolText = BridgeJson.Text(data, "message");
        // Core 先关联 callbackId，再校验内部响应的大小与模式。
        return true;
    }
}

/// 适用于通道已直接传输统一 JSON 字符串的宿主。
public sealed class UnityProtocolStringCodec : IUnityBridgeCodec
{
    public string EncodeRequest(string protocolText)
    {
        UnityBridgeCodecLimits.ValidateRequest(protocolText);
        return protocolText;
    }
    public bool TryDecodeResponse(string payload, out string protocolText)
    {
        protocolText = null;
        UnityBridgeCodecLimits.ValidatePayload(payload);
        protocolText = payload;
        return true;
    }
}

internal static class UnityBridgeCodecLimits
{
    public const int OuterBytes = 2 * 1024 * 1024;
    public static void ValidateRequest(string text)
    {
        if (text == null || Encoding.UTF8.GetByteCount(text) > 256 * 1024)
            throw new ArgumentException("Bridge message too large");
    }
    public static void ValidatePayload(string payload)
    {
        if (payload == null || Encoding.UTF8.GetByteCount(payload) > OuterBytes)
            throw new FormatException("Invalid native envelope");
    }
}
}
