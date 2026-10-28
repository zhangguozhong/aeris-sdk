import AerisContracts

#if SWIFT_PACKAGE
    import AerisInvocation
#endif

// 旧 Swift 源码通过 import Aeris 使用过渡别名；新代码统一使用 Aeris 名称。
// 不为旧运行时反射字符串或已编译二进制提供兼容，Contracts 仍保持纯 Objective-C 协议库。
@available(*, deprecated, renamed: "AerisMessageReceiver") public typealias UBMessageReceiver =
    AerisMessageReceiver

@available(*, deprecated, renamed: "AerisMessageReceiverFactory") public typealias
    UBMessageReceiverFactory = AerisMessageReceiverFactory

@available(*, deprecated, renamed: "AerisBridgeInvocation") public typealias UBBridgeInvocation =
    AerisBridgeInvocation
