# Aeris Unity

Aeris Unity 为 Unity 提供 C# Client Core、Adapter 和 iOS/Android 原生通道，支持调用原生、callback、持续回调、事件订阅、取消和按容器隔离的连接。

## 配套版本

| 组件 | 版本 |
| --- | --- |
| Unity UPM 包 `com.company.aeris` | `0.26.0-preview.3` |
| Git tag | `unity-0.26.0-preview.3` |
| Aeris iOS Pods / Android Maven | `0.26.0-preview.2` |
| Unity | `2022.3+`（本机验收 `2022.3.62f3c1`） |
| Newtonsoft.Json | `3.2.1`，由 UPM 自动解析 |
| 平台最低版本 | iOS `15.0` / Android API `24` |

Android 原生宿主使用 Java 17、compileSdk 37。Unity 的 Player 构建仍使用对应 Unity 版本支持的工具链。编辑器 Play Mode 不提供 iOS/Android 原生通道，实际通信需运行相应 Player。

`preview.3` 修复只读 Git UPM 包的资源元数据，不修改通信协议、C# API 或 Native 依赖版本。包 ID 保留 `com.company.aeris`，代码命名空间为 `Aeris`。

## 1. 在 Unity 安装

打开 **Window → Package Manager → + → Add package from git URL**，输入：

```text
https://github.com/zhangguozhong/aeris-sdk.git?path=/packages/unity#unity-0.26.0-preview.3
```

也可以在项目 `Packages/manifest.json` 的 `dependencies` 中合并：

```json
{
  "com.company.aeris": "https://github.com/zhangguozhong/aeris-sdk.git?path=/packages/unity#unity-0.26.0-preview.3"
}
```

保留项目原有依赖，不要用这个片段覆盖完整文件。安装需要本机 Git 和网络访问；提交 `Packages/manifest.json` 与 `Packages/packages-lock.json`，让团队和出包使用同一份代码。

安装后 Unity 能识别 `using Aeris;`。包自动引入 Newtonsoft.Json 和 Android JNI 模块。若业务使用自定义 asmdef，在 references 中增加 `Aeris.Runtime`；需要直接使用 JObject 的业务程序集也应引用 `Unity.Newtonsoft.Json`。

在 Package Manager 的 Aeris 页面，导入 **Samples → Bridge Demo**。示例导入 Assets 后编译为独立 `Aeris.Samples` 程序集；不要同时复制另一份 Runtime 或手工放入重复的通道源码。

离线交付也可从本版本 GitHub Release 下载 `com.company.aeris-0.26.0-preview.3.tgz`，使用 **Add package from tarball**。此时来源为 Local tarball，而非 Git；任选一种安装方式。

## 2. iOS 宿主接入

Unity 导出 iOS 工程时，包中的 Postprocessor 自动把通用 C ABI 通道编入 **UnityFramework**，并公开三个通道头文件。构建并将生成的 `UnityFramework.framework` 链接、嵌入宿主 App，Data 的归属与宿主 `setDataBundleId` 配置一致。

宿主 Podfile：

```ruby
source 'https://github.com/zhangguozhong/leo-podspecs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '15.0'
use_frameworks! :linkage => :static

target 'HostApp' do
  pod 'AerisContracts', '= 0.26.0-preview.2'
  pod 'Aeris/Core', '= 0.26.0-preview.2'
  pod 'AerisHost/Unity', '= 0.26.0-preview.2'
end
```

执行 `pod install` 后打开 workspace。UnityFramework 由宿主自己的工程管理；Aeris Pod 不查找 UnityFramework 路径，不需要 Aeris 专用 post_install，也不需要外置 AerisUnity.framework。

业务 App 实现唯一依赖 UnityFramework 的接口接线：

```swift
import Aeris
import Foundation
import UnityFramework

@MainActor final class AppUnityChannel: AerisUnityChannelDriver {
    func bind(
        channel: String,
        makeReceiver: @escaping Aeris.AerisUnityReceiverBuilder
    ) throws -> @MainActor () -> Void {
        let binding = try AerisUnityPlugin.bindChecked(
            channel: channel,
            makeReceiver: { emit in
                guard let receiver = makeReceiver(emit) else { return nil }
                return AerisUnityReceiverCallbacks(
                    receive: receiver.receiveMessage,
                    close: receiver.close
                )
            }
        )
        return { binding.close() }
    }

    func prepareForUnityUnload() throws {
        try AerisUnityPlugin.prepareForUnityUnloadChecked()
    }
}
```

Engine、模块注册与每容器绑定：

```swift
import Aeris
import AerisHost
import UIKit

@MainActor final class ProjectBridge: NSObject, BridgeModule {
    let moduleName = "ProjectBridge"

    @objc func echo(_ session: BridgeSession) {
        // 后台工作也只持有本次 Session，不把请求保存在共享 Bridge 的当前请求属性中。
        DispatchQueue.main.async {
            session.callback(["message": "hello", "source": session.source])
        }
    }
}

@MainActor final class UnityBridgeOwner {
    private let channel = AerisUnityChannelAdapter(driver: AppUnityChannel())
    private var host: UnityHost?

    // App 启动时调用一次；多个容器使用同一个 Engine。
    static func configureEngine() throws -> BridgeEngine {
        let engine = BridgeEngine.shared
        try engine.configureDefaultModule("ProjectBridge")
        try engine.register(module: ProjectBridge())
        try engine.registerEvent(topic: "project.changed", delivery: .ordered)
        return engine
    }

    func bind(engine: BridgeEngine, container: UIViewController) throws {
        guard host == nil else { return }
        host = try UnityHost(
            configuration: AerisHostConfiguration(
                engine: engine,
                allowedEventTopics: ["project.changed"]
            ),
            channel: "game.main",
            unityChannel: channel,
            containerViewController: container
        )
    }

    func close() {
        host?.close()
        host = nil
    }

    func prepareForUnload() throws {
        try UnityHost.prepareForUnityUnload(using: channel)
    }
}
```

先创建并保留 `UnityBridgeOwner`、绑定，再启动 Player 让 C# 打开同名 `game.main`。新增容器创建独立 Owner 与 channel；不要覆盖已有绑定。权限通过 `AerisHostConfiguration` 按容器注入。

## 3. Android 宿主接入

Unity 导出 Android 工程时，Postprocessor 把通用 Java 通道复制到 **unityLibrary**。App 将该模块作为 Unity as a Library 接入，通道实现随它打包。

在宿主实际生效的 Gradle 仓库配置中增加：

```kotlin
maven {
    url = uri("https://raw.githubusercontent.com/zhangguozhong/aeris-maven/0.26.0-preview.2")
}
```

App 的依赖：

```kotlin
implementation(project(":unityLibrary"))
implementation("com.aeris.sdk:aeris:0.26.0-preview.2")
implementation("com.aeris.sdk:aeris-unity:0.26.0-preview.2")
// 仅提供宿主编译所需的通道类型；运行时唯一实现来自 unityLibrary。
compileOnly("com.aeris.sdk:aeris-unity-channel:0.26.0-preview.2")
```

若 App 直接使用 UnityPlayer 类型，按导出工程位置为 `unity-classes.jar` 配置 compileOnly；不要再 implementation 相同 jar。不能同时打包 Maven channel JAR 和 unityLibrary 中的 Java 源码实现。

在 Android 主线程，先配置共享 Engine 和业务 Bridge，再绑定容器：

```kotlin
import com.aeris.sdk.BridgeEngine
import com.aeris.sdk.AndroidBridgeUIContext
import com.aeris.sdk.unity.AerisUnityChannelDriver

// root 是本容器真实持有的 View；owner 由 Activity/Fragment 生命周期持有。
val context = AndroidBridgeUIContext(root)
val owner = AerisUnityChannelDriver(
    channel = "game.main",
    engine = BridgeEngine.shared,
    uiContext = context,
    allowedEventTopics = setOf("project.changed"),
)
```

此处只演示绑定；Android Engine 同样需要宿主注册 `echo` 方法和 `project.changed` topic，方法实现使用 `session.callback(...)`。必须先绑定再让 C# 打开通道；Java 通道本身不包含业务方法。

## 4. C# 打开连接和调用

以下方法从 Unity 主线程执行，创建后持续持有 `ClientCore` 和 Wire：

```csharp
using System;
using System.Threading.Tasks;
using Aeris;
using Newtonsoft.Json.Linq;
using UnityEngine;

public sealed class GameBridge : IDisposable
{
    private readonly IUnityBridgeWire wire;
    private readonly ClientCore client;

    public GameBridge()
    {
        wire = AerisNativeWire.Open("game.main");
        try
        {
            client = new ClientCore(
                new UnityAdapter(wire, new UnityProtocolStringCodec()),
                Debug.LogException
            );
        }
        catch
        {
            (wire as IDisposable)?.Dispose();
            throw;
        }
    }

    public Task ReadyAsync() => client.ReadyAsync();

    public CallHandle Echo()
    {
        return client.Call(
            "echo",
            new JObject { ["message"] = "hello" },
            (error, result) =>
            {
                if (error != null)
                    Debug.LogError(error.Code + ": " + error.Message);
                else
                    Debug.Log(result);
            },
            extra: "game.home"
        );
    }

    public Task<BridgeSubscription> SubscribeAsync()
    {
        return client.SubscribeAsync(
            "project.changed",
            data => Debug.Log(data),
            error => Debug.LogException(error)
        );
    }

    public void Dispose()
    {
        try { client.Dispose(); }
        finally { (wire as IDisposable)?.Dispose(); }
    }
}
```

启动流程创建 GameBridge 后等待 `ReadyAsync()`，再调用 `Echo()` 或订阅。保存返回的 CallHandle，需要取消时等待 `CancelAsync()`；保存 BridgeSubscription，需要退订时等待 `UnsubscribeAsync()`。宿主必须先注册允许订阅的 topic，并通过 `Engine.publish` 发布数据。

原生回传顺序是 **Session / EventHub → Connection → Transport → 平台插件 → Wire → Adapter → Client Core → 业务 callback**。C# 不直接引用 Swift Engine 或 Android业务 Bridge。

## 5. 关闭、暂停和卸载

单容器关闭：Unity 主线程先 Dispose C# owner，原生主线程关闭对应 UnityHost/Driver 并撤销 UIContext；实际业务取消和 UI dismiss 完成后才释放对应任务资源。

卸载整个 Player：

1. Dispose 全部 C# owner；关闭全部原生容器绑定，停止创建新调用。
2. 等待原生 Session、订阅及业务任务真实清理完成。取消 accepted、close 方法返回都不能代替资源清理完成。
3. 退出当前 C ABI/JNI 和反向 callback 调用栈。
4. iOS 调用 `prepareForUnload()`；成功后再调用 `UnityFramework.unloadApplication()`，等待 `unityDidUnload`。屏障失败时先修复未清理资源，再重试。
5. Android 在主线程调用 `AerisUnityChannelDriver.prepareUnload()`，成功后再调用 UnityPlayer.unload/destroy；下次启动新的 Player 前调用 `AerisUnityChannelDriver.resume()` 并重新绑定。resume 不是暂停后每次恢复都要调用的业务动作。

Unity 暂停或进入后台时，托管 callback 依赖 PlayerLoop，不能保证持续执行。Native 仍可监听事件、有界排队和清理；恢复后按队列策略交付。普通暂停不销毁 Engine 或连接，不要每次 OnApplicationPause 都创建新 owner。旧连接关闭后的 callback 不得复用到新 owner。

## 升级

将 Git ref 更新到目标版本，重新解析 UPM 并提交 lock，重新导出 UnityFramework / unityLibrary。原生通道属于 Unity 构建产物，单独更新 Pod 不会替换旧 Player 中的 C ABI/JNI 实现。

本版本继续使用现有 Aeris Native `0.26.0-preview.2`，无需重新发布或升级 npm 包。此前 `0.26.0-preview.2` UPM Git 安装缺少资源 meta，请改用本页的 Unity 专用 tag。

## 许可证

[MIT](LICENSE)。
