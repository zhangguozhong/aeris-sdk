import Foundation

/// 兼容 Web 物理通道封装，内部字符串始终使用统一协议。
public enum WebBridgeWire {
    public static let marker = "unifiedBridge"
    public static func decodeRequest(_ wire: String) throws -> String {
        let prefix = marker + "&"
        guard wire.hasPrefix(prefix), wire.utf8.count <= 256 * 1024 + prefix.utf8.count else {
            throw BridgeFailure("INVALID_WIRE", "Expected unifiedBridge&JSON")
        }
        return String(wire.dropFirst(prefix.count))
    }
    public static func callbackArguments(_ protocolText: String) throws -> String {
        guard protocolText.utf8.count <= 256 * 1024 else {
            throw BridgeFailure("PAYLOAD_TOO_LARGE", "Native message too large")
        }
        // JSON 数组可安全作为 JS 实参表达式，禁止将用户原始文本直接拼入引号。
        let data = try JSONSerialization.data(withJSONObject: [marker, protocolText])
        return String(decoding: data, as: UTF8.self).replacingOccurrences(
            of: "\u{2028}", with: "\\u2028"
        ).replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

/// 兼容通道使用 componentName、methodName 和 data 封装，不依赖具体宿主 SDK。
public enum UnityBridgeWire {
    public static func request(_ text: String) throws -> String {
        try encode(text, method: "receive")
    }
    public static func response(_ text: String) throws -> String {
        try encode(text, method: "onMessage")
    }
    public static func decodeRequest(_ wire: String) throws -> String {
        try decode(wire, method: "receive")
    }
    public static func decodeResponse(_ wire: String) throws -> String {
        try decode(wire, method: "onMessage")
    }
    private static func encode(_ text: String, method: String) throws -> String {
        guard text.utf8.count <= 256 * 1024 else {
            throw BridgeFailure("PAYLOAD_TOO_LARGE", "Bridge message too large")
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "componentName": "UnifiedBridge", "methodName": method, "data": ["message": text],
            ]), as: UTF8.self)
    }
    private static func decode(_ wire: String, method: String) throws -> String {
        guard wire.utf8.count <= 2 * 1024 * 1024,
            let object = try JSONSerialization.jsonObject(with: Data(wire.utf8)) as? [String: Any],
            object["componentName"] as? String == "UnifiedBridge",
            object["methodName"] as? String == method, let data = object["data"] as? [String: Any],
            let message = data["message"] as? String, message.utf8.count <= 256 * 1024
        else {
            throw BridgeFailure("INVALID_WIRE", "Expected the fixed UnifiedBridge wire envelope")
        }
        return message
    }
}
