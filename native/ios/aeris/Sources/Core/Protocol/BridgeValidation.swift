import CoreFoundation
import Foundation

/// params、result 和 Provider 快照共用相对载荷根节点规则。
enum BridgePayloadValidator {
    static func valid(_ value: Any, depth: Int = 0) -> Bool {
        guard depth <= 32 else { return false }
        if value is NSNull || value is String { return true }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return true }
            let n = number.doubleValue
            return n.isFinite && (n.rounded() != n || abs(n) <= 9_007_199_254_740_991)
        }
        if let object = value as? [String: Any] {
            return object.allSatisfy { key, value in
                !["__proto__", "prototype", "constructor"].contains(key)
                    && valid(value, depth: depth + 1)
            }
        }
        if let array = value as? [Any] { return array.allSatisfy { valid($0, depth: depth + 1) } }
        return false
    }
    static func method(_ value: String) -> Bool {
        guard value.utf8.count <= 256, !value.isEmpty else { return false }
        let r = value.range(
            of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)?$", options: .regularExpression)
        return r == value.startIndex..<value.endIndex
            && !value.split(separator: ".").contains(where: {
                ["constructor", "prototype", "__proto__"].contains(String($0))
            })
    }
    static func integer(_ value: Any) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
            n.doubleValue.isFinite, n.doubleValue.rounded() == n.doubleValue, n.doubleValue >= 1,
            n.doubleValue <= 600000
        else { return nil }
        return n.intValue
    }
    static func request(_ fields: [String: Any]) -> BridgeFailure? {
        guard
            Set(fields.keys).isSubset(of: ["callbackId", "method", "params", "extra", "timeoutMs"])
        else { return BridgeFailure("INVALID_ARGUMENT", "Unknown request field") }
        guard let method = fields["method"] as? String, Self.method(method) else {
            return BridgeFailure("INVALID_METHOD", "Invalid method")
        }
        guard let params = fields["params"] as? [String: Any], valid(params) else {
            return BridgeFailure("INVALID_ARGUMENT", "Invalid params")
        }
        if let value = fields["timeoutMs"], integer(value) == nil {
            return BridgeFailure("INVALID_ARGUMENT", "Invalid timeoutMs")
        }
        if let value = fields["extra"] {
            guard let extra = value as? String else {
                return BridgeFailure("INVALID_ARGUMENT", "extra must be string")
            }
            guard BridgeCodec.extraFitsResponse(extra) else {
                return BridgeFailure("PAYLOAD_TOO_LARGE", "extra leaves no response headroom")
            }
        }
        // 直接构造的 Session 绕过 Codec，分发前也必须校验整个语义封装的边界。
        guard JSONSerialization.isValidJSONObject(fields),
            let size = try? JSONSerialization.data(
                withJSONObject: fields, options: [.withoutEscapingSlashes]
            ).count, size <= 256 * 1024
        else { return BridgeFailure("PAYLOAD_TOO_LARGE", "Request too large") }
        return nil
    }
}

/// 转换为 Foundation 对象之前，严格校验语法、解码后的重复键和 Unicode。
/// 容器按绝对层数计数，根为 1，与业务载荷的相对深度独立。
struct BridgeJSONScanner {
    let bytes: [UInt8]
    var i = 0
    init(_ raw: String) { bytes = Array(raw.utf8) }
    mutating func validate() throws {
        space()
        guard peek == 123 else { throw invalid }
        try object(depth: 1)
        space()
        guard i == bytes.count else { throw invalid }
    }
    private var invalid: BridgeFailure { BridgeFailure("PROTOCOL_ERROR", "Invalid JSON envelope") }
    private var peek: UInt8? { i < bytes.count ? bytes[i] : nil }
    private mutating func space() { while let b = peek, [9, 10, 13, 32].contains(b) { i += 1 } }
    private mutating func take(_ b: UInt8) throws {
        guard peek == b else { throw invalid }
        i += 1
    }
    private mutating func value(depth: Int) throws {
        space()
        guard let b = peek else { throw invalid }
        switch b {
        case 123: try object(depth: depth)
        case 91:
            guard depth <= 64 else { throw invalid }
            i += 1
            space()
            if peek == 93 {
                i += 1
                return
            }
            while true {
                try value(depth: depth + 1)
                space()
                if peek == 93 {
                    i += 1
                    return
                }
                try take(44)
            }
        case 34: _ = try string()
        case 116: try literal(Array("true".utf8))
        case 102: try literal(Array("false".utf8))
        case 110: try literal(Array("null".utf8))
        default: try number()
        }
    }
    private mutating func object(depth: Int) throws {
        guard depth <= 64 else { throw invalid }
        try take(123)
        space()
        if peek == 125 {
            i += 1
            return
        }
        var keys = Set<String>()
        while true {
            space()
            let key = try string()
            guard keys.insert(key).inserted else { throw invalid }
            space()
            try take(58)
            try value(depth: depth + 1)
            space()
            if peek == 125 {
                i += 1
                return
            }
            try take(44)
        }
    }
    private mutating func literal(_ expected: [UInt8]) throws { for b in expected { try take(b) } }
    private mutating func hex() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let b = peek else { throw invalid }
            i += 1
            let digit: UInt32
            switch b {
            case 48...57: digit = UInt32(b - 48)
            case 65...70: digit = UInt32(b - 55)
            case 97...102: digit = UInt32(b - 87)
            default: throw invalid
            }
            value = value * 16 + digit
        }
        return value
    }
    private mutating func string() throws -> String {
        try take(34)
        var output: [UInt8] = []
        while let b = peek {
            i += 1
            if b == 34 {
                guard let text = String(bytes: output, encoding: .utf8) else { throw invalid }
                return text
            }
            guard b >= 32 else { throw invalid }
            if b != 92 {
                output.append(b)
                continue
            }
            guard let escape = peek else { throw invalid }
            i += 1
            switch escape {
            case 34, 92, 47: output.append(escape)
            case 98: output.append(8)
            case 102: output.append(12)
            case 110: output.append(10)
            case 114: output.append(13)
            case 116: output.append(9)
            case 117:
                var scalar = try hex()
                if (0xD800...0xDBFF).contains(scalar) {
                    try take(92)
                    try take(117)
                    let low = try hex()
                    guard (0xDC00...0xDFFF).contains(low) else { throw invalid }
                    scalar = 0x10000 + (scalar - 0xD800) * 1024 + (low - 0xDC00)
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    throw invalid
                }
                guard let unicode = UnicodeScalar(scalar) else { throw invalid }
                output.append(contentsOf: String(unicode).utf8)
            default: throw invalid
            }
        }
        throw invalid
    }
    private mutating func number() throws {
        if peek == 45 { i += 1 }
        guard let first = peek else { throw invalid }
        if first == 48 {
            i += 1
        } else {
            guard (49...57).contains(first) else { throw invalid }
            i += 1
            digits()
        }
        if peek == 46 {
            i += 1
            guard let b = peek, (48...57).contains(b) else { throw invalid }
            digits()
        }
        if peek == 101 || peek == 69 {
            i += 1
            if peek == 43 || peek == 45 { i += 1 }
            guard let b = peek, (48...57).contains(b) else { throw invalid }
            digits()
        }
    }
    private mutating func digits() { while let b = peek, (48...57).contains(b) { i += 1 } }
}
