#pragma once

// 旧 Objective-C 类型名称的源码迁移入口；主实现与运行时导出均使用 Aeris。
// 请重新编译调用方，并将 NSClassFromString 等反射字符串更新为新名称。
#define UBBridgeInvocation AerisBridgeInvocation
#define UBBridgeSession AerisBridgeSession
#define UBBridgeSource AerisBridgeSource
#define UBNativeTransport AerisNativeTransport
#define UBBridgeReceiverFactory AerisBridgeReceiverFactory
#define UBRNNativeTransport AerisRNNativeTransport
#define UBFlutterNativeTransport AerisFlutterNativeTransport
#define UBWebNativeTransport AerisWebNativeTransport
#define UBUnityNativeTransport AerisUnityNativeTransport
