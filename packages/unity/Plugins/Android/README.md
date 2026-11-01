# Unity Android 通用 Native Wire

`com.aeris.unity.AerisUnityChannel` 只有 Java 标准库依赖。它随 UnityLibrary 编译，不能把项目 SDK、Aeris Core 或宿主 AAR 放进 Unity 工程。SDK 宿主接线位于 `native/android/aeris-unity`，依赖方向是宿主 → Core + UnityLibrary 的通道契约。

## Android 宿主

宿主 app 同时依赖导出的 UnityLibrary 与 `:aeris-unity`。`aeris-unity` 对 `:aeris-unity-channel` 使用 **compileOnly**；后者只是引用同一份 Java 源码的契约编译模块，不应作为 app 的 runtime 依赖或再次打进 AAR。最终 APK 的通道类唯一来源是 UnityLibrary。

```kotlin
// 在启动该 Unity 容器之前绑定；每个并存容器必须使用不同名称。
val unityBridge = AerisUnityChannelDriver(
    channel = "game.primary",
    engine = engine,
    uiContext = uiContext,
    allowedPermissions = setOf("device.read"),
    allowedEventTopics = setOf("app.appearance"),
)

// 普通容器退出：关闭该连接，其余容器不受影响。
unityBridge.close()

// 整个 Unity 运行时卸载：在 Android 主线程、退出所有 JNI 回调调用栈之后执行。
AerisUnityChannelDriver.prepareUnload()
unityPlayer.unload() // 或宿主实际使用的 destroy 入口

// 新的 UnityPlayer 启动前恢复，再重新创建 Driver。
AerisUnityChannelDriver.resume()
```

Driver 为每次打开创建独立 `AerisUnityNativeTransport`，使用 `BridgeSource.UNITY = 4`，并将连接异常关闭通知转成物理 Wire 断开。权限、UIContext 与 topic 白名单均来自宿主注入。

## Unity C#

```csharp
// Unity 主线程，且在 Android 宿主完成上述绑定之后。
IUnityBridgeWire wire = AerisNativeWire.Open("game.primary");
var adapter = new UnityAdapter(wire, new UnityProtocolStringCodec());
var client = new ClientCore(adapter);
await client.ReadyAsync();
// 使用现有 client.Call / Event API；业务协议不改变。

client.Dispose();
((IDisposable)wire).Dispose();
```

也可直接使用 `new AerisAndroidNativeWire("game.primary")`。JNI 调用使用 Unity 自带的 `AndroidJavaClass` 和 `AndroidJavaProxy`，不需要任何业务 SDK。统一入口在 iOS 仍选择原来的 `AerisIOSNativeWire`；Editor 和其他平台明确拒绝原生打开。Core/Adapter 需要使用 `UnityProtocolStringCodec`，因为 Android NativeTransport 直接接收统一协议字符串。

所有 Wire 创建、发送、Dispose 操作都在 Unity 主线程。Java → C# 回调可来自 Android 主线程，Wire 用创建时捕获的 `SynchronizationContext` 切回 Unity 主线程，再由既有 Adapter/Core 处理。`link.xml` 保留 Android Wire 及条件编译的嵌套 JNI 代理，导出规则保留 Java 反射入口；前缀通配格式见 [Unity Link XML 文档](https://docs.unity.com/en-us/engine/6000.0/manual/scripting/compilation-and-code-reload/script-compilation/managed-code-stripping/xml-formatting)。

## 不依赖 Aeris Core 的自定义宿主

```java
AerisUnityChannel.Binding binding = AerisUnityChannel.bind(
    "custom.game",
    emitter -> new AerisUnityChannel.Receiver() {
        public void receive(String text) { emitter.emit(text); }
        public void close() { /* 清理当前容器 */ }
    },
    serializedHostMainExecutor
);
// 异常时调用该 Receiver 所属 emitter.disconnect("HOST_DISCONNECTED")。
binding.close();
```

Executor 必须提供 FIFO、串行宿主线程执行，并在所有 Binding 完成关闭之前保持可用。Factory、Receiver.receive/close、托管回调的排队工作均通过该 Executor 执行；终止通知可在触发终止的线程同步到达，C# 总是再切回 Unity 线程。每条 Binding 同时只允许一个打开句柄；关闭后重新打开产生新句柄，旧 Receiver 的 Emitter 不会进入新连接。

通道名称限制为 1–128 个 ASCII 字母、数字或 `_.:-`。最多 128 个 Binding；每个 Endpoint 共用发送/回调队列的 128 条、4 MiB UTF-8 字节预算，单条上限 2 MiB。C# 入站队列另有同样默认预算。溢出、无效 UTF-8、Factory/Receiver/回调异常都会终止当前连接并释放待交付字符串。关闭与卸载先撤销句柄及回调引用，再清理 Receiver；迟到回调被隔离。回调或托管 JNI 调用尚未返回时 `prepareUnload` 会拒绝重入。

## UPM 导出与验证

`.java.meta` 禁止 Unity 自动再次加入源码；`AerisUnityAndroidPostprocessor` 在 Android Gradle 导出后把唯一 Java 源复制进 UnityLibrary `src/main/java`，附加 consumer ProGuard 规则，可重复执行。iOS 导出处理器没有修改。

从仓库根目录运行：

```sh
python3 tests/packaging/unity_android_plugin_test.py
```

它执行真实 `javac/java` plain JVM 生命周期测试，并用 .NET 编译全部 C# Runtime，执行 JNI 边界替身测试和导出文件 fixture 测试。提供 `AERIS_UNITY=/path/to/Unity.app` 且安装了 Android 支持模块时，还会针对真实 Unity Android JNI 与 Editor 扩展程序集编译 Runtime 和导出处理器；本机已通过 Unity 2021.3.24f1 的这项 API 编译检查。需要 JDK 17、.NET 8；可设置 `JAVA_HOME` 与 `AERIS_NEWTONSOFT`（默认复用 .NET SDK 随附的 Newtonsoft DLL）。这些验证不要求安装 Android SDK，也不代表真实 Unity Android Player、IL2CPP、Gradle 导出构建或设备测试已经通过；这些仍需在具备 Unity Android 模块和 Android SDK 的环境验证。

## 真实Player本机验收

新增 `examples/unity-android-host`，通过真实Editor导出unityLibrary/IL2CPP并由原生宿主注入Engine。详见 [Unity Android接入与验收](../../../../docs/UnityAndroid接入与验收.md)。入口 `bash tooling/unity-android/verify.sh` 不使用GitHub CI；先验证缺Driver真实失败，再检查九个实际场景及真正卸载回调。暂停时Native可入Wire队列，Unity业务需恢复PlayerLoop才能消费；暂停关闭由Native独立清理。

UPM包补充Android JNI内置模块依赖，解决全新工程AndroidJavaClass/Proxy缺失；协议、Java类名和C#公开API不变。本地候选尚未发布或覆盖0.26.0-preview.1 tag。原生App还须引入UnityPlayer编译契约和launcher生成资源；生成工程的新Gradle兼容只由验证工具处理，不写回Unity安装目录。
