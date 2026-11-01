# Aeris Web Adapter

版本`0.26.0-preview.1`，共用同版本aeris-client-core。ESM与声明位于dist，源码位于src。

可从本次GitHub Release附件安装aeris-web-0.26.0-preview.1.tgz；不声明已发布同名npm版本。宿主需要先安装Native入口，普通浏览器没有原生Bridge时会拒绝握手。

iOS使用WKWebView；Android需要支持WEB_MESSAGE_LISTENER、DOCUMENT_START_SCRIPT的现代WebView，限制可信HTTPS主文档。每次文档导航/Reload创建新端点并退役旧连接。

[宿主接入](https://github.com/zhangguozhong/aeris-sdk/tree/0.26.0-preview.1/README.md)。MIT。
