package com.aeris.sdk.web

import java.net.URI
import java.util.Locale

/** 每个绑定仅属于一个文档；重新加载或导航时创建新的 Endpoint 和 WebView。 */
class WebEndpointPolicy(allowedHTTPSHosts: Set<String>) {
    val allowedOriginRules: Set<String>
    private val hosts = allowedHTTPSHosts.map { it.lowercase(Locale.ROOT) }.toSet()
    private var navigated = false
    var closed = false
        private set
    init {
        require(hosts.isNotEmpty() && hosts.all { host ->
            host.length <= 253 && host.split('.').all { it.matches(Regex("[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?")) }
        }) { "Supply exact HTTPS hostnames without scheme, path, wildcard or port" }
        allowedOriginRules = hosts.map { "https://$it" }.toSet()
    }
    fun isTrusted(url: String): Boolean = runCatching {
        val origin = URI(url)
        origin.scheme?.lowercase(Locale.ROOT) == "https" && origin.host?.lowercase(Locale.ROOT) in hosts &&
            origin.port in setOf(-1, 443) && origin.rawUserInfo == null
    }.getOrDefault(false)
    fun acceptsMessage(origin: String, mainFrame: Boolean) = !closed && mainFrame && isTrusted(origin)
    fun navigationStarted(url: String): Boolean {
        if (closed || navigated || !isTrusted(url)) { close(); return false }
        navigated = true
        return true
    }
    fun close() { closed = true }
}
