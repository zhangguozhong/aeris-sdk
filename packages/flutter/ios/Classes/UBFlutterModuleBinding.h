#import <AerisContracts/UBMessageReceiver.h>
#import "AerisFlutterModuleBinding.h"

// 旧版协议名称仅供源码兼容；新接入使用 Aeris 前缀。
#define UBFlutterModuleBinding AerisFlutterModuleBinding

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const UBFlutterBridgePluginKey
    __attribute__((deprecated("Use AerisFlutterBridgePluginKey for new registration")));
FOUNDATION_EXPORT NSString *const UBFlutterBridgeChannelName
    __attribute__((deprecated("Use AerisFlutterBridgeChannelName")));
NS_ASSUME_NONNULL_END
