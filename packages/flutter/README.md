# aeris_flutter

Aeris 的 Dart Client 与 iOS/Android Flutter 插件。插件版本 `0.26.0-preview.2` 配套 Aeris Native `0.26.0-preview.1`，使用 `aeris_bridge` 通道。插件自动注册后，宿主还须为每个 FlutterEngine 绑定独立连接。

这是预览版本。真机、最低系统真机、签名正式安装以及具体商业登录、支付、定位硬件插件仍待验收；请按自己的业务能力与插件组合测试。

## 环境与安装

Dart `>=3.6.0 <4.0.0`、Flutter `>=3.41.0`；iOS 15.0+；Android minSdk 24、compileSdk 37、Java 17。本预览 iOS 使用 CocoaPods，Android 使用支持本插件 Kotlin 源码的 AGP 配置。

```yaml
dependencies:
  flutter:
    sdk: flutter
  aeris_flutter: 0.26.0-preview.2
```

```sh
flutter pub get
```

该声明从 [pub.dev](https://pub.dev/packages/aeris_flutter) 解析插件；不要额外添加 Git、path 或 dependency overrides。应用提交 `pubspec.lock`，宿主同时锁定下面的 Native 版本。

## 公共原生依赖

iOS 在应用 Podfile 顶部增加公开 Specs 和系统 CDN，保留 Flutter 模板的 podhelper、插件安装和 post_install：

```ruby
source 'https://github.com/zhangguozhong/leo-podspecs.git'
source 'https://cdn.cocoapods.org/'
platform :ios, '15.0'
```

插件由 Flutter 自动安装，依赖的 `AerisContracts` 固定为 `0.26.0-preview.1`。需要下面的直接 Native 绑定时，在实际应用 target 内添加：

```ruby
pod 'Aeris/UIKitContext', '= 0.26.0-preview.1'
pod 'Aeris/Transports', '= 0.26.0-preview.1'
```

本预览未提供 SwiftPM 描述；较新 Flutter 应用可按[官方项目级配置](https://docs.flutter.dev/packages-and-plugins/swift-package-manager/for-app-developers)在应用 pubspec 中使用 CocoaPods：

```yaml
flutter:
  config:
    enable-swift-package-manager: false
```

运行 `pod install`，使用生成的 `.xcworkspace`。不要为 `aeris_flutter` 或 Aeris Native 再指定本地 Pod 或另一份 Git 来源。

Android 在当前宿主的依赖仓库配置中加入固定公共 Maven 地址；根据工程已有仓库策略，放入 `dependencyResolutionManagement.repositories` 或既有 `allprojects.repositories`，保持单一有效配置：

```kotlin
maven {
    url = uri("https://raw.githubusercontent.com/zhangguozhong/aeris-maven/0.26.0-preview.1")
    content { includeGroup("com.aeris.sdk") }
}
```

插件会解析 `com.aeris.sdk:aeris:0.26.0-preview.1`。保留 `google()` 和 `mavenCentral()`；无需添加本地 `:aeris` 项目，也无需全局修改 Gradle 仓库。

## 流程一：标准 Flutter App

创建平台工程，添加上述依赖和平台配置：

```sh
flutter create --empty --platforms ios,android aeris_app
cd aeris_app
flutter pub get
```

在 Dart 主 isolate 中创建并持有一个客户端；宿主绑定完成后 `ready()` 才会成功：

```dart
import 'package:aeris_flutter/aeris_flutter.dart';
import 'package:flutter/widgets.dart';

Future<BridgeClient> connect() async {
  WidgetsFlutterBinding.ensureInitialized();
  final client = BridgeClient(FlutterAdapter());
  try {
    await client.ready();
    return client;
  } catch (_) {
    await client.dispose();
    rethrow;
  }
}
```

将客户端保存在应用或容器状态中，退出时 `await client.dispose()`。业务调用的方法、权限和事件必须由 Native 宿主实际注册；空 Engine 的握手成功不代表存在拍照、支付等业务能力。

iOS 保留 Flutter 模板的 `GeneratedPluginRegistrant` 注册。在拥有实际 `FlutterViewController` 的主线程入口执行以下绑定；宿主长期持有返回值，并为每个 Engine 各调用一次：

```swift
import Aeris
import AerisContracts
import Flutter
import UIKit
import aeris_flutter

@MainActor
func bindAeris(to controller: FlutterViewController)
  throws -> (any AerisFlutterModuleBinding, AerisBridgeReceiverFactory) {
  let engine = controller.engine
  guard let plugin = engine.valuePublished(byPlugin: AerisFlutterBridgePluginKey)
    as? any AerisFlutterModuleBinding else {
    throw NSError(domain: "AerisFlutter", code: 1,
      userInfo: [NSLocalizedDescriptionKey: "请先注册当前 Engine 的插件"])
  }
  let factory = try AerisBridgeReceiverFactory(
    engine: BridgeEngine.shared, source: .flutter,
    allowedPermissions: [], allowedEventTopics: [])
  factory.bindUIContext(BridgeUIContext(containerViewController: controller))
  let receiver = factory.makeReceiver { [weak plugin] text in
    plugin?.emitMessage(toDart: text)
  }
  plugin.bindReceiver(receiver)
  return (plugin, factory)
}
```

关闭时调用所持有插件的 `close()`，使上下文失效，并按宿主的资源协议等待业务任务真正结束，再销毁 Engine。`close()` 的返回不代表业务异步任务已完成；需要受管路由、可恢复清理及 Engine 所有权管理时，使用 [FlutterHull](https://pub.dev/packages/flutter_hull) 的 Coordinator。

Android 保留 `FlutterActivity` 的插件注册，在 `configureFlutterEngine` 中取当前 Engine 的插件：

```kotlin
import android.view.ViewGroup
import com.aeris.sdk.AndroidBridgeUIContext
import com.aeris.sdk.BridgeEngine
import com.aeris.sdk.flutter.AerisUnifiedBridgePlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private val bridge = BridgeEngine()
    private var plugin: AerisUnifiedBridgePlugin? = null
    private var aerisContext: AndroidBridgeUIContext? = null

    override fun configureFlutterEngine(engine: FlutterEngine) {
        super.configureFlutterEngine(engine)
        val root = window.decorView.findViewById<ViewGroup>(android.R.id.content)
        val current = checkNotNull(engine.plugins.get(AerisUnifiedBridgePlugin::class.java))
        val ui = AndroidBridgeUIContext(root)
        current.bind(bridge, ui, allowedPermissions = emptySet(),
            allowedEventTopics = emptySet())
        plugin = current
        aerisContext = ui
    }

    override fun cleanUpFlutterEngine(engine: FlutterEngine) {
        plugin?.close()
        aerisContext?.invalidate()
        plugin = null
        aerisContext = null
        super.cleanUpFlutterEngine(engine)
    }
}
```

此片段使用新建、由当前 Activity 持有的默认 Engine。缓存或共享 Engine 的解绑、异步资源屏障及重建策略须由宿主单独管理。iOS 和 Android 都必须先注册业务模块/事件，再建立连接；每个容器自己的权限和事件白名单应尽量收窄。

## 流程二：嵌入已有 Native App

先用 `flutter create --template module aeris_feature` 创建 Flutter 模块，并添加相同 hosted 依赖。按 [iOS CocoaPods 集成指南](https://docs.flutter.dev/add-to-app/ios/project-setup-legacy#use-cocoapods-and-the-flutter-sdk)或 [Android add-to-app 指南](https://docs.flutter.dev/add-to-app/android/project-setup)将模块接入宿主，再合并上述公共 Specs/Maven 配置。

宿主创建实际 FlutterEngine、安装生成的插件注册器、挂载 FlutterViewController/FlutterView，然后为该 Engine 执行上面的 Native 绑定。iOS 使用实际承载 Flutter 的 controller；Android 的 `bind` 接收实际容器的 `AndroidBridgeUIContext`。运行 Dart 前应准备好绑定，启动期间到达的握手也需要及时完成宿主配置。

宿主仍负责 Flutter 插件要求的 Activity/Scene、权限、Activity result、深链和内存回调。通过官方 Runner 或官方生命周期分发器转发，避免重复分发；权限白名单不替代操作系统权限申请。

## 连接与升级

同一 Engine 主 isolate 只持有一个连接所有者；后台 isolate 不建立第二条连接。多个 Engine 可以复用宿主 BridgeEngine，但应分别获取各自插件、上下文和连接。

升级时同步更新 Dart 插件、其中原生插件及配套 Native 版本，并重新执行 `flutter pub get` 和 `pod install`。保留应用已验证的锁文件与平台配置用于回滚，回退整个配对版本；不要覆盖已存在的发布版本或 tag。旧导入 `unified_bridge.dart` 保留兼容入口，业务使用 `aeris_flutter.dart`。
