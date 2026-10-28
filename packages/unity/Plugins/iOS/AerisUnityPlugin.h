#import <Foundation/Foundation.h>
#import "AerisUnityHost.h"
#import "AerisUnityChannel.h"

NS_ASSUME_NONNULL_BEGIN

__attribute__((visibility("default"))) FOUNDATION_EXPORT NSErrorDomain const AerisUnityErrorDomain;
__attribute__((visibility("default"))) FOUNDATION_EXPORT NSString *const AerisUnityBridgeCodeKey;

typedef NS_ERROR_ENUM(AerisUnityErrorDomain, AerisUnityPluginErrorCode) {
    AerisUnityPluginErrorInvalidChannel = 1001,
    AerisUnityPluginErrorDuplicateChannel = 1002,
    AerisUnityPluginErrorResourceLimit = 1003,
    AerisUnityPluginErrorUnloadBusy = 1004,
    AerisUnityPluginErrorWrongThread = 1005,
    AerisUnityPluginErrorInvalidFactory = 1006,
    AerisUnityPluginErrorReceiverUnavailable = 1007,
    AerisUnityPluginErrorNativeFailure = 1008,
    AerisUnityPluginErrorInvalidArgument = 1009
};

// App 只连接 receive/close 闭包；Unity 协议包装由通用插件负责。
__attribute__((visibility("default")))
@interface AerisUnityReceiverCallbacks : NSObject <AerisUnityMessageReceiver>
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithReceive:(void (^)(NSString *message))receive
                          close:(void (^)(void))close
    NS_SWIFT_NAME(init(receive:close:)) NS_SWIFT_UI_ACTOR;
@end

typedef id<AerisUnityMessageReceiver> _Nullable (^AerisUnityReceiverBuilder)(
    void (^emitter)(NSString *message));

// App 每个容器持有一份，显式 close 后撤销注册及该容器的活动连接。
__attribute__((visibility("default")))
@interface AerisUnityHostBinding : NSObject
@property(nonatomic, readonly, copy) NSString *channel;
- (instancetype)init NS_UNAVAILABLE;
- (void)close NS_SWIFT_UI_ACTOR;
@end

__attribute__((visibility("default")))
@interface AerisUnityPlugin : NSObject
// 通道名只负责路由，权限与 source 由宿主工厂决定；重复或非法注册返回 nil。
+ (nullable AerisUnityHostBinding *)bindFactory:(id<AerisUnityMessageReceiverFactory>)factory
                                        channel:(NSString *)channel
    NS_SWIFT_NAME(bind(factory:channel:)) NS_SWIFT_UI_ACTOR;
// 闭包接入入口；内部创建 Factory 包装，不依赖宿主 App 的 Pod。
+ (nullable AerisUnityHostBinding *)bindChannel:(NSString *)channel
                                  makeReceiver:(AerisUnityReceiverBuilder)makeReceiver
    NS_SWIFT_NAME(bind(channel:makeReceiver:)) NS_SWIFT_UI_ACTOR;
// 新入口保留具体错误；旧 nil/BOOL 接口继续可用。
+ (nullable AerisUnityHostBinding *)bindChannel:(NSString *)channel
                                  makeReceiver:(AerisUnityReceiverBuilder)makeReceiver
                                         error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(bindChecked(channel:makeReceiver:)) NS_SWIFT_UI_ACTOR;
+ (BOOL)prepareForUnityUnloadWithError:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(prepareForUnityUnloadChecked()) NS_SWIFT_UI_ACTOR;
// 只含固定元数据，不记录载荷、extra、异常详情或任意输入；重置不改变活动路由。
+ (NSDictionary<NSString *, id> *)diagnosticsSnapshot NS_SWIFT_UI_ACTOR;
+ (void)resetDiagnostics NS_SWIFT_UI_ACTOR;
// 必须在卸载 Unity 前于主线程同步执行，先清空全部函数指针，再关闭接收器。
// 此屏障不向托管端回调；应先 Dispose C# owner，不可从反向回调内部卸载 Unity。
+ (BOOL)prepareForUnityUnload NS_SWIFT_UI_ACTOR;
@end

NS_ASSUME_NONNULL_END
