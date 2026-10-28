#import "AerisUnityPlugin.h"
#include <limits.h>
#include <atomic>

NSErrorDomain const AerisUnityErrorDomain = @"dev.aeris.unity";
NSString *const AerisUnityBridgeCodeKey = @"AerisUnityBridgeCode";
static NSMutableDictionary<NSString *, NSNumber *> *diagnosticCounts;
static NSMutableArray<NSDictionary *> *diagnosticFailures;
static std::atomic<uint64_t> wrongThreadRejects{0};

static NSString *BridgeCode(AerisUnityPluginErrorCode code) {
    switch (code) {
    case AerisUnityPluginErrorInvalidChannel: return @"UNITY_INVALID_CHANNEL";
    case AerisUnityPluginErrorDuplicateChannel: return @"UNITY_CHANNEL_ALREADY_BOUND";
    case AerisUnityPluginErrorResourceLimit: return @"UNITY_RESOURCE_LIMIT";
    case AerisUnityPluginErrorUnloadBusy: return @"UNITY_UNLOAD_BUSY";
    case AerisUnityPluginErrorWrongThread: return @"UNITY_WRONG_THREAD";
    case AerisUnityPluginErrorInvalidFactory: return @"UNITY_INVALID_FACTORY";
    case AerisUnityPluginErrorReceiverUnavailable: return @"UNITY_RECEIVER_UNAVAILABLE";
    case AerisUnityPluginErrorInvalidArgument: return @"UNITY_INVALID_ARGUMENT";
    default: return @"UNITY_NATIVE_FAILURE";
    }
}

static NSString *ErrorDescription(AerisUnityPluginErrorCode code) {
    switch (code) {
    case AerisUnityPluginErrorInvalidChannel: return @"Invalid Unity channel name";
    case AerisUnityPluginErrorDuplicateChannel: return @"Unity channel is already bound";
    case AerisUnityPluginErrorResourceLimit: return @"Unity channel resource limit reached";
    case AerisUnityPluginErrorUnloadBusy: return @"Leave the native call stack before unloading";
    case AerisUnityPluginErrorWrongThread: return @"Use the Unity channel on the main thread";
    case AerisUnityPluginErrorInvalidFactory: return @"Expected a Unity receiver factory";
    case AerisUnityPluginErrorReceiverUnavailable: return @"Unity receiver is unavailable";
    case AerisUnityPluginErrorInvalidArgument: return @"Invalid Unity native argument";
    default: return @"Unity native operation failed";
    }
}

static void CountOperation(NSString *key) {
    if (!diagnosticCounts)
        diagnosticCounts = [NSMutableDictionary new];
    diagnosticCounts[key] = @([diagnosticCounts[key] unsignedLongLongValue] + 1);
}

static void RecordFailure(NSString *operation, AerisUnityPluginErrorCode code, NSInteger status) {
    if (![NSThread isMainThread]) {
        wrongThreadRejects.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    CountOperation([operation stringByAppendingString:@".failure"]);
    CountOperation([@"failure." stringByAppendingString:BridgeCode(code)]);
    if (!diagnosticFailures)
        diagnosticFailures = [NSMutableArray new];
    if (diagnosticFailures.count == 64)
        [diagnosticFailures removeObjectAtIndex:0];
    [diagnosticFailures addObject:@{@"operation": operation, @"code": BridgeCode(code), @"status": @(status)}];
}

static BOOL Reject(NSString *operation, AerisUnityPluginErrorCode code, NSError **error) {
    RecordFailure(operation, code, code);
    if (error)
        *error = [NSError errorWithDomain:AerisUnityErrorDomain code:code userInfo:@{
          NSLocalizedDescriptionKey: ErrorDescription(code), AerisUnityBridgeCodeKey: BridgeCode(code)
        }];
    return NO;
}

static AerisUnityStatus NativeReject(NSString *operation, AerisUnityPluginErrorCode code,
                                    AerisUnityStatus status) {
    RecordFailure(operation, code, status);
    return status;
}

@interface AerisUnityReceiverCallbacks ()
@property(nonatomic, copy, nullable) void (^receiveBlock)(NSString *);
@property(nonatomic, copy, nullable) void (^closeBlock)(void);
@end

@implementation AerisUnityReceiverCallbacks
- (instancetype)initWithReceive:(void (^)(NSString *))receive close:(void (^)(void))close {
    self = [super init];
    if (self) {
        _receiveBlock = [receive copy];
        _closeBlock = [close copy];
    }
    return self;
}
- (void)receiveMessage:(NSString *)message {
    if (![NSThread isMainThread])
        return;
    void (^receive)(NSString *) = self.receiveBlock;
    if (receive)
        receive(message);
}
- (void)close {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self close]; });
        return;
    }
    void (^close)(void) = self.closeBlock;
    self.receiveBlock = nil;
    self.closeBlock = nil;
    if (close)
        close();
}
@end

// 只有插件认识 Unity 接收器协议；App 无需再实现 Factory/Receiver 类。
@interface AerisUnityBlockReceiverFactory : NSObject <AerisUnityMessageReceiverFactory>
@property(nonatomic, copy) AerisUnityReceiverBuilder builder;
@end

@implementation AerisUnityBlockReceiverFactory
- (id<AerisUnityMessageReceiver>)makeReceiverWithEmitter:(void (^)(NSString *))emitter {
    return self.builder(emitter);
}
@end

@class AerisUnityEndpoint;
static NSMutableDictionary<NSString *, AerisUnityHostBinding *> *bindings;
static NSMutableDictionary<NSNumber *, AerisUnityEndpoint *> *endpoints;
static int64_t nextHandle = 1;
static BOOL preparingUnload;
static BOOL closingForUnload;
static uint64_t callbackEpoch;
static NSInteger activeCallbacks;
static NSInteger activeManagedCalls;

// 防止业务在 P/Invoke 尚未返回时卸载 IL2CPP，返回路径仍需要托管运行时。
struct AerisManagedCallScope {
    AerisManagedCallScope() {
        activeManagedCalls++;
    }
    ~AerisManagedCallScope() {
        activeManagedCalls--;
    }
};

@interface AerisUnityHostBinding ()
@property(nonatomic, readwrite, copy) NSString *channel;
@property(nonatomic, strong) id<AerisUnityMessageReceiverFactory> factory;
@property(nonatomic, strong, nullable) AerisUnityEndpoint *endpoint;
@property(nonatomic) BOOL closed;
- (instancetype)initWithChannel:(NSString *)channel
                        factory:(id<AerisUnityMessageReceiverFactory>)factory;
@end

@interface AerisUnityEndpoint : NSObject
@property(nonatomic) int64_t handle;
@property(nonatomic) int64_t context;
@property(nonatomic) AerisUnityMessageCallback messageCallback;
@property(nonatomic) AerisUnityClosedCallback closedCallback;
@property(nonatomic, weak) AerisUnityHostBinding *binding;
@property(nonatomic, strong, nullable) id<AerisUnityMessageReceiver> receiver;
@property(nonatomic) BOOL ready;
@property(nonatomic) BOOL closed;
- (void)emit:(NSString *)message;
- (void)closeWithReason:(AerisUnityStatus)reason notify:(BOOL)notify;
@end

static BOOL ValidChannel(NSString *value) {
    if (!value || [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 128)
        return NO;
    NSCharacterSet *invalid = [[NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.:-"] invertedSet];
    return value.length > 0 && [value rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

@implementation AerisUnityEndpoint
- (void)emit:(NSString *)message {
    if (![NSThread isMainThread] || self.closed || !self.ready || !self.messageCallback)
        return;
    NSData *data = [message dataUsingEncoding:NSUTF8StringEncoding];
    if (!data || data.length == 0 || data.length > 2 * 1024 * 1024) {
        RecordFailure(@"emit", AerisUnityPluginErrorInvalidArgument, AerisUnityInvalidArgument);
        [self closeWithReason:AerisUnityInvalidArgument notify:YES];
        return;
    }
    activeCallbacks++;
    @try {
        self.messageCallback(self.context, (const uint8_t *)data.bytes, (int32_t)data.length);
    } @finally {
        activeCallbacks--;
    }
    CountOperation(@"emit.success");
}
- (void)closeWithReason:(AerisUnityStatus)reason notify:(BOOL)notify {
    if (self.closed)
        return;
    self.closed = YES;
    AerisUnityClosedCallback callback = notify && self.ready ? self.closedCallback : nullptr;
    int64_t context = self.context;
    uint64_t epoch = callbackEpoch;
    // 先撤销句柄与函数指针，接收器清理产生的迟到消息不会进入托管运行时。
    self.messageCallback = nullptr;
    self.closedCallback = nullptr;
    [endpoints removeObjectForKey:@(self.handle)];
    if (self.binding.endpoint == self)
        self.binding.endpoint = nil;
    id<AerisUnityMessageReceiver> receiver = self.receiver;
    self.receiver = nil;
    @try {
        [receiver close];
    } @catch (NSException *exception) { /* 清理失败仍撤销路由，不记录异常详情。 */
        RecordFailure(@"close", AerisUnityPluginErrorNativeFailure, AerisUnityNativeFailure);
    }
    // receiver.close 可以重入卸载屏障，不能再调用其清理前保存的旧函数指针。
    if (callback && epoch == callbackEpoch && !preparingUnload) {
        activeCallbacks++;
        @try {
            callback(context, reason);
        } @finally {
            activeCallbacks--;
        }
    }
}
@end

@implementation AerisUnityHostBinding
- (instancetype)initWithChannel:(NSString *)channel
                        factory:(id<AerisUnityMessageReceiverFactory>)factory {
    self = [super init];
    if (self) {
        _channel = [channel copy];
        _factory = factory;
    }
    return self;
}
- (void)close {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
          [self close];
        });
        return;
    }
    if (self.closed)
        return;
    self.closed = YES;
    if (bindings[self.channel] == self)
        [bindings removeObjectForKey:self.channel];
    AerisUnityEndpoint *endpoint = self.endpoint;
    [endpoint closeWithReason:AerisUnityClosed notify:!preparingUnload];
    self.endpoint = nil;
    self.factory = nil;
}
@end

@implementation AerisUnityPlugin
+ (AerisUnityHostBinding *)bindChannel:(NSString *)channel
                        makeReceiver:(AerisUnityReceiverBuilder)makeReceiver {
    return [self bindChannel:channel makeReceiver:makeReceiver error:nil];
}
+ (AerisUnityHostBinding *)bindChannel:(NSString *)channel
                        makeReceiver:(AerisUnityReceiverBuilder)makeReceiver
                               error:(NSError **)error {
    if (error) *error = nil;
    if (![NSThread isMainThread]) {
        Reject(@"bind", AerisUnityPluginErrorWrongThread, error);
        return nil;
    }
    if (!makeReceiver) {
        Reject(@"bind", AerisUnityPluginErrorInvalidFactory, error);
        return nil;
    }
    AerisUnityBlockReceiverFactory *factory = [AerisUnityBlockReceiverFactory new];
    factory.builder = makeReceiver;
    return [self bindFactory:factory channel:channel error:error];
}
+ (AerisUnityHostBinding *)bindFactory:(id<AerisUnityMessageReceiverFactory>)factory
                               channel:(NSString *)channel {
    return [self bindFactory:factory channel:channel error:nil];
}
+ (AerisUnityHostBinding *)bindFactory:(id<AerisUnityMessageReceiverFactory>)factory
                               channel:(NSString *)channel error:(NSError **)error {
    if (error) *error = nil;
    AerisUnityPluginErrorCode failure = (AerisUnityPluginErrorCode)0;
    if (![NSThread isMainThread]) failure = AerisUnityPluginErrorWrongThread;
    else if (closingForUnload) failure = AerisUnityPluginErrorUnloadBusy;
    else if (!factory) failure = AerisUnityPluginErrorInvalidFactory;
    else if (!ValidChannel(channel)) failure = AerisUnityPluginErrorInvalidChannel;
    else if (bindings[channel]) failure = AerisUnityPluginErrorDuplicateChannel;
    else if (bindings.count >= 128) failure = AerisUnityPluginErrorResourceLimit;
    if (failure) {
        Reject(@"bind", failure, error);
        return nil;
    }
    if (!bindings) {
        bindings = [NSMutableDictionary new];
        endpoints = [NSMutableDictionary new];
    }
    preparingUnload = NO;
    AerisUnityHostBinding *binding = [[AerisUnityHostBinding alloc] initWithChannel:channel
                                                                            factory:factory];
    bindings[channel] = binding;
    CountOperation(@"bind.success");
    return binding;
}
+ (NSDictionary<NSString *, id> *)diagnosticsSnapshot {
    if (![NSThread isMainThread]) return @{};
    NSMutableDictionary *counts = [diagnosticCounts mutableCopy] ?: [NSMutableDictionary new];
    counts[@"wrongThreadRejects"] = @(wrongThreadRejects.load(std::memory_order_relaxed));
    return @{@"counters": [counts copy], @"failures": [diagnosticFailures copy] ?: @[],
             @"gauges": @{@"bindings": @(bindings.count), @"endpoints": @(endpoints.count),
                          @"activeCallbacks": @(activeCallbacks), @"activeManagedCalls": @(activeManagedCalls)}};
}
+ (void)resetDiagnostics {
    if (![NSThread isMainThread]) return;
    diagnosticCounts = [NSMutableDictionary new];
    diagnosticFailures = [NSMutableArray new];
    wrongThreadRejects.store(0, std::memory_order_relaxed);
}
+ (BOOL)prepareForUnityUnload {
    return [self prepareForUnityUnloadWithError:nil];
}
+ (BOOL)prepareForUnityUnloadWithError:(NSError **)error {
    if (error) *error = nil;
    if (![NSThread isMainThread])
        return Reject(@"unload", AerisUnityPluginErrorWrongThread, error);
    if (closingForUnload || activeCallbacks > 0 || activeManagedCalls > 0)
        return Reject(@"unload", AerisUnityPluginErrorUnloadBusy, error);
    preparingUnload = YES;
    closingForUnload = YES;
    callbackEpoch++;
    // 同步主线程屏障：先清空所有函数指针，之后才运行任意接收器清理。
    for (AerisUnityEndpoint *endpoint in endpoints.allValues) {
        endpoint.messageCallback = nullptr;
        endpoint.closedCallback = nullptr;
    }
    for (AerisUnityHostBinding *binding in bindings.allValues)
        [binding close];
    closingForUnload = NO;
    CountOperation(@"unload.success");
    return YES;
}
@end

AerisUnityStatus AerisUnity_Open(const uint8_t *channel, int32_t channelLength, int64_t context,
                                 AerisUnityMessageCallback message, AerisUnityClosedCallback closed,
                                 int64_t *handle) {
    if (handle)
        *handle = 0;
    if (![NSThread isMainThread])
        return NativeReject(@"open", AerisUnityPluginErrorWrongThread, AerisUnityWrongThread);
    AerisManagedCallScope scope;
    if (!channel || channelLength < 1 || channelLength > 128 || context <= 0 || !message ||
        !closed || !handle)
        return NativeReject(@"open", AerisUnityPluginErrorInvalidArgument, AerisUnityInvalidArgument);
    NSString *name = [[NSString alloc] initWithBytes:channel
                                              length:channelLength
                                            encoding:NSUTF8StringEncoding];
    if (!ValidChannel(name))
        return NativeReject(@"open", AerisUnityPluginErrorInvalidArgument, AerisUnityInvalidArgument);
    AerisUnityHostBinding *binding = bindings[name];
    if (!binding || binding.closed || preparingUnload)
        return NativeReject(@"open", AerisUnityPluginErrorReceiverUnavailable, AerisUnityChannelNotBound);
    if (binding.endpoint)
        return NativeReject(@"open", AerisUnityPluginErrorDuplicateChannel, AerisUnityChannelInUse);
    if (nextHandle == INT64_MAX)
        return NativeReject(@"open", AerisUnityPluginErrorResourceLimit, AerisUnityResourceLimit);
    AerisUnityEndpoint *endpoint = [AerisUnityEndpoint new];
    endpoint.handle = nextHandle++;
    endpoint.context = context;
    endpoint.messageCallback = message;
    endpoint.closedCallback = closed;
    endpoint.binding = binding;
    binding.endpoint = endpoint;
    endpoints[@(endpoint.handle)] = endpoint;
    @try {
        __weak AerisUnityEndpoint *weakEndpoint = endpoint;
        id<AerisUnityMessageReceiver> receiver =
            [binding.factory makeReceiverWithEmitter:^(NSString *text) {
              [weakEndpoint emit:text];
            }];
        if (!receiver || endpoint.closed || binding.closed) {
            [receiver close];
            [endpoint closeWithReason:AerisUnityClosed notify:NO];
            return NativeReject(@"open", AerisUnityPluginErrorReceiverUnavailable, AerisUnityClosed);
        }
        endpoint.receiver = receiver;
        // 工厂创建期间不允许反向回调；成功返回后才开始接收请求。
        endpoint.ready = YES;
        *handle = endpoint.handle;
        CountOperation(@"open.success");
        return AerisUnitySuccess;
    } @catch (NSException *exception) {
        [endpoint closeWithReason:AerisUnityNativeFailure notify:NO];
        return NativeReject(@"open", AerisUnityPluginErrorNativeFailure, AerisUnityNativeFailure);
    }
}

AerisUnityStatus AerisUnity_Send(int64_t handle, const uint8_t *bytes, int32_t length) {
    if (![NSThread isMainThread])
        return NativeReject(@"send", AerisUnityPluginErrorWrongThread, AerisUnityWrongThread);
    AerisManagedCallScope scope;
    if (!bytes || length < 1 || length > 256 * 1024)
        return NativeReject(@"send", AerisUnityPluginErrorInvalidArgument, AerisUnityInvalidArgument);
    AerisUnityEndpoint *endpoint = endpoints[@(handle)];
    if (!endpoint || endpoint.closed)
        return NativeReject(@"send", AerisUnityPluginErrorReceiverUnavailable, AerisUnityClosed);
    NSString *text = [[NSString alloc] initWithBytes:bytes
                                              length:length
                                            encoding:NSUTF8StringEncoding];
    if (!text)
        return NativeReject(@"send", AerisUnityPluginErrorInvalidArgument, AerisUnityInvalidArgument);
    @try {
        [endpoint.receiver receiveMessage:text];
        CountOperation(@"send.success");
        return AerisUnitySuccess;
    } @catch (NSException *exception) {
        [endpoint closeWithReason:AerisUnityNativeFailure notify:YES];
        return NativeReject(@"send", AerisUnityPluginErrorNativeFailure, AerisUnityNativeFailure);
    }
}

AerisUnityStatus AerisUnity_Close(int64_t handle) {
    if (![NSThread isMainThread])
        return NativeReject(@"close", AerisUnityPluginErrorWrongThread, AerisUnityWrongThread);
    AerisManagedCallScope scope;
    AerisUnityEndpoint *endpoint = endpoints[@(handle)];
    [endpoint closeWithReason:AerisUnityClosed notify:NO];
    CountOperation(@"close.success");
    return AerisUnitySuccess;
}
