#import <Foundation/Foundation.h>
#import <NativeUnifiedBridgeSpec/NativeUnifiedBridgeSpec.h>
#import <React/RCTInvalidating.h>
#import "AerisRNModuleBinding.h"

NS_ASSUME_NONNULL_BEGIN

@interface RCTUnifiedBridge
    : NativeUnifiedBridgeSpecBase <NativeUnifiedBridgeSpec, RCTInvalidating, AerisRNModuleBinding>
@end

NS_ASSUME_NONNULL_END
