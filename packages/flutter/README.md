# aeris_flutter

Flutter 插件包含 Dart Client Core、Adapter 和薄 iOS 原生插件。当前包版本 `0.25.0`；要求 Dart `>=3.6.0 <4.0.0`、Flutter `>=3.41.0`。当前声明的平台为 iOS。

## 1. 通过私有 Git 安装

在实际 Flutter App 或嵌入式模块的 `pubspec.yaml` 中添加：

```yaml
dependencies:
  flutter:
    sdk: flutter
  aeris_flutter:
    git:
      url: https://github.com/zhangguozhong/Aeris.git
      ref: '0.25.0'
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
  :tag => '0.25.0'
}

pod 'AerisContracts', **aeris_source, :modular_headers => true
pod 'Aeris/Core', **aeris_source
pod 'AerisHost/Flutter', **aeris_source
```

`aeris_flutter` 原生 Pod 由 Flutter podhelper 安装，不重复声明 Git 来源。执行宿主的 `pod install` 后，App 启动 FlutterEngine、注册插件，再创建并持有该容器独立的 `FlutterHost`，由 Host 将 Transport 注入注册表中的插件实例，然后 Dart 才调用 `ready()`。关闭时调用 `host.close()`，再释放对应 FlutterEngine；模块能运行不代表桥接已经完成绑定。


当前源码的物理通道统一为 `aeris_bridge`，Dart Adapter 与 iOS 插件必须成对升级；默认 pluginClass 和 registry key 为 `AerisUnifiedBridgePlugin`。Installer 优先查新 key，只在未找到时回退 `UBUnifiedBridgePlugin`。每个 Engine 只注册一套入口，不能同时注册新旧插件。

## 3. 分发和验证

Flutter 目前可直接使用上面的 Git 依赖，无需另建 Dart 仓库。`ref` 与宿主 Pod 均固定为 `0.25.0` tag；后续升级时同步更新。Pod 说明见[根 README](../../README.md#私有-git-pod-接入)。离线交付可解压 `artifacts/flutter/aeris_flutter-0.25.0.tar.gz`，再用 `path` 引用解压后的插件根目录；该归档由维护者生成，不随 Git 自动下载。


## Flutter 框架回归

在仓库的 `tests/flutter-framework` 中执行 `flutter pub get` 和 `flutter test`，验证真实 `BasicMessageChannel` 的类型约束及空确认行为。可空通道类型用于框架确认，业务消息仍必须是非空字符串；不会修改 Aeris 协议。

远程 `0.25.0` tag 尚未包含此次可空通道修复，在 Flutter 3.47.8 实际构建时会出现 `Future<String>` 不能返回 `null` 的编译错误。使用修复后的源码验证，待后续版本发布后再切换正式 tag，不覆盖已有 tag。

## 通道名称升级

当前源码使用 `aeris_bridge`，旧 tag 的通道为 `unified_bridge`。升级时同时更新 Dart 包和其中的 iOS 插件，并重新执行宿主的 `pod install`；仅更新一端会导致握手失败。新旧插件常量符号都指向当前通道，旧 registry key 与 `unified_bridge.dart` 导入兼容入口继续保留。该改名不增加新的 JSON 字段，也不覆盖已有 tag。
