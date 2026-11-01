# Aeris

统一 RN、Flutter、Web 和 Unity 与原生宿主的桥接协议。当前预览版 `0.26.0-preview.1`，支持 iOS 与 Android；协议和四端公开调用行为保持不变。

## iOS

```ruby
source 'https://github.com/zhangguozhong/leo-podspecs.git'
source 'https://cdn.cocoapods.org/'

pod 'AerisContracts', '= 0.26.0-preview.1'
pod 'Aeris/Core', '= 0.26.0-preview.1'
# 按需选用：AerisHost/Web、AerisHost/Unity、AerisHost/ReactNative、AerisHost/Flutter。
```

RN/Flutter原生插件由平台工具自动链接，不要重复声明另一来源的同名Pod。纯Native Core最低iOS15.0，RN0.87宿主最低iOS15.1。

## React Native

```sh
npm install --save-exact aeris-react-native@0.26.0-preview.1
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
maven { url = uri("https://raw.githubusercontent.com/zhangguozhong/aeris-maven/0.26.0-preview.1") }
```

```kotlin
implementation("com.aeris.sdk:aeris:0.26.0-preview.1")
// 按需：aeris-react-native、aeris-web、aeris-flutter、aeris-unity。
```

已有唯一`:aeris`源码项目时，RN/Flutter/Unity模块复用它，不额外加载另一份Core。否则从上述固定Maven来源解析。Unity通道实现只由UnityLibrary提供，宿主不能重复runtime打包`aeris-unity-channel`。

## Flutter

```yaml
dependencies:
  aeris_flutter:
    git:
      url: https://github.com/zhangguozhong/aeris-sdk.git
      ref: 0.26.0-preview.1
      path: packages/flutter
```

Flutter工具注册iOS/Android插件；宿主从对应Engine取插件并绑定Aeris Engine，最终退出时先关闭连接，再destroy/detach。此版本通过Git分发，未发布pub.dev。

## Unity

在UPM中添加Git URL：

```text
https://github.com/zhangguozhong/aeris-sdk.git?path=/packages/unity#0.26.0-preview.1
```

Unity2022.3+。iOS通用通道随UnityFramework编译，App通过AerisHost/Unity及宿主注入接口接线；Android由Java/JNI通道连接宿主Driver。暂停时C#业务回调等待PlayerLoop恢复，Native仍按有界队列处理和清理。卸载前关闭所有Driver并等待Native清理。

## Web

Web Adapter源码与ESM位于`packages/web`。可使用本次GitHub预览Release附件 `aeris-web-0.26.0-preview.1.tgz`，其Core依赖为同版本npm包。Android WebView要求现代组件支持WEB_MESSAGE_LISTENER和DOCUMENT_START_SCRIPT，限定可信HTTPS主文档。iOS使用WKWebView和AerisHost/Web。

## Native业务

App持有共享`BridgeEngine`，动态注册业务Bridge对象和事件topic；每个容器独立Factory、Connection、UIContext，每次调用独立Session。普通结果用callback，过程数据用emit，终态用complete；业务任务需实现取消和实际资源清理。Native事件统一Engine.publish，Provider可选。

Android诊断通过`engine.diagnostics.snapshot()`获取脱敏计数、队列/连接/请求指标和耗时；`session.operationTrace`跟踪实际清理。Observer不可记录业务载荷或阻塞上传。

## 预览范围

本轮模拟器覆盖API24与API35 ARM64 16KiB的RN/Flutter/Unity，Web覆盖现代WebView。当前Swift回归与此前iOS平台验证保留。真机、API24旧WebView、OS长期后台/强制杀进程和生产签名Release尚未完成本轮验收；不宣称稳定版或所有设备均已验证。`latest`保持原版本，预览使用精确版本或npm `next`。

MIT。仅发布SDK源码、制品和使用说明，不包含私有设计文档或业务项目SDK。
