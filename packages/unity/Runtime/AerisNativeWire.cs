using System;

namespace Aeris
{
/// 统一平台入口；宿主须先注册与 channel 对应的工厂。
public static class AerisNativeWire
{
    public static IUnityBridgeWire Open(string channel)
    {
#if UNITY_IOS && !UNITY_EDITOR
        return new AerisIOSNativeWire(channel);
#elif UNITY_ANDROID && !UNITY_EDITOR
        return new AerisAndroidNativeWire(channel);
#else
        throw new PlatformNotSupportedException("Native Aeris wire requires an iOS or Android Player");
#endif
    }
}
}
