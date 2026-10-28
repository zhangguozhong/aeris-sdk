#import <Foundation/Foundation.h>
#import <AerisContracts/AerisMessageReceiver.h>

NS_ASSUME_NONNULL_BEGIN

// 公共接口仅包含 Objective-C 类型，避免向 Swift 导入方暴露 Codegen/C++ 类型。
@protocol AerisRNModuleBinding <NSObject>
- (void)bindReceiver:(id<AerisMessageReceiver>)receiver NS_SWIFT_UI_ACTOR;
- (void)emitMessageToJS:(NSString *)message NS_SWIFT_UI_ACTOR;
@end

// 返回的对象是实际的 RCTUnifiedBridge 实例，通过此接口使用。
FOUNDATION_EXPORT Class AerisUnifiedBridgeModuleClass(void);
FOUNDATION_EXPORT id<AerisRNModuleBinding> AerisCreateUnifiedBridgeModule(void) NS_SWIFT_UI_ACTOR;

NS_ASSUME_NONNULL_END
