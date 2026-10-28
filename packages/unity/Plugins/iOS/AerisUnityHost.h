#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// UnityFramework 的宿主契约只依赖 Foundation，不引用 App 的 Pod 模块。
__attribute__((visibility("default")))
@protocol AerisUnityMessageReceiver<NSObject>
- (void)receiveMessage:(NSString *)message NS_SWIFT_UI_ACTOR;
- (void)close NS_SWIFT_UI_ACTOR;
@end

__attribute__((visibility("default")))
@protocol AerisUnityMessageReceiverFactory<NSObject>
- (nullable id<AerisUnityMessageReceiver>)makeReceiverWithEmitter:(void (^)(NSString *message))emitter
    NS_SWIFT_UI_ACTOR;
@end

NS_ASSUME_NONNULL_END
