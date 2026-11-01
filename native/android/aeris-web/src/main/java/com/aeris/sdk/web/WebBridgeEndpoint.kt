package com.aeris.sdk.web

import android.graphics.Bitmap
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.view.ViewGroup
import androidx.webkit.JavaScriptReplyProxy
import androidx.webkit.ScriptHandler
import androidx.webkit.WebMessageCompat
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature
import com.aeris.sdk.*

/** 可信 WebView 边界；创建、加载和关闭均在 Android UI 线程执行。 */
class WebBridgeEndpoint(
    private val engine: BridgeEngine,
    container: ViewGroup,
    allowedHTTPSHosts: Set<String>,
    allowedPermissions: Set<String> = emptySet(),
    allowedEventTopics: Set<String>? = null,
) {
    private val policy = WebEndpointPolicy(allowedHTTPSHosts)
    private val uiContext: AndroidBridgeUIContext
    val webView: WebView
    private var script: ScriptHandler? = null
    private var replyProxy: JavaScriptReplyProxy? = null
    private var transport: AerisHostBinding? = null
    private var closedObservation: BridgeCancellation? = null
    private var invalidation: BridgeCancellation? = null
    private var disposed = false

    init {
        engine.dispatcher.checkThread()
        check(WebViewFeature.isFeatureSupported(WebViewFeature.WEB_MESSAGE_LISTENER) &&
            WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            "This WebView must support origin-scoped messages and document-start injection"
        }
        uiContext = AndroidBridgeUIContext(container)
        webView = WebView(container.context)
        webView.settings.javaScriptEnabled = true
        webView.settings.allowFileAccess = false
        webView.settings.allowContentAccess = false
        val receiver = AerisHostBinding(engine.dispatcher, ::emit)
        receiver.bind(AerisBridgeReceiverFactory(engine, BridgeSource.WEB, uiContext, allowedPermissions, allowedEventTopics))
        transport = receiver
        closedObservation = receiver.observeClosed { engine.dispatcher.execute { close() } }
        WebViewCompat.addWebMessageListener(webView, OBJECT_NAME, policy.allowedOriginRules) { _, message, origin, mainFrame, proxy ->
            if (policy.acceptsMessage(origin.toString(), mainFrame) && uiContext.isValid) {
                if (message.type != WebMessageCompat.TYPE_STRING) { close() }
                else try {
                    val text = WebBridgeWire.decodeRequest(message.data ?: throw IllegalArgumentException("Expected String"))
                    replyProxy = proxy // 代理固定属于发起消息的文档，导航竞争也不会改变归属。
                    transport?.receiveMessage(text)
                } catch (_: Exception) { close() }
            }
        }
        script = WebViewCompat.addDocumentStartJavaScript(webView, """
            (function() {
              if (window !== window.top) return;
              var port = window.$OBJECT_NAME;
              port.onmessage = function(event) {
                var bridge = window.WBBridgeJSConnector;
                if (bridge && typeof bridge.Callback === 'function') bridge.Callback('unifiedBridge', event.data);
              };
              window.Unity = window.Unity || {};
              window.Unity.call = function(message) { port.postMessage(message); };
            })();
        """.trimIndent(), policy.allowedOriginRules)
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                if (!request.isForMainFrame) return false
                if (!policy.isTrusted(request.url.toString())) { close(); return true }
                return false
            }
            override fun onPageStarted(view: WebView, url: String, favicon: Bitmap?) {
                if (!policy.navigationStarted(url)) close()
            }
            override fun onRenderProcessGone(view: WebView, detail: RenderProcessGoneDetail): Boolean {
                close()
                (view.parent as? ViewGroup)?.removeView(view)
                view.destroy()
                return true
            }
        }
        invalidation = uiContext.observeInvalidation { close() }
    }
    private fun emit(text: String) {
        engine.dispatcher.checkThread()
        if (policy.closed || !uiContext.isValid) return
        try { replyProxy?.postMessage(text) } catch (_: Exception) { close() }
    }
    fun close() {
        engine.dispatcher.checkThread()
        if (disposed) return
        disposed = true
        policy.close()
        invalidation?.cancel()
        invalidation = null
        replyProxy = null
        closedObservation?.cancel()
        closedObservation = null
        transport?.close()
        transport = null
        uiContext.invalidate()
        script?.remove()
        script = null
        WebViewCompat.removeWebMessageListener(webView, OBJECT_NAME)
        webView.webViewClient = WebViewClient()
    }
    companion object { private const val OBJECT_NAME = "aerisNativeBridge" }
}
