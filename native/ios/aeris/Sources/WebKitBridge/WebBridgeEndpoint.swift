#if canImport(UIKit) && canImport(WebKit)
    import UIKit
    import WebKit

    @MainActor private final class WeakWebMessageHandler: NSObject, WKScriptMessageHandler {
        weak var endpoint: WebBridgeEndpoint?
        init(_ endpoint: WebBridgeEndpoint) { self.endpoint = endpoint }
        func userContentController(
            _ userContentController: WKUserContentController, didReceive message: WKScriptMessage
        ) { endpoint?.receive(message) }
    }

    /// 每个文档或容器独立绑定；重新加载或打开新文档时创建新的 Endpoint/WebView。
    @MainActor public final class WebBridgeEndpoint: NSObject, WKNavigationDelegate {
        public let webView: WKWebView
        private let uiContext: BridgeUIContext
        private let engine: BridgeEngine
        private let allowedHosts: Set<String>
        private var transport: AerisWebNativeTransport?
        private var closed = false
        private var hasStartedNavigation = false

        public init(
            engine: BridgeEngine, containerViewController: UIViewController,
            allowedHTTPSHosts: Set<String>, allowedPermissions: Set<String> = [],
            allowedEventTopics: Set<String>? = nil
        ) {
            precondition(!allowedHTTPSHosts.isEmpty)
            uiContext = BridgeUIContext(containerViewController: containerViewController)
            self.engine = engine
            allowedHosts = Set(allowedHTTPSHosts.map { $0.lowercased() })
            let configuration = WKWebViewConfiguration()
            webView = WKWebView(frame: .zero, configuration: configuration)
            super.init()
            let controller = configuration.userContentController
            controller.add(WeakWebMessageHandler(self), name: "webViewBridge")
            controller.addUserScript(
                WKUserScript(
                    source: """
                        window.Unity = window.Unity || {};
                        window.Unity.call = function(message) {
                          window.webkit.messageHandlers.webViewBridge.postMessage(message);
                        };
                        """, injectionTime: .atDocumentStart, forMainFrameOnly: true))
            webView.navigationDelegate = self
            transport = AerisWebNativeTransport(
                engine: engine, allowedPermissions: allowedPermissions,
                allowedEventTopics: allowedEventTopics,
                uiContextProvider: { [weak self] in self?.uiContext }
            ) { [weak self] text in self?.emit(text) }
        }
        fileprivate func receive(_ message: WKScriptMessage) {
            guard !closed, message.name == "webViewBridge", message.frameInfo.isMainFrame else {
                return
            }
            let origin = message.frameInfo.securityOrigin
            guard origin.protocol == "https", allowedHosts.contains(origin.host.lowercased()),
                origin.port == 0 || origin.port == 443, let wire = message.body as? String
            else { return }
            do { transport?.receiveMessage(try WebBridgeWire.decodeRequest(wire)) } catch {
                close()
            }
        }
        private func emit(_ text: String) {
            guard !closed, let args = try? WebBridgeWire.callbackArguments(text) else { return }
            let script = """
                (function(args) {
                  var bridge=window.WBBridgeJSConnector;
                  if (!bridge || typeof bridge.Callback !== 'function') throw new Error('Bridge receiver unavailable');
                  bridge.Callback.apply(bridge,args);
                })(\(args));
                """
            webView.evaluateJavaScript(script) { [weak self] _, error in
                if error != nil { self?.close() }
            }
        }
        public func webView(
            _ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?
        ) { if hasStartedNavigation { close() } else { hasStartedNavigation = true } }
        public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { close() }
        public func close() {
            guard !closed else { return }
            closed = true
            transport?.close()
            transport = nil
            uiContext.invalidate()
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: "webViewBridge")
            webView.navigationDelegate = nil
        }
    }

#endif
