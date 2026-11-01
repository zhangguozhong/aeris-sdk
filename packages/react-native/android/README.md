# Aeris React Native Android 候选实现

此目录来自私有 `feat/android-rn` 候选分支。本次 Android 实现尚未公开发布；已公开的 `0.26.0-preview.1` npm 包、Git tag 和 iOS API 保持不变。Android Core 尚无公开 Maven 制品，不能按 Maven 坐标安装。

## 源码接入

宿主使用 React Native 0.87.0、React 19.2.3、JDK 17、AGP 9.2.1、Gradle 9.4.1、Android API 37 和 minSdk 24。AGP 9 提供内置 Kotlin 支持；不要再次应用旧 Kotlin Android 插件。应用在 `settings.gradle.kts` 中显式引用候选源码：

```kotlin
include(":aeris")
project(":aeris").projectDir = file("<candidate>/native/android/aeris")
include(":aeris-react-native")
project(":aeris-react-native").projectDir = file("<candidate>/packages/react-native/android")
```

应用添加 `implementation(project(":aeris-react-native"))`。传入 `-PaerisNodeModulesDir=<absolute-node_modules>` 指向宿主已安装 RN 0.87.0 与 Codegen 0.87.0 的依赖目录。插件 `preBuild` 真实执行 Codegen，由现有 TypeScript Spec 生成 `NativeUnifiedBridgeSpec.java`；不提交或伪造生成接口。CI 使用 `tooling/android-bootstrap/package-lock.json` 独立安装固定依赖，无开发机绝对路径。CLI 与 Android 配置扫描器固定为 20.2.0，并对源码与实际 npm tarball 解包内容执行空配置自动链接检查；不手填 Package import 或 instance。

## 独立绑定

公共类型位于 `com.aeris.sdk.reactnative`：

- `AerisMessageReceiver`：`receiveMessage`、`beginClosing`、`close`。
- `AerisRNModuleBinding`：`bindReceiver`、`emitMessageToJS`。
- `AerisRNReceiverFactory`：`create(binding)` 返回该 RN Context 独享的接收器。
- `AerisRNPackage(factory)`：每个 Context 创建模块并在主线程调用 factory；无参构造支持自动链接。

宿主替换默认自动链接 Package 后注入 factory：

```kotlin
AerisRNPackage(AerisRNReceiverFactory { binding ->
    val transport = AerisRNNativeTransport(
        engine = sharedEngine,
        uiContext = containerContext,
        allowedPermissions = setOf("echo"),
        allowedEventTopics = setOf("business.changed"),
        emit = binding::emitMessageToJS,
    )
    object : AerisMessageReceiver {
        override fun receiveMessage(message: String) = transport.receive(message)
        override fun beginClosing() = transport.beginClosing()
        override fun close() = transport.close()
    }
})
```

不要同时注册两个 `NativeUnifiedBridge` Package。绑定仅发生一次，模块不保存项目业务或全局“当前接收器”。缺少接收器时第一次发送产生有界 `DISCONNECTED` 关闭消息；后续消息忽略。RN 线程发送、factory、宿主接收、事件发送和销毁清理经过主 dispatcher；`invalidate` 立即阻断迟到消息并异步关闭接收器一次。

RN 页面自己的通道可以直接创建 Core Transport，不要求为每页新增 RN NativeModule。共享 Engine 的不同 Connection 仍隔离 callbackId、订阅、权限和关闭状态。

第一阶段的 `BridgeEventProvider` 自动观察仅支持 GLOBAL topic。CONTEXT topic 使用 `engine.publish(topic, data, uiContext)` 显式发布；注册 CONTEXT 与非空 provider 的组合会返回 `INVALID_ARGUMENT`，以免静默丢弃事件。

## 协议与验证

请求仅接受 `callbackId/method/params/timeoutMs/extra`；`source=2` 由 Native 填写。回包为 `callbackId/seq/finished/result|error/extra`；事件为 `subscriptionId/seq/data|error`。不引入 `kind/v/stream/keepAlive`。业务 JSON 深度 32，协议封套深度 64，单消息 256 KiB。

`bridge.cancel` 的 params 包含 `targetCallbackId` 与可选字符串 `reason`，与现有 JS Client 一致。Native 在所属 Connection 中找到目标 Session 后执行 onCancel；`accepted=true` 只表示受理取消，不表示业务 UI 已关闭。未知字段与非字符串 reason 会被拒绝，业务资源仍由宿主的异步清理 callback 确认完成。

本机仅运行真实协议 JVM 回归，不安装 Android SDK：

```sh
JAVA_HOME=<jdk17> gradle -p native/android/protocol-tests test --no-daemon
```

`.github/workflows/android-foundation.yml` 在 GitHub runner 安装 Android SDK，真实执行 Core 与 RN Debug/Release 编译、Codegen、Android 单元测试。测试 XML、报告、生成接口与完整 Gradle 日志保留七天。JVM 成功不能替代这些 Android 编译结果；运行设备验证由宿主应用 CI 完成。

候选代码 `7eeb432` 的 [Android CI 41086248655](https://github.com/zhangguozhong/Aeris/actions/runs/41086248655) 已通过 Core/RN Debug 与 Release 编译、真实 Codegen、35 项 Android 单元测试及 2 项源码/归档自动链接测试。本地纯 JVM 回归为 34 项（不执行 Android Package 构造测试）；不能将两种环境的计数混为一谈。

## 持续集成

Android foundation 工作流配置为 main push 和面向 main 的普通 PR 自动执行，权限为 contents:read，不需要发布凭据。验收包含真实 Codegen、Core/RN Debug/Release AAR、35 项 Android 单元测试和源码/打包制品两项自动链接检查。配置在对应合并后对 main 生效，不改变公开 npm/Maven 版本。

本次功能分支运行：[CI 41152166193](https://github.com/zhangguozhong/Aeris/actions/runs/41152166193) 已通过。

## Android 通用命名空间

Core 使用 `com.aeris.sdk`，RN 插件使用 `com.aeris.sdk.reactnative`，生成的 Java Spec 使用 `com.aeris.sdk.reactnative.codegen`；源码目录、Gradle namespace/group、Codegen 和 R8 注解规则保持一致。URN 消费者更新对应 Kotlin import，URN 自身仍为 `com.urn.sdk`。

这次调整针对尚未公开发布的 Android 候选源码。npm 包名、版本、JS 的 `NativeUnifiedBridge` 模块名称、iOS Pod 和通信协议均保持不变。当前通过 `project(":aeris")` 引入 Core，不能把 Gradle group 当作已经可以从 Maven Central 下载的坐标；正式发布需另行配置仓库与发布命名空间。
