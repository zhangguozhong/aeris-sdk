// 为 AerisContracts 保留一个 Objective-C 编译单元，供当前 CocoaPods / SwiftPM 目标构建和链接。
// 请保留本文件；在现有配置下直接删除，会影响 Swift 模块导入或链接。
// 公共通信协议定义在 AerisMessageReceiver.h，公开头文件由 Podspec 配置导出。
//
// 早期 BridgeContracts.m 中的方法查找、签名校验和动态调用逻辑，已迁移到 AerisBridgeInvocation。
// 实现位置：Aeris Pod 的 Sources/Invocation/AerisBridgeInvocation.m，属于 Aeris/Core。
// BridgeRegistry 负责方法解析和缓存，实际查找与调用由 AerisBridgeInvocation 执行。
// 此处仅引用公共协议头文件，保持 Contracts 与原生执行层的依赖边界。
#import "AerisMessageReceiver.h"
