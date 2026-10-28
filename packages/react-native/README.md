# aeris-react-native

RN 插件包含 JS 入口、RN Adapter、Codegen 规范和薄 iOS 原生模块；通用 JS 逻辑由独立的 `aeris-client-core` 提供。当前包版本 `0.25.0`，peer 依赖为 React Native `0.87.x`、React `^19.2.3`。其他 RN 版本需要单独验证。

## 1. 安装 JS 和插件包

使用 npm 精确安装 `aeris-client-core@0.25.0` 与 `aeris-react-native@0.25.0`。发布前验收或离线接入也可使用同版本的两个 tarball，例如：

```text
RNFeature/
├── package.json
└── vendor/aeris/
    ├── aeris-client-core-0.25.0.tgz
    └── aeris-react-native-0.25.0.tgz
```

在 RN 项目根目录执行一次安装：

```sh
npm install --save-exact ./vendor/aeris/aeris-client-core-0.25.0.tgz ./vendor/aeris/aeris-react-native-0.25.0.tgz
```

同时安装两个包，使 `aeris-react-native` 的精确 Core 依赖在本地得到满足；只安装 RN tarball 会尝试从 registry 寻找 Core。提交 `package.json`、lockfile 和所引用的两个 tarball，保证其他开发机与 CI 能找到同一份文件。

安装后使用：

```ts
import { bridge } from 'aeris-react-native';

async function startBridge() {
  await bridge.ready();
  bridge.call('takePhoto', { quality: 80 }, (error, result) => {
    // 宿主需注册拍照方法并授予权限；业务在这里处理结果。
  });
}

// 从模块初始化流程调用 startBridge() 并处理初始化错误。
// RN 容器最终销毁时 await bridge.dispose()，普通页面离开时不销毁共享实例。
```

`bridge` 与 `createBridge()` 二选一；同一个原生连接只创建一个 Core 所有者。JS 由 Metro 打包，Pod 不负责安装 JS。npm 支持本地 tarball 安装，详见 [npm 官方说明](https://docs.npmjs.com/cli/v11/commands/npm-install/)。

## 2. iOS 宿主安装 Pod 并注入

先完成 npm 安装，再将以下依赖合并进现有 RN 宿主 Podfile：

```ruby
aeris_source = {
  :git => 'https://github.com/zhangguozhong/aeris-sdk.git',
  :tag => '0.25.0'
}

# 放入实际 App target 内；保留 RN 原来的 use_native_modules!、
# use_react_native!、最低 iOS 版本、静态 framework 和 post_install 配置。
pod 'AerisContracts', **aeris_source, :modular_headers => true
pod 'Aeris/Core', **aeris_source
pod 'AerisHost/ReactNative', **aeris_source
```

执行宿主的 `pod install`。`AerisRN` 由 `aeris-react-native/AerisRN.podspec` 自动链接安装，不要重复声明 Git Pod 来源。RN 功能模块位于独立目录时，autolinking 和 `use_react_native!` 必须指向该模块的 npm 依赖图；不能仅在另一个目录安装插件后就期望宿主自动发现。

原生初始化与注入仍然必须执行：App 初始化并注册 `BridgeEngine.shared` 的业务能力 → 按容器创建 `ReactNativeHost` → App 的 RNFactoryDelegate 返回 `host.makeModule()` → RN 创建模块并完成 Transport 绑定 → JS 执行 `ready()`。App 持有各容器独立的 Host，关闭时调用 `host.close()`，再销毁对应 RN 容器。


## 3. 本地开发与维护者分发

联调时可以在 RN 项目中同时使用两份源码目录：

```sh
npm install /path/to/Aeris/packages/client-core /path/to/Aeris/packages/react-native
```


RN 和 Core 位于同一仓库的不同子目录，不能将 Unity 的 `?path=/packages/unity` 语法用于 `npm install`。未来如接入私有 npm registry，需要同时发布 Core 和 RN 两个版本；当前无需改变包结构或复制 Core。

维护者打包命令和 `0.25.0` tag 接入方式见[根 README](../../README.md#四端客户端接入)。固定 TurboModule 名仍为 `NativeUnifiedBridge`、原生模块为 `RCTUnifiedBridge`，Codegen 名为 `NativeUnifiedBridgeSpec`，协议及 callback 生命周期保持不变。
