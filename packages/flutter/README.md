# aeris_flutter

Flutter 插件包含 Dart Client Core、Adapter 和薄 iOS / Android 原生插件。当前包版本 `0.26.0-preview.1`；要求 Dart `>=3.6.0 <4.0.0`、Flutter `>=3.41.0`。当前源码声明 iOS 和 Android；既有 `0.26.0-preview.1` tag 不会被此次 Android 补齐覆盖。

## 1. 通过私有 Git 安装

在实际 Flutter App 或嵌入式模块的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  flutter:
    sdk: flutter
  aeris_flutter:
    git:
      url: https://github.com/zhangguozhong/Aeris.git
      ref: '0.26.0-preview.1'
      path: packages/flutter
```

```sh
flutter pub get
```

本地开发时，将这项 Git 依赖替换为 `path: /path/to/Aeris/packages/flutter`，不同时声明两种来源。Flutter 支持 Git 仓库子目录包，详见 [Dart 官方依赖说明](https://dart.dev/tools/pub/dependencies#git-packages)。包保持 `publish_to: none`，不需要上传 pub.dev。开发机和 CI 需要自行配置私有 Git 读取凭据。

在初始化 Flutter binding 后创建客户端：

```dart
import 'package:flutter/widgets.dart';
import 'package:aeris_flutter/aeris_flutter.dart';

Future<BridgeClient> connectToNative() async {
  WidgetsFlutterBinding.ensureInitialized();
  final bridge = BridgeClient(FlutterAdapter());
  await bridge.ready();
  bridge.call('takePhoto', {'quality': 80}, (error, result) {
    // 宿主需注册对应方法并授予权限。
  });
  // 调用者持有返回的 bridge，在容器最终销毁时 await bridge.dispose()。
  return bridge;
}
```

同一个 FlutterEngine 的主 isolate 保持一个连接所有者。Dart 代码随 Flutter 模块编译，Pod 只编译插件的 iOS 部分。

## 2. 嵌入原生 App 的 Pod 接入

在 Flutter 模块执行 `flutter pub get`、生成平台包装后，宿主保留模块的 `.ios/Flutter/podhelper.rb` 和 `install_all_flutter_pods`。在实际 App target 中增加：

```ruby
aeris_source = {
  :git => 'https://github.com/zhangguozhong/Aeris.git',
  :tag => '0.26.0-preview.1'
}

pod 'AerisContracts', **aeris_source, :modular_headers => true
pod 'Aeris/Core', **aeris_source
pod 'AerisHost/Flutter', **aeris_source
```

`aeris_flutter` 原生 Pod 由 Flutter podhelper 安装，不重复声明 Git 来源。执行宿主的 `pod install` 后，App 启动 FlutterEngine、注册插件，再创建并持有该容器独立的 `FlutterHost`，由 Host 将 Transport 注入注册表中的插件实例，然后 Dart 才调用 `ready()`。关闭时调用 `host.close()`，再释放对应 FlutterEngine；模块能运行不代表桥接已经完成绑定。

完整 Podfile 见 [Flutter Podfile](../../examples/ios-host/AerisHost/Flutter/Podfile)，启动、注册与绑定见 [FlutterHostIntegration.swift](../../examples/ios-host/AerisHost/Flutter/FlutterHostIntegration.swift)。示例中的本地 Aeris `:path` 三行可替换为上面的私有 Git 三行。App 提交 Podfile.lock，Flutter 功能模块按其应用工程管理 pubspec.lock，并在 CI 使用同一套锁定依赖。

当前源码的物理通道统一为 `aeris_bridge`，Dart Adapter 与对应平台原生插件必须成对升级；默认 pluginClass 和 registry key 为 `AerisUnifiedBridgePlugin`。Installer 优先查新 key，只在未找到时回退 `UBUnifiedBridgePlugin`。每个 Engine 只注册一套入口，不能同时注册新旧插件。

## 3. 分发和验证

Flutter 目前可直接使用上面的 Git 依赖，无需另建 Dart 仓库。`ref` 与宿主 Pod 均固定为 `0.26.0-preview.1` tag；后续升级时同步更新。Pod 说明见[根 README](../../README.md#私有-git-pod-接入)。离线交付可解压 `artifacts/flutter/aeris_flutter-0.26.0-preview.1.tar.gz`，再用 `path` 引用解压后的插件根目录；该归档由维护者生成，不随 Git 自动下载。


## Flutter 框架回归

在仓库的 `tests/flutter-framework` 中执行 `flutter pub get` 和 `flutter test`，验证真实 `BasicMessageChannel` 的类型约束及空确认行为。可空通道类型用于框架确认，业务消息仍必须是非空字符串；不会修改 Aeris 协议。

远程 `0.26.0-preview.1` tag 尚未包含此次可空通道修复，在 Flutter 3.47.8 实际构建时会出现 `Future<String>` 不能返回 `null` 的编译错误。使用修复后的源码验证，待后续版本发布后再切换正式 tag，不覆盖已有 tag。

## 通道名称升级

当前源码使用 `aeris_bridge`，旧 tag 的通道为 `unified_bridge`。升级时同时更新 Dart 包和其中的原生插件，并重新执行宿主的 `pod install`；仅更新一端会导致握手失败。新旧插件常量符号都指向当前通道，旧 registry key 与 `unified_bridge.dart` 导入兼容入口继续保留。该改名不增加新的 JSON 字段，也不覆盖已有 tag。

## Android 宿主绑定

Android 插件源码位于本包的 `android/`（仓库路径 `packages/flutter/android`），不是缺少 `native/android/aeris-flutter` 目录。原生聚合工程将该目录映射为 `:aeris-flutter`；Flutter 工具直接按 pubspec.yaml 的 Android 插件声明加载同一份源码。

Android 使用 `com.aeris.sdk` Core 和独立 Flutter 插件，不依赖业务 SDK。宿主要求 minSdk 24、compileSdk 37、Java 17 和支持内置 Kotlin 的 AGP 9。Flutter 工具会注册 `com.aeris.sdk.flutter.AerisUnifiedBridgePlugin`；注册不代表已绑定 Aeris Engine。Android Core 可优先从源码构建；宿主在 `settings.gradle.kts` 中把 Core 加为项目（路径按实际 checkout 调整）：

```kotlin
include(":aeris")
project(":aeris").projectDir = file("/path/to/Aeris/native/android/aeris")
```

Flutter 依赖保持本包源码路径。宿主在主线程注册模块和事件源，然后从对应 `FlutterEngine` 的插件注册表取出实例，注入该容器的接收器：

```kotlin
import com.aeris.sdk.*
import com.aeris.sdk.flutter.AerisUnifiedBridgePlugin

val aeris = BridgeEngine.shared
aeris.installSystemEventProviders(applicationContext) // 每个 Aeris Engine 只装一次
// aeris.register(MyDefaultBridge())
val uiContext = AndroidBridgeUIContext(containerViewGroup)
val plugin = flutterEngine.plugins.get(AerisUnifiedBridgePlugin::class.java)
    as? AerisUnifiedBridgePlugin
    ?: error("请先在当前FlutterEngine注册Aeris插件")
plugin.bind(
    engine = aeris,
    uiContext = uiContext,
    allowedPermissions = setOf("camera"),
    allowedEventTopics = setOf("network.changed", "appearance.changed"),
)
// 容器最终关闭时，在主线程调用：
plugin.close()
uiContext.invalidate()
flutterEngine.destroy()
```

同一个 Aeris Engine 可以服务多个 FlutterEngine；每个 FlutterEngine 单独获取、绑定并持有插件和 UIContext。`bind` 只能调用一次，权限及事件白名单是该连接自己的快照。插件只绑定一次；整体容器替换时重新创建 FlutterEngine/插件绑定（或在 Dart 关闭旧客户端后显式移除并重新注册插件），再创建新 UIContext；原 View 脱离窗口会使旧 UIContext 永久失效。也可使用 `AerisBridgeReceiverFactory` / `bindReceiver` 注入自定义宿主接收器，工厂必须固定为 `.FLUTTER` 来源。

Android 与 Dart 同样使用 `BasicMessageChannel<String?>`、`StringCodec` 和固定通道 `aeris_bridge`。框架 reply 恒为 `null`，业务响应独立发送；宿主绑定前只允许缓冲一条初始 `bridge.hello`，第二条或业务请求会关闭绑定。Engine detach、物理发送故障和显式关闭会释放处理器并阻止迟到发送。逻辑连接故障只清理旧Connection，物理通道有效时允许Dart新建Client并用全新前缀hello恢复，不自动恢复旧请求/订阅。后台 isolate 不创建第二个 Aeris 连接。

`network.changed` 保持 iOS 的 `status/connected/interface/expensive/constrained` 字段：Android 已验证联网为 `satisfied`，存在待验证网络为 `requiresConnection`，无网络为 `unsatisfied`；`expensive` 对应计费网络，`constrained` 对应计费网络上的后台流量限制。`appearance.changed` 的 `style` 为 `light/dark/unspecified`，读取原容器的 Resources 配置；它要求暴露原始 View 的 `AndroidContainerBridgeUIContext`（默认实现 `AndroidBridgeUIContext`），不会改用全局 Application 外观。两者均通过现有 EventHub、统一事件协议和出站预算发送。

仓库原生独立编译可传 `-PaerisFlutterSdk=/path/to/flutter` 或设置 `FLUTTER_ROOT`，仅引用该 SDK 已缓存的 Android embedding JAR（依次检查 `android-arm64`、`android-x64`、`android`）。也可显式传 `-PaerisFlutterEmbeddingJar=/absolute/flutter-embedding.jar` 注入固定版本的真实官方 Maven JAR；该文件必须存在且非空，并且仅参与 `compileOnly`，不会打进插件 AAR。显式 JAR 参数优先于 SDK 缓存。正常 Flutter App 构建由 Flutter 工具提供 embedding，无需在本插件安装 SDK。包含 Java 编译步骤的独立 AGP 验收需使用完整 JDK 17（必须包含 `jlink`；仅有 `javac` 的裁剪 JBR 不足）。运行纯 JVM 回归（包括真实 Core、Flutter 绑定和 Web origin 策略）使用：

```sh
JAVA_HOME=/path/to/jdk17 native/android/gradlew -p native/android/protocol-tests test --no-daemon
```

### Android 本轮通信对齐（2026-10-31）


完整App已位于 `examples/flutter-android-host`：原生宿主嵌入Flutter模块，真实Flutter3.47.8/Dart3.13.7的9项API35 ARM64设备验收通过，覆盖调用/过程回调、事件与退订、取消、逻辑恢复、实际插件detach重绑、双Engine隔离及活动任务/订阅下Engine.destroy。Debug/测试APK/Release编译和缺失Native绑定的真实Dart超时负向检查也已通过。


### Android 前轮验证状态（2026-10-31）

最终本机实际 AGP 构建已通过 Core、RN、Web、Flutter、Unity 五模块的 Debug/Release AAR，以及 56 项单元测试（其中 Flutter 6/6，全部零失败/跳过）。Flutter 编译使用真实官方 Flutter 3.41.0 embedding JAR；Release AAR 的真实 `classes.jar` 已确认不含 `io.flutter` 引擎类。日志和汇总位于仓库根目录下的 `artifacts/android-agp-verification/`：`final-full-build.log`、`unit-results.json`、`release-aar-audit.json`；另有 `packages/flutter/android/build/test-results/testDebugUnitTest/TEST-*.xml`。

Core 的网络与容器外观 Provider 已在 API 35 ARM64 AVD 上通过 3/3 设备测试。源码为 `native/android/aeris/src/androidTest/java/com/aeris/sdk/AndroidSystemEventProviderTest.kt`，结果为 `native/android/aeris/build/outputs/androidTest-results/connected/debug/TEST-*.xml` 和 `artifacts/android-agp-verification/provider-device.log`。这三项验证 Provider 的容器隔离与监听清理，不覆盖 FlutterEngine 的实际 Android 收发或 attach/detach；真实 FlutterEngine、WebView 和 UnityPlayer 的设备验收仍未运行。


### Android 候选 Maven 依赖

插件先使用宿主的 `project(":aeris")`，没有该项目时回退固定坐标 `com.aeris.sdk:aeris:0.26.0-preview.1`。这些是候选坐标，并不表示已经发布到 Maven Central，也不声明公有 namespace 所有权；宿主必须显式配置本地 staging 或自己的制品仓库。使用候选 AAR 时，不添加上面的 `include(":aeris")`，而是在宿主 `settings.gradle.kts` 的 `dependencyResolutionManagement.repositories` 中加入已审计的仓库：

```kotlin
maven { url = uri("/path/to/aeris-maven-staging") }
```

源码维护者可在仓库 checkout 中使用可选 `maven-publish` 任务准备候选 `aeris`、`aeris-web`、`aeris-flutter` 和 Unity 制品。`-PaerisMavenStagingDir=/absolute/local/path` 只设置文件系统 staging 位置，不配置任何公网上传仓库。版本保持 `0.26.0-preview.1`；不要覆盖已有远程 tag 或已发布包。独立 Flutter 插件归档不依赖仓库里的发布 convention 文件。
