# Aeris React Native

版本`0.26.0-preview.2`，RN0.87 / React19.2.3，自动依赖同版本aeris-client-core。

```sh
npm install --save-exact aeris-react-native@0.26.0-preview.2
```

RN CLI自动链接iOS AerisRN Pod和Android Package。iOS使用公开leo-podspecs解析AerisContracts/Aeris/AerisHost；不要重复声明另一来源的AerisRN。Android需配置Aeris Maven仓库并在根Gradle注入实际node_modules路径`ext.aerisNodeModulesDir = file("../node_modules").absolutePath`；URN脚手架已注入。插件根据TS Spec执行真实Codegen，不需要手写生成类。

宿主给每个容器绑定Receiver/Transport和UIContext，注入同一个Engine；Native主动事件沿同一通道回传。绑定和清理接口见ios/及android/src/main；JS入口导出RNAdapter。

[完整原生依赖与接入说明](https://github.com/zhangguozhong/aeris-sdk/tree/0.26.0-preview.2/README.md)。MIT。
