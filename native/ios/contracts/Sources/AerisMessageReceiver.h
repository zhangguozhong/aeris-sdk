#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// 由原生宿主实现，所有调用在主线程串行执行。
@protocol AerisMessageReceiver <NSObject>
- (void)receiveMessage:(NSString *)message NS_SWIFT_UI_ACTOR;
- (void)close NS_SWIFT_UI_ACTOR;
@end

// 可选的两阶段关闭能力。旧接收器仍只需实现基础协议；容器必须显式检查此能力。
@protocol AerisClosingMessageReceiver <AerisMessageReceiver>
- (void)beginClosing NS_SWIFT_UI_ACTOR;
@end

// 由宿主提供的工厂，让 RN 适配代码无需导入 Swift 类即可创建接收器。
@protocol AerisMessageReceiverFactory <NSObject>
- (id<AerisMessageReceiver>)makeReceiverWithEmitter:(void (^)(NSString *message))emitter
    NS_SWIFT_UI_ACTOR;
@end

NS_ASSUME_NONNULL_END
