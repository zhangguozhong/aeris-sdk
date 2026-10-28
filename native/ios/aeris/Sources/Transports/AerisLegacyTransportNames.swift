// 兼容别名只随 Transports 安装，Core 无需依赖可选的容器接入层。
@available(*, deprecated, renamed: "AerisNativeTransport") public typealias UBNativeTransport =
    AerisNativeTransport

@available(*, deprecated, renamed: "AerisBridgeReceiverFactory") public typealias
    UBBridgeReceiverFactory = AerisBridgeReceiverFactory

@available(*, deprecated, renamed: "AerisRNNativeTransport") public typealias UBRNNativeTransport =
    AerisRNNativeTransport

@available(*, deprecated, renamed: "AerisFlutterNativeTransport") public typealias
    UBFlutterNativeTransport = AerisFlutterNativeTransport

@available(*, deprecated, renamed: "AerisWebNativeTransport") public typealias
    UBWebNativeTransport = AerisWebNativeTransport

@available(*, deprecated, renamed: "AerisUnityNativeTransport") public typealias
    UBUnityNativeTransport = AerisUnityNativeTransport
