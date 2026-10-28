#import "AerisUnifiedBridgePlugin.h"

NSString *const AerisFlutterBridgePluginKey = @"AerisUnifiedBridgePlugin";
NSString *const AerisFlutterBridgeChannelName = @"aeris_bridge";
NSString *const AerisFlutterLegacyBridgePluginKey = @"UBUnifiedBridgePlugin";

@interface AerisUnifiedBridgePlugin ()
@property(nonatomic, strong) FlutterBasicMessageChannel *channel;
@property(nonatomic, strong) id<AerisMessageReceiver> receiver;
@property(nonatomic, copy) NSString *startupMessage;
@property(atomic, assign) BOOL closed;
@end

@implementation AerisUnifiedBridgePlugin
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    NSCAssert(NSThread.isMainThread, @"Register on the platform main thread");
    AerisUnifiedBridgePlugin *plugin = [self new];
    plugin.channel =
        [FlutterBasicMessageChannel messageChannelWithName:AerisFlutterBridgeChannelName
                                           binaryMessenger:registrar.messenger
                                                     codec:[FlutterStringCodec sharedInstance]];
    __weak AerisUnifiedBridgePlugin *weakPlugin = plugin;
    [plugin.channel setMessageHandler:^(id message, FlutterReply reply) {
      // 此处仅确认框架消息，业务响应通过独立通道发送。
      reply(nil);
      AerisUnifiedBridgePlugin *current = weakPlugin;
      if (!current || current.closed)
          return;
      if (![message isKindOfClass:NSString.class] ||
          [(NSString *)message lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 256 * 1024) {
          [current close];
          return;
      }
      if (!current.receiver) {
          // Engine.run 会在宿主绑定前启动 Dart，因此最多暂存一条初始 hello 消息。
          // Core 收到 bridge.hello 就绪结果后才发送业务请求，插件无需解析 JSON。
          if (current.startupMessage) {
              [current close];
              return;
          }
          current.startupMessage = [message copy];
          return;
      }
      [current.receiver receiveMessage:message];
    }];
    // 发布此实例，使宿主能够查找它，并让 Flutter 调用其 detachFromEngine 回调。
    [registrar publish:plugin];
}
- (void)bindReceiver:(id<AerisMessageReceiver>)receiver {
    NSCAssert(NSThread.isMainThread, @"Bind on main");
    if (self.closed || self.receiver || !receiver) {
        [NSException raise:NSInternalInconsistencyException format:@"Bind exactly once per engine"];
    }
    self.receiver = receiver;
    NSString *initial = self.startupMessage;
    self.startupMessage = nil;
    if (initial)
        [receiver receiveMessage:initial];
}
- (void)emitMessageToDart:(NSString *)message {
    NSCAssert(NSThread.isMainThread, @"Send on main");
    if (!self.closed)
        [self.channel sendMessage:message];
}
- (void)close {
    NSCAssert(NSThread.isMainThread, @"Close on main");
    if (self.closed && !self.channel)
        return;
    self.closed = YES;
    [self.channel setMessageHandler:nil];
    [self.receiver close];
    self.receiver = nil;
    self.startupMessage = nil;
    self.channel = nil;
}
- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
    // 此回调由 Flutter 调用，原生 App 也可在 destroyContext 前显式关闭。
    if (NSThread.isMainThread)
        [self close];
    else
        dispatch_async(dispatch_get_main_queue(), ^{
          [self close];
        });
}
@end
