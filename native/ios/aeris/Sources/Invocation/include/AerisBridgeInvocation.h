#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// 固定 ABI：宿主方法返回 void，且只接收一个 BridgeSession 对象。
// 仅在已注册模块对象中发现方法，排除 NSObject 方法和属性访问器。
@interface AerisBridgeInvocation : NSObject
+ (SEL _Nullable)lookupTarget:(NSObject *)target
                   methodName:(NSString *)methodName NS_SWIFT_UI_ACTOR
    NS_SWIFT_NAME(lookup(_:methodName:));
+ (BOOL)validateTarget:(NSObject *)target
              selector:(SEL)selector NS_SWIFT_UI_ACTOR NS_SWIFT_NAME(validate(_:selector:));
+ (BOOL)invokeTarget:(NSObject *)target
            selector:(SEL)selector
             session:(NSObject *)session NS_SWIFT_UI_ACTOR
    NS_SWIFT_NAME(invoke(_:selector:session:));
@end

NS_ASSUME_NONNULL_END
