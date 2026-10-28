#import <Foundation/Foundation.h>
#import <AerisContracts/AerisMessageReceiver.h>

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const AerisFlutterBridgePluginKey;
FOUNDATION_EXPORT NSString *const AerisFlutterBridgeChannelName;
// 仅用于查找旧 GeneratedPluginRegistrant 发布的实例。
FOUNDATION_EXPORT NSString *const AerisFlutterLegacyBridgePluginKey;

@protocol AerisFlutterModuleBinding <NSObject>
- (void)bindReceiver:(id<AerisMessageReceiver>)receiver NS_SWIFT_UI_ACTOR;
- (void)emitMessageToDart:(NSString *)message NS_SWIFT_UI_ACTOR;
- (void)close NS_SWIFT_UI_ACTOR;
@end
NS_ASSUME_NONNULL_END
