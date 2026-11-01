# Aeris Android 源码入口

Android聚合Gradle工程统一编译通用Core和平台原生插件。RN/Flutter插件的源码随各自平台包分发，因此通过settings.gradle.kts映射目录，避免维护第二份实现。

| Gradle模块 | 实际目录 | 用途 |
| --- | --- | --- |
| :aeris | aeris/ | Engine、Session、Connection、事件、预算、四种Transport和宿主绑定契约 |
| :aeris-react-native | ../../packages/react-native/android/ | RN NativeModule与绑定 |
| :aeris-flutter | ../../packages/flutter/android/ | FlutterPlugin、BasicMessageChannel与独立Engine绑定 |
| :aeris-web | aeris-web/ | 可信WebView文档通道 |
| :aeris-unity | aeris-unity/ | Unity宿主组合与绑定 |
| :aeris-unity-channel | aeris-unity/channel/ | Unity侧Java通道编译契约；宿主只compileOnly，最终由UnityLibrary提供 |

Flutter的Dart Client/Adapter位于packages/flutter/lib，pubspec.yaml声明Android插件。正常Flutter工程由Flutter工具完成插件依赖和embedding接线；宿主仍需注入Aeris Engine与该容器UIContext。不是将六个模块全部引入每个App。

接入和完整回传时序见[Android说明](../../docs/AerisAndroid接入.md)，Flutter宿主示例见[Flutter包README](../../packages/flutter/README.md)。Flutter绑定7项和真实API编译通过；完整原生App位于examples/flutter-android-host，真实FlutterEngine的9项设备验收已通过，详见[Flutter Android接入](../../docs/FlutterAndroid接入与验收.md)。JVM/编译与实际Engine设备结果分开记录。
