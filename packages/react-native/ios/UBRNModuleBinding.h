#import <AerisContracts/UBMessageReceiver.h>
#import "AerisRNModuleBinding.h"

// 旧版源码兼容入口；新接入请导入 AerisRNModuleBinding.h。
#define UBRNModuleBinding AerisRNModuleBinding

NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT Class UBUnifiedBridgeModuleClass(void)
    __attribute__((deprecated("Use AerisUnifiedBridgeModuleClass")));
FOUNDATION_EXPORT id<AerisRNModuleBinding> UBCreateUnifiedBridgeModule(void) NS_SWIFT_UI_ACTOR
    __attribute__((deprecated("Use AerisCreateUnifiedBridgeModule")));
NS_ASSUME_NONNULL_END
