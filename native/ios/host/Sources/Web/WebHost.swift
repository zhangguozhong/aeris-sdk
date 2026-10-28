import Aeris
import UIKit
import WebKit

/// 每个文档独立持有；页面加载与路由由 App 决定。
@MainActor public final class WebHost {
    public let endpoint: WebBridgeEndpoint
    public var webView: WKWebView { endpoint.webView }

    public init(
        configuration: AerisHostConfiguration, containerViewController: UIViewController,
        allowedHTTPSHosts: Set<String>
    ) {
        endpoint = WebBridgeEndpoint(
            engine: configuration.engine, containerViewController: containerViewController,
            allowedHTTPSHosts: allowedHTTPSHosts,
            allowedPermissions: configuration.allowedPermissions,
            allowedEventTopics: configuration.allowedEventTopics)
    }

    public func close() { endpoint.close() }
}
