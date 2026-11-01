# Aeris Flutter

Dart Client Core、Flutter Adapter及iOS/Android原生插件，版本`0.26.0-preview.1`。

```yaml
dependencies:
  aeris_flutter:
    git:
      url: https://github.com/zhangguozhong/aeris-sdk.git
      ref: 0.26.0-preview.1
      path: packages/flutter
```

Flutter工具完成插件注册；原生App从对应FlutterEngine取AerisUnifiedBridgePlugin并注入Engine、容器上下文和权限。先关闭连接并等待业务清理，再detach/destroy Engine。iOS基础Pod使用公开Specs；Android无源码Core时使用同版本Aeris Maven。

此版本由固定Git tag分发，未发布pub.dev。SDK不携带项目业务对象或Framework。

[完整接入](https://github.com/zhangguozhong/aeris-sdk/tree/0.26.0-preview.1/README.md)。MIT。
