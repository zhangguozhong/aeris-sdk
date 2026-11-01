# Aeris Unity Android 宿主连接

`:aeris-unity` 包装 Core 的 `AerisUnityNativeTransport`，按容器注入 UIContext、权限与 topic 白名单。用法、独立工厂接口、卸载顺序和测试边界见 [`packages/unity/Plugins/Android/README.md`](../../../packages/unity/Plugins/Android/README.md)。

Gradle 需要注册 `:aeris-unity`（本目录）及 `:aeris-unity-channel`（`channel/`）。宿主模块对通道模块仅 `compileOnly`；最终应用通过导出的 UnityLibrary 提供通用 Java 类，禁止额外 runtime 链接通道 JAR，避免重复类。`:aeris-unity-channel:jar` 只用于宿主编译契约，不是运行时分发依赖。


## 验证状态（2026-10-31）

最终本机实际 AGP 已通过 Core、RN、Web、Flutter、Unity 五模块的 Debug/Release AAR 构建，以及 56 项单元测试（Core 41、Web 3、RN 6、Flutter 6，零失败/跳过）。Unity 模块的 Gradle 测试目标为 `NO-SOURCE`，不计入这 56 项；其通用 Java 生命周期、C# Wire/Core、导出处理与真实 Unity API 程序集编译由仓库的 `tests/packaging/unity_android_plugin_test.py` 独立验证。日志和汇总位于仓库根目录下的 `artifacts/android-agp-verification/`：`final-full-build.log`、`unit-results.json`、`release-aar-audit.json`。

六模块固定 `0.26.0-preview.1` 的本地 Maven staging 已完成，18 个 AAR/JAR、sources、POM 齐全，并核对 6 份 Gradle metadata。Unity POM 与 API/runtime metadata 都没有 `aeris-unity-channel` 依赖，宿主 AAR 没有打入 `com/aeris/unity/` 通用通道类；独立 channel JAR 包含通道实现及同源 Java sources。记录为 `artifacts/android-maven-local-agp-20261031/candidate-manifest.json`、`artifacts/android-maven-local-agp-20261031/local-verification.json`，日志为 `artifacts/android-agp-verification/maven-stage.log`；没有远程发布。

Core Provider 已在 API 35 ARM64 AVD 上通过 3/3 设备测试，结果在 `native/android/aeris/build/outputs/androidTest-results/connected/debug/TEST-*.xml` 与 `artifacts/android-agp-verification/provider-device.log`。以上是前轮基础模块证据，不代表Player运行。当前真正Unity Android IL2CPP Player的调用、事件、取消、双通道隔离、暂停恢复和卸载验收已另行补齐，见[Unity完整指南](../../../docs/UnityAndroid接入与验收.md)；FlutterEngine和WebView也有独立真实App记录。上述证据是本机生成的 ignored 文件，完整边界见[Android 接入第 9 章](../../../docs/AerisAndroid接入.md#9-验证范围)。
