#pragma once
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

typedef int32_t AerisUnityStatus;
enum {
    AerisUnitySuccess = 0,
    AerisUnityInvalidArgument = 1,
    AerisUnityWrongThread = 2,
    AerisUnityChannelNotBound = 3,
    AerisUnityChannelInUse = 4,
    AerisUnityClosed = 5,
    AerisUnityNativeFailure = 6,
    AerisUnityResourceLimit = 7
};

// 回调期间借用 bytes；托管端必须同步复制，不释放或保存此指针。
typedef void (*AerisUnityMessageCallback)(int64_t context, const uint8_t *bytes, int32_t length);
typedef void (*AerisUnityClosedCallback)(int64_t context, int32_t reason);

#define AERIS_UNITY_EXPORT __attribute__((visibility("default")))

// Open/Send/Close 在 Unity 所在的 iOS 主线程调用，所有句柄在进程内永不复用。
AERIS_UNITY_EXPORT AerisUnityStatus AerisUnity_Open(const uint8_t *channel, int32_t channelLength,
                                                    int64_t context,
                                                    AerisUnityMessageCallback message,
                                                    AerisUnityClosedCallback closed,
                                                    int64_t *handle);
AERIS_UNITY_EXPORT AerisUnityStatus AerisUnity_Send(int64_t handle, const uint8_t *bytes,
                                                    int32_t length);
AERIS_UNITY_EXPORT AerisUnityStatus AerisUnity_Close(int64_t handle);

#if defined(__cplusplus)
}
#endif
