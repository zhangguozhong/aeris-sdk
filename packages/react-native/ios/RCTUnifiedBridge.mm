#import "RCTUnifiedBridge.h"

@interface RCTUnifiedBridge ()
@property(atomic, assign) BOOL invalidated;
@end

@implementation RCTUnifiedBridge {
    id<AerisMessageReceiver> _receiver; // 实现由宿主管理，仅允许主线程访问。
}

+ (NSString *)moduleName {
    return @"NativeUnifiedBridge";
}
+ (BOOL)requiresMainQueueSetup {
    return YES;
}

- (void)bindReceiver:(id<AerisMessageReceiver>)receiver {
    NSCAssert(NSThread.isMainThread, @"Bind on main before returning this module to RN");
    if (self.invalidated || _receiver != nil || receiver == nil) {
        [NSException raise:NSInternalInconsistencyException
                    format:@"Receiver must be bound exactly once"];
    }
    _receiver = receiver;
}

- (void)send:(NSString *)message {
    NSString *text = [message copy];
    __weak RCTUnifiedBridge *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      RCTUnifiedBridge *self = weakSelf;
      if (!self || self.invalidated)
          return;
      // 在 RN 获取此实例前完成注入；缺少注入意味着宿主存在错误。
      if (!self->_receiver) {
          [NSException raise:NSInternalInconsistencyException
                      format:@"Native Bridge receiver was not injected"];
      }
      [self->_receiver receiveMessage:text];
    });
}

- (void)emitMessageToJS:(NSString *)message {
    NSCAssert(NSThread.isMainThread, @"Emit on main");
    if (!self.invalidated)
        [self emitOnMessage:message];
}

- (void)invalidate {
    self.invalidated = YES; // 立即阻止消息发送，无需等待主队列清理。
    dispatch_async(dispatch_get_main_queue(), ^{
      [self->_receiver close];
      self->_receiver = nil;
    });
}

- (std::shared_ptr<facebook::react::TurboModule>)getTurboModule:
    (const facebook::react::ObjCTurboModule::InitParams &)params {
    return std::make_shared<facebook::react::NativeUnifiedBridgeSpecJSI>(params);
}
@end

Class AerisUnifiedBridgeModuleClass(void) {
    return RCTUnifiedBridge.class;
}
id<AerisRNModuleBinding> AerisCreateUnifiedBridgeModule(void) {
    return [RCTUnifiedBridge new];
}
