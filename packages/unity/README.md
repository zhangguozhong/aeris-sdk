# com.company.aeris

Unity UPM runtime, its adapter, the embedded iOS native channel and export processor, and opt-in lifecycle samples.

Version 0.25.0 preserves the 0.22.0 wire contract and callback lifecycle.

## 通过 UPM 安装

在 Unity Package Manager 中选择 **Add package from git URL**，输入：

```text
https://github.com/zhangguozhong/Aeris.git?path=/packages/unity#0.25.0
```

也可以在 Unity 项目 `Packages/manifest.json` 的 `dependencies` 中添加：

```json
{
  "dependencies": {
    "com.company.aeris": "https://github.com/zhangguozhong/Aeris.git?path=/packages/unity#0.25.0"
  }
}
```

合并到现有 dependencies，保留其他包。`?path=` 指定 UPM 子目录，`#0.25.0` 固定已推送的 tag；这是 Unity 的 Git 包语法，见 [Unity 官方说明](https://docs.unity3d.com/Manual/upm-git.html)。开发机和 CI 的命令行 Git 都需要私有仓库读取权限；GitHub Desktop 已登录不代表 UPM 已有非交互凭据。不要将 token 放入 manifest。提交 manifest 和 `Packages/packages-lock.json`。

本地开发可用 Package Manager 的 **Add package from disk** 选择 `packages/unity/package.json`；离线分发可用 **Add package from tarball** 选择维护者生成的 `artifacts/unity/com.company.aeris-0.25.0.tgz`。后者不随 Git 克隆自动下载。当前保持 UPM 名称 `com.company.aeris`，无需建立 UPM registry。

要求 Unity `2022.3` 或更新版本；UPM 自动解析声明的 `com.unity.nuget.newtonsoft-json` `3.2.1`。业务程序集若使用 asmdef，添加对 `Aeris.Runtime` 的引用；代码使用 `using Aeris;`。Package Manager 中按需导入 Bridge Demo Sample，才可使用 `Aeris.Samples` 下的示例类。

安装 UPM 后即能在 Unity 中开发 C# 部分；iOS 桥接需导出并编译 UnityFramework，完成下方 App 通道绑定后才能实际收发。Editor 和非 iOS Player 不提供这条原生通道。UPM URL 与宿主 Pod 均固定为 `0.25.0` tag；后续升级时同步更新，避免两边从不同版本取源码。

## iOS 内置通道

使用包内的 `AerisIOSNativeWire` 与 `Plugins/iOS` Foundation 原生通道。`Editor/AerisUnityIOSPostprocessor.cs` 在 iOS 导出后将通道复制到 `Libraries/AerisUnity`，只向 UnityFramework target 加入唯一源码、Public Headers 和 umbrella header 引用，重复执行保持幂等。C# 继续使用 `DllImport("__Internal")` 调用既有 C ABI，Native 使用静态反向函数指针返回 UTF-8 数据。Unity 侧不依赖 Aeris/AerisContracts，无需安装 Pod。


Unity 2022.3 的真实 iOS 导出验证补齐了三项构建处理：撤销 UPM 自动副本的编译归属，仅编译 `Libraries/AerisUnity/AerisUnityPlugin.mm`；为该文件显式开启 ARC、Objective-C 异常与 C++17；按构建配置扩展已有符号导出限制，保留 Aeris 的 C ABI、错误常量和宿主 ObjC 类型；原本无白名单的配置不新增白名单。处理器重复执行保持幂等，消息协议与 C# API 不变。不可仅凭头文件声明的 `visibility(default)` 判断动态符号已导出。

原始 `0.25.0` tag 不包含上述导出修复，使用该 tag 验证真实 Player 时需要回补处理器并重新导出 UnityFramework。宿主对 Unity 自身类型的导出、Data 资源归属及运行时启动仍由宿主的 Unity 工程配置负责，Pod 不接管。模拟器验收不能代替真机与前后台测试。

1. 安装 UPM 包并独立导出、编译包含通道的 UnityFramework，放入宿主 App，例如 HostApp/Frameworks。App target 正常引用、嵌入和签名，无需把 Unity 源码工程加入 App workspace。
2. 宿主通过 AerisHost/Unity 或 Aeris/UnityBridge 使用原有 Entry，编译自己的 AppUnityChannel（范本在 examples/ios-host/Unity/AppUnityChannel.swift），通过 AerisUnityChannelAdapter(driver:) 包装后注入 unityChannel 参数。Pods 不导入 UnityFramework，不需要相关安装 hook 或路径变量。
3. Unity 在主线程创建以下 owner，channel 与 App 一致，等待 ready 后调用现有 Bridge API。

宿主的私有 Git Podfile 见[根 README](../../README.md#私有-git-pod-接入)：显式指定同一 `0.25.0` tag 的 AerisContracts、Aeris/Core 和 AerisHost/Unity。只装这三个 Pod 不能代替 Unity 侧 UPM 安装；UPM 中的原生通道编入 UnityFramework，App 的 Pod 中不再编译一份通道源码。

```csharp
using Aeris;
using Aeris.Samples;

var owner = new UnityIOSChannelExample("unity-main");
await owner.ReadyAsync();
owner.Bridge.Call("takePhoto", new Newtonsoft.Json.Linq.JObject(), (error, result) => {
    // 由业务处理结果；App 需要先注册对应方法并授予所需权限。
});
// 容器离开时结束请求、订阅与原生端点。
owner.Dispose();
```

原 Entry、Transport 与连接流程保留。AerisUnityChannel 是可复用服务，bind(factory:channel:) 返回本容器独立 AerisUnityChannelBinding；AerisUnityChannelAdapter 将通用 Receiver 和绑定管理封装在 Pod，AppUnityChannel 仅实现 Driver，Unity Factory 包装归 UPM 插件。具体代码见 examples/ios-host/Unity/UnityBridgeIntegration.swift，以及 examples/ios-host/AerisHost/Unity/UnityHostIntegration.swift。

关闭容器调用 entry.close 或 host.close。全部 C# owner、容器和业务异步资源清理完成后，在主线程调用 prepareForUnityUnload(using: unityChannel)，屏障成功后再卸载 UnityFramework；忙状态必须退出当前调用栈后重试。服务可供不同 channel 复用，同名绑定失败不得影响原有容器。

PluginImporter 和 C ABI 头文件保持原字节；C# Client Core 仅调整命名空间，公开类型名和行为保持不变；原生插件提供闭包 Factory、AerisUnityReceiverCallbacks 以及新增 Checked NSError API。AppUnityChannel 使用 bindChecked / prepareForUnityUnloadChecked，错误原因通过 AerisUnityBridgeCodeKey 转为 BridgeFailure。标准新接线必须更新 UPM 插件并重新导出/编译 UnityFramework，旧 Framework 仅能继续使用旧接线。Editor 和非 iOS Player 仍明确报告不支持。Aeris 子模块与目录为 UIKitContext、SystemEventSources、WebKitBridge、UnityBridge；0.23.0 项目需更新名字并补通道注入，旧 tag 保留。

文档 1.48 / 包 0.25.0。测试包括纯 Pod 无框架编译、宿主实际适配器编译、真实 C# P/Invoke 往返与关闭回归；不替代真实 IL2CPP Player 和真机卸载验收。

## 接收预算、异常断开与诊断

原两参数 UnityAdapter 构造不变；默认排队最多 128 条、4 MiB UTF-8。可用三参数构造传入 `new UnityReceiveLimits(maxMessages: 128, maxBytes: 4194304)`。单条外包装仍限制为 2 MiB，Core 关联、校验和排序逻辑不变。QueuedReceiveMessages / QueuedReceiveBytes 是线程安全的排队快照，UTF-8 预算不是托管堆实际大小。

队列超限或物理断开会立即封闭准入、清空条目中的字符串并释放预算；主线程异步通知一次，旧 Post 不再交付。Dispose 同样立即清空预算。Native Transport 入站解码失败通过已有 bridge.close / DISCONNECTED 回到 Core，结束活动请求并清除订阅，订阅不额外调用 onError。逻辑断开通知返回后，物理 Wire 仍有效时可重建 Core、以新前缀握手；不自动重放请求，不影响其他容器。

主线程调用 AerisUnityPlugin.diagnosticsSnapshot() 读取固定 counters、最近最多 64 条 operation/code/status 失败记录和活动资源 gauges；resetDiagnostics() 清空历史但保留活动路由。诊断不保存 payload、extra 或原始异常。C ABI 状态码和导出方法不变，完整 NSError 代码表与回传时序见设计文档。

## 自定义和兼容通道

Add this package with Package Manager or a local manifest dependency. The package declares `com.unity.nuget.newtonsoft-json` 3.2.1 and the `Aeris.Runtime` assembly. Runtime 使用 `Aeris`，导入示例使用 `Aeris.Samples`，Editor 保持 `Aeris.Editor`。原 `using UnifiedBridgeExample;` 应改为 `using Aeris;`，使用示例时另外添加 `using Aeris.Samples;`。 Construct `UnitySdkWire` with host-provided send/subscribe/unsubscribe delegates, then compose `ClientCore(new UnityAdapter(wire, new UnityProtocolStringCodec()))` for a raw JSON channel on the Unity main thread. Import the Bridge Demo sample as needed. The iOS App supplies its own physical channel; project-specific SDK headers and delegate bindings are outside this repository.

`UnityAdapter(wire)` defaults to `LegacyUnityBridgeCodec`, preserving the existing `componentName` / `methodName` / `data.message` envelope. A channel that already carries unified JSON strings uses `new UnityAdapter(wire, new UnityProtocolStringCodec())`. Implement `IUnityBridgeCodec.EncodeRequest` and `TryDecodeResponse` for another host envelope; return `false` for unrelated component traffic and throw when a matching bridge payload is malformed. Decode failures close that adapter and release its wire ownership.

`IUnityBridgeWire` stays the host send/event boundary. `UnitySdkWire` binds any existing string send, subscribe and unsubscribe delegates without requiring a native export name. The `UnityStringChannelExample` sample owns this delegate binding and a `ClientCore`; its default codec is raw strings, and its optional `codec` argument accepts a host codec:

```csharp
using Aeris;
using Aeris.Samples;

// On Unity's main thread; these delegates come from the host's existing channel.
var owner = new UnityStringChannelExample(host.Send, host.Subscribe, host.Unsubscribe);
await owner.ReadyAsync();
owner.Bridge.Call("echo", new Newtonsoft.Json.Linq.JObject(), (error, result) => {
    // Handle the host's registered method result here.
});
// Dispose when this container closes, including when a queued callback is pending.
owner.Dispose();
```

The host binds raw strings using `UnityHostEntry` and `UnityStringChannelBinding`, and registers the methods it exposes. The App owns each container's listener, validates its routing target, forwards inbound strings on MainActor, and closes the entry before removing the listener and releasing the physical channel. Legacy envelopes can still be converted at the host boundary using `UnityBridgeWire`. One adapter owns each wire; separate containers use separate wires. Create, call and dispose on the Unity main thread; native receives are marshalled there through the bounded queue. Requests remain capped at 256 KiB of UTF-8, and physical native payloads at 2 MiB. Core correlates response identifiers before applying inner size/schema limits so retired responses stay inert. The sample releases its host subscription after a failed handshake or disposal.



## 事件投递与双端清理（1.48）

Native 注册事件时可选 delivery：纯业务 topic 默认 ordered，Provider 默认 latest，显式值独立于 Provider；缓冲为 32 条 / 1 MiB，ordered 超限以 BACKPRESSURE 终止受影响事件组，不静默跳过。四端订阅接口和报文不变。

Core 本地致命错误先封闭请求和订阅，再发送已有 bridge.close 清理 Native，最后关闭 Adapter；Native 关闭或物理断开不回写。UnityAdapter 实现可选 IBridgeTerminalSender，在自身入站已封闭但 Wire 仍有效时发送终态，不接管 Wire 的物理所有权。Unity 暂停后仍依赖 PlayerLoop 恢复，宿主可独立关闭 Native 容器。

退订进行中复用任务，true/false 确认均缓存为成功；失败允许同句柄显式重试相同 subscriptionId，不恢复本地监听。示例最多额外重试一次，不自动无限重试。新增 CleanupTests 与实际 P/Invoke 用例验证错误后 Native 清理及同 Wire 新前缀恢复；JS/Dart 还验证关闭发送失败/挂起与同步退订重入。

导出处理器按覆盖/继承和变量引用语义读取工程中 Target/Project 的 `OTHER_LDFLAGS`、`OTHER_LDFLAGS_FRAMEWORK` 和 `EXPORTED_SYMBOLS_FILE`。若限制仅来自外部 xcconfig 或构建命令行，宿主需在自己的导出策略中保留 Aeris 的公共 C/ObjC 符号；处理器不解析外部配置。
