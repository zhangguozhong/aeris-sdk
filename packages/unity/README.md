# Aeris Unity

Unity2022.3+，C# Core/Adapter与iOS/Android通用原生通道。版本`0.26.0-preview.1`。

UPM Git URL：

```text
https://github.com/zhangguozhong/aeris-sdk.git?path=/packages/unity#0.26.0-preview.1
```

iOS插件随UnityFramework编译；App使用AerisHost/Unity并注入AerisUnityChannel，不依赖外置AerisUnity.framework。Android通道由UnityLibrary编译，App创建AerisUnityChannelDriver；Maven通道JAR只能作为宿主编译契约，禁止重复runtime打包。C#使用AerisNativeWire按平台选JNI或iOS C入口。

Player暂停时C#消费暂停，Native仍能有界排队和清理；卸载前关闭Driver，等待Native清理，再调用真实unload。不能靠取消确认推断UI或任务已释放。

[完整接入与预览范围](https://github.com/zhangguozhong/aeris-sdk/tree/0.26.0-preview.1/README.md)。MIT。
