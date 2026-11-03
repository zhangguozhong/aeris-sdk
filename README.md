# Aeris

Aeris 是面向 iOS 和 Android 的统一跨平台通信 SDK，连接 Web、React Native、Flutter 和 Unity。支持原生调用、持续回调、事件订阅、取消与按容器隔离的连接。

原生 SDK、JavaScript Core、RN 和 Web 使用 `0.26.0-preview.2`；Unity UPM 包和 Flutter 插件使用 `0.26.0-preview.3`，配套同一原生 SDK。

## iOS

```ruby
source 'https://github.com/zhangguozhong/leo-podspecs.git'
source 'https://cdn.cocoapods.org/'

pod 'AerisContracts', '= 0.26.0-preview.2'
pod 'Aeris/Core', '= 0.26.0-preview.2'
# 按需选用：AerisHost/Web、AerisHost/Unity、AerisHost/ReactNative、AerisHost/Flutter。
```

RN/Flutter原生插件由平台工具自动链接，不要重复声明另一来源的同名Pod。纯Native Core最低iOS15.0，RN0.87宿主最低iOS15.1。

## React Native

```sh
npm install --save-exact aeris-react-native@0.26.0-preview.2
```

自动安装匹配的 `aeris-client-core`。使用RN0.87/React19.2.3及RN官方Podfile/Gradle配置；插件由autolinking注册，宿主注入共享Engine及每容器上下文。iOS原生依赖从上面的公开Specs解析。

Android根工程需要为插件提供宿主的实际node_modules路径（URN脚手架已自动注入）：

```groovy
// 根build.gradle；monorepo按实际提升后的依赖目录调整。
ext.aerisNodeModulesDir = file("../node_modules").absolutePath
```


## Android原生依赖

SDK包名 `com.aeris.sdk`，minSdk24，Java17。宿主根据实际Gradle策略将下列仓库合并到dependencyResolutionManagement或allprojects.repositories：

```kotlin
maven { url = uri("https://raw.githubusercontent.com/zhangguozhong/aeris-maven/0.26.0-preview.2") }
```

```kotlin
implementation("com.aeris.sdk:aeris:0.26.0-preview.2")
// 按需：aeris-react-native、aeris-web、aeris-flutter、aeris-unity。
```

RN/Unity 从源码集成时，可复用宿主已有的唯一 `:aeris` 模块；Flutter 托管插件使用上述 Maven 依赖。Unity 通道实现由 UnityLibrary 提供，宿主不要重复打包 `aeris-unity-channel`。

## Flutter

```yaml
dependencies:
  aeris_flutter: 0.26.0-preview.3
```

Flutter 插件通过 pub.dev 分发，配套 Aeris Native `0.26.0-preview.2`。宿主为每个 Engine 绑定独立连接；退出时先关闭连接并等待真实资源清理，再 destroy/detach。

完整平台仓库配置、原生绑定和接入步骤见 [Flutter 插件使用说明](packages/flutter/README.md)。Flutter 专用源码 tag 为 `flutter-0.26.0-preview.3`；其他平台源码 tag 为 `0.26.0-preview.2`。

## Unity

在UPM中添加Git URL：

```text
https://github.com/zhangguozhong/aeris-sdk.git?path=/packages/unity#unity-0.26.0-preview.3
```

Unity2022.3+。iOS通用通道随UnityFramework编译，App通过AerisHost/Unity及宿主注入接口接线；Android由Java/JNI通道连接宿主Driver。暂停时C#业务回调等待PlayerLoop恢复，Native仍按有界队列处理和清理。卸载前关闭所有Driver并等待Native清理。

Unity 包已包含 C#、双端通道和导出处理器。完整安装、宿主绑定、取消及卸载顺序见 [Unity 插件接入说明](packages/unity/README.md)。

## Web

Web Adapter源码与ESM位于`packages/web`。可使用 [Web 安装包](https://github.com/zhangguozhong/aeris-sdk/releases/download/0.26.0-preview.2/aeris-web-0.26.0-preview.2.tgz)，其Core依赖为同版本npm包。Android WebView要求现代组件支持WEB_MESSAGE_LISTENER和DOCUMENT_START_SCRIPT，限定可信HTTPS主文档。iOS使用WKWebView和AerisHost/Web。

## Native业务

App持有共享`BridgeEngine`，动态注册业务Bridge对象和事件topic；每个容器独立Factory、Connection、UIContext，每次调用独立Session。普通结果用callback，过程数据用emit，终态用complete；业务任务需实现取消和实际资源清理。Native事件统一Engine.publish，Provider可选。

Android诊断通过`engine.diagnostics.snapshot()`获取脱敏计数、队列/连接/请求指标和耗时；`session.operationTrace`跟踪实际清理。Observer不可记录业务载荷或阻塞上传。

## 版本兼容

RN 插件使用 React Native `0.87.0`、React `19.2.3`，iOS 最低 `15.1`；独立原生 SDK 最低 iOS `15.0`、Android API `24`。各平台按上文固定版本接入，升级时同步检查对应原生依赖和应用锁文件。

当前为预览版本，请按应用的目标设备和插件组合验证集成。

## 许可证

[MIT](LICENSE)。
