# Aeris Client Core

统一协议、callback、连续过程回调、超时、取消、事件订阅和关闭清理。版本`0.26.0-preview.2`。

```sh
npm install --save-exact aeris-client-core@0.26.0-preview.2
```

使用`ClientCore`并注入对应平台Adapter；RN/Web共用此包，不重复复制Core。`call`发起请求，Native通过emit发送过程数据，complete/callback结束；订阅通过统一系统方法完成。通道关闭后旧callback和订阅不能复活。

[四端宿主接入](https://github.com/zhangguozhong/aeris-sdk/tree/0.26.0-preview.2/README.md)。MIT。
