# Android WebView host

The optional `:aeris-web` Android library depends on `:aeris` and AndroidX WebKit 1.12.1. Core and the other transports do not depend on WebKit. Minimum Android API is 24; the installed WebView must support `WEB_MESSAGE_LISTENER` and `DOCUMENT_START_SCRIPT`. Unsupported WebViews fail construction before creating a binding.

Create each endpoint on the UI thread with its own actual container and a host-owned Engine:

```kotlin
import com.aeris.sdk.BridgeEngine
import com.aeris.sdk.web.WebBridgeEndpoint

val engine = BridgeEngine.shared // 在宿主启动时注册共享业务模块
val endpoint = WebBridgeEndpoint(
    engine = engine,
    container = containerViewGroup,
    allowedHTTPSHosts = setOf("bridge.example.com"),
    allowedPermissions = setOf("camera"),
    allowedEventTopics = setOf("network.changed", "appearance.changed"),
)
containerViewGroup.addView(endpoint.webView)
endpoint.webView.loadUrl("https://bridge.example.com/app")
// Keep this endpoint for the document lifetime. Final container teardown:
endpoint.close()
containerViewGroup.removeView(endpoint.webView)
endpoint.webView.destroy()
```

Allow only exact HTTPS hostnames on the default port 443. No wildcard, HTTP, file, custom scheme, subframe or nondefault-port origins are accepted. The endpoint owns its WebViewClient; replacing that client bypasses its navigation lifecycle and is unsupported. Reload, redirect after the first document navigation, or a second document navigation permanently closes the old endpoint. Create a fresh endpoint/WebView for the next document. Detaching the original container also invalidates its UIContext and closes the connection.

The document-start script installs the existing Web Adapter entry `window.Unity.call("unifiedBridge&" + json)`. Native responses keep `WBBridgeJSConnector.Callback("unifiedBridge", json)` and all protocol fields unchanged. Native uses the originating document's `JavaScriptReplyProxy`, then the injected script invokes the fixed callback. User JSON is never interpolated into JavaScript. Endpoint close releases the listener, script, receiver and proxy; Engine failure also releases the endpoint after the terminal control message.

AndroidX documents [origin-scoped WebView message listeners](https://developer.android.com/reference/androidx/webkit/WebViewCompat#addWebMessageListener(android.webkit.WebView,java.lang.String,java.util.Set%3Cjava.lang.String%3E,androidx.webkit.WebViewCompat.WebMessageListener)) and the [per-frame JavaScriptReplyProxy relationship](https://developer.android.com/reference/androidx/webkit/JavaScriptReplyProxy). The proxy binds outbound messages to the document that initiated the handshake.

Pure JVM tests execute the real trust policy and framing code under `native/android/protocol-tests`; they do not execute a WebView.

Final local verification on 2026-10-31 successfully built Debug/Release AARs for Core, RN, Web, Flutter and Unity, and passed 56 AGP unit tests with no failures or skips (Web: 3/3). Core's three system Provider instrumentation cases also passed on an API 35 ARM64 AVD. These Provider tests cover container appearance and actual network callback registration/cleanup; they do not exercise WebView scripts, document navigation or `JavaScriptReplyProxy` delivery. Real WebView, FlutterEngine and UnityPlayer device acceptance remains pending.

Build evidence is under the repository-root directory `artifacts/android-agp-verification/`: `final-full-build.log`, `unit-results.json`, `release-aar-audit.json` and `provider-device.log`. Provider XML is under `native/android/aeris/build/outputs/androidTest-results/connected/debug/TEST-*.xml`. Six-module local Maven staging also passed: all 18 primary artifacts/POMs/sources and six Gradle metadata files were checked, with fixed `0.26.0-preview.1` coordinates and no remote publication. Its records are `artifacts/android-maven-local-agp-20261031/candidate-manifest.json` and `artifacts/android-maven-local-agp-20261031/local-verification.json`; the build log is `artifacts/android-agp-verification/maven-stage.log`. These artifacts and build reports are ignored local evidence. See [Android verification scope](../../../docs/AerisAndroid接入.md#9-验证范围) for the remaining device and CI limits.

The source build prefers `project(":aeris")`; without it, the fixed candidate dependency is `com.aeris.sdk:aeris:0.26.0-preview.1`. Consumers must configure their own audited filesystem/staging Maven repository. The optional repository-checkout `maven-publish` convention prepares `com.aeris.sdk:aeris-web:0.26.0-preview.1` in a local filesystem repository (`-PaerisMavenStagingDir=/absolute/path`); it does not upload to a public repository or establish public Maven namespace ownership.

## 真实 WebView 验收

原生宿主 `examples/web-android-host` 使用正式 Web Client/Adapter 和真实 HTTPS 文档，提供调用、事件、取消、逻辑恢复、双页隔离及导航/Renderer/关闭清理的本机验收。执行 `bash tooling/webview-android/verify.sh`；详细步骤见 [接入指南](../../../docs/WebViewAndroid接入与验收.md)。Debug 临时 CA 不进入 Release，不使用 SSL 忽略或放宽来源规则。后续不使用 GitHub CI。
