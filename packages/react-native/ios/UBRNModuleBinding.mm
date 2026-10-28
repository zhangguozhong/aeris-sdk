#import "UBRNModuleBinding.h"

// 旧 C 符号保留为源码迁移入口，行为与新工厂完全一致。
Class UBUnifiedBridgeModuleClass(void) {
    return AerisUnifiedBridgeModuleClass();
}
id<AerisRNModuleBinding> UBCreateUnifiedBridgeModule(void) {
    return AerisCreateUnifiedBridgeModule();
}
