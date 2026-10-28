# Aeris

Aeris 为 iOS 宿主中的 Web、React Native、Flutter 和 Unity 模块提供统一桥接协议、原生能力注册、callback、持续回调及事件订阅。

**0.25.0 Core/RN 预览版已发布**：npm aeris-client-core@0.25.0、aeris-react-native@0.25.0；原生 Specs 位于 [leo-podspecs](https://github.com/zhangguozhong/leo-podspecs)，源码 tag 为 0.25.0。当前验证以 iOS 为主，未声明 Android 实现已经完成。aeris.json 的全套 published=false 表示其他平台 registry 尚未全部发布，已发布范围见 publication。

## React Native 与原生接入

发布后安装精确版本：

```sh
npm install --save-exact aeris-client-core@0.25.0 aeris-react-native@0.25.0
```

RN 插件随 npm 包提供 iOS 源码和 Codegen。原生宿主加载 RN 官方 CocoaPods 脚本后，在实际 App target 合并：

```ruby
aeris_source = { :git => 'https://github.com/zhangguozhong/aeris-sdk.git', :tag => '0.25.0' }
pod 'AerisContracts', **aeris_source
pod 'Aeris', **aeris_source
pod 'AerisHost', **aeris_source
# 保留 RN 工程自己的 use_native_modules! / use_react_native! / post_install。
# AerisRN 由 node_modules 自动链接，无须重复声明另一来源的同名 Pod。
```

根目录 JSON Podspec 适用于 Git/Specs 安装；native/ios 下的 Podspec 适用于相应源码目录的 :path 安装。

```ts
import { bridge } from 'aeris-react-native';

await bridge.ready();
bridge.call('takePhoto', { quality: 80 }, (error, result) => {
  // 宿主需注册该能力并授予权限；业务处理 error 或 result。
});
```

原生使用共享 BridgeEngine 注册业务 Bridge。每个容器拥有独立 Connection、UIContext、权限和清理生命周期。不要在共享 Bridge 实例属性中保存当前请求的参数或 callback。Native 主动事件通过 Engine.publish 发布。

URN 用户由 URN 容器持有各页面连接，不应再使用上述全局 bridge 为同一页面重复创建连接。

## 其他平台与构建

Web、Flutter、Unity 的客户端和 iOS 插件源码分别位于 packages/web、packages/flutter、packages/unity。当前发布步骤仅处理 Core、RN npm 以及 iOS 原生源码；其他平台 registry 尚未发布。

维护者在 tooling 目录安装锁定的构建工具，再执行 `python3 tooling/client-build.py`。iOS App 使用 CocoaPods 接入，不依赖本仓库的测试工具。

## 许可

MIT。此公开源码仓库仅保留发布源码与使用说明，不包含内部设计文档、测试日志和私有开发仓库历史。

首轮 npm 发布同时生成 next 与 latest，建议按上文精确版本安装。公开 Specs 不依赖 Trunk 账号。
