package com.aeris.sdk

import com.google.gson.Gson

/** 仅处理旧版 Web 物理通道封装，JSON 协议内容保持不变。 */
object WebBridgeWire {
    const val MARKER = "unifiedBridge"
    fun decodeRequest(wire: String): String {
        val prefix = "$MARKER&"
        if (!wire.startsWith(prefix) || BridgeCodec.size(wire) > BridgeCodec.MAX_BYTES + prefix.length)
            throw BridgeFailure("INVALID_WIRE", "Expected unifiedBridge&JSON")
        return wire.substring(prefix.length)
    }
    fun callbackArguments(text: String): String {
        if (BridgeCodec.size(text) > BridgeCodec.MAX_BYTES) throw BridgeFailure("PAYLOAD_TOO_LARGE", "Native message too large")
        return Gson().toJson(listOf(MARKER, text)).replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")
    }
}
