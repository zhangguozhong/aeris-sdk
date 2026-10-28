import Foundation

public enum BridgeCodec {
    public static func decode(_ raw: String) throws -> BridgeMessage {
        guard raw.utf8.count <= 256 * 1024 else {
            throw BridgeFailure("PROTOCOL_ERROR", "Message too large")
        }
        var scanner = BridgeJSONScanner(raw)
        try scanner.validate()
        guard
            let fields = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
            fields["method"] is String
        else { throw BridgeFailure("PROTOCOL_ERROR", "Expected a method envelope") }
        return BridgeMessage(fields: fields)
    }
    // 为 callbackId 和有界兜底错误预留 1 KiB，以编码后的 JSON 字节数计量。
    static func extraFitsResponse(_ extra: String) -> Bool {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: ["extra": extra], options: [.withoutEscapingSlashes])
        else { return false }
        return data.count <= 255 * 1024
    }
    static func encode(_ fields: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: fields, options: [.withoutEscapingSlashes])
        guard data.count <= 256 * 1024, let text = String(data: data, encoding: .utf8) else {
            throw BridgeFailure("PAYLOAD_TOO_LARGE", "Invalid outbound envelope")
        }
        return text
    }
}
