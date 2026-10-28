import Foundation

/// 内部不可变输出，Connection 原样转发文本，实际发送仍由 Transport 负责。
struct BridgePreparedResponse {
    let text: String
    let finished: Bool
    let requiresCleanup: Bool
    let callbackId: String?
    init(text: String, finished: Bool, requiresCleanup: Bool, callbackId: String? = nil) {
        self.text = text
        self.finished = finished
        self.requiresCleanup = requiresCleanup
        self.callbackId = callbackId
    }
}

/// 业务响应和系统响应的统一准备入口，EventHub 快照另行处理。
@MainActor final class BridgeResponseEncoder {
    private let encode: ([String: Any]) throws -> String
    init(encode: @escaping ([String: Any]) throws -> String = BridgeCodec.encode) {
        self.encode = encode
    }

    func prepare(
        callbackId: String, seq: Int, finished: Bool?, extra: String?,
        result: Result<[String: Any], BridgeFailure>
    ) throws -> BridgePreparedResponse {
        var envelope: [String: Any] = ["callbackId": callbackId, "seq": seq]
        envelope["finished"] = finished ?? true
        if let extra { envelope["extra"] = extra }
        func failure(_ error: BridgeFailure) throws -> BridgePreparedResponse {
            envelope.removeValue(forKey: "result")
            envelope["error"] = ["code": error.code, "message": error.message]
            envelope["finished"] = true
            return BridgePreparedResponse(
                text: try encode(envelope), finished: true, requiresCleanup: true,
                callbackId: callbackId)
        }
        switch result {
        case .success(let value):
            guard BridgePayloadValidator.valid(value) else {
                return try failure(BridgeFailure("INTERNAL_ERROR", "Invalid native result"))
            }
            envelope["result"] = value
        case .failure(let error):
            guard !error.code.isEmpty, error.code.utf16.count <= 128, !error.message.isEmpty,
                error.message.utf16.count <= 4096
            else {
                return try failure(BridgeFailure("INTERNAL_ERROR", "Invalid native error response"))
            }
            envelope["error"] = ["code": error.code, "message": error.message]
            envelope["finished"] = true
        }
        do {
            return BridgePreparedResponse(
                text: try encode(envelope), finished: envelope["finished"] as? Bool ?? true,
                requiresCleanup: false, callbackId: callbackId)
        } catch {
            let code =
                (error as? BridgeFailure)?.code == "PAYLOAD_TOO_LARGE"
                ? "PAYLOAD_TOO_LARGE" : "INTERNAL_ERROR"
            // 候选回包过大时，需要再次编码有界的结束兜底响应。
            return try failure(
                BridgeFailure(
                    code,
                    code == "PAYLOAD_TOO_LARGE"
                        ? "Response too large" : "Native response encoding failed"))
        }
    }
}
