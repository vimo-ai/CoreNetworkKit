import Foundation

/// SSE 事件
///
/// 表示一个 Server-Sent Event，包含事件类型、数据、ID 等信息
public struct SSEEvent: Equatable, Sendable {
    /// 事件类型（对应 `event:` 字段，默认为 "message"）
    public let event: String

    /// 事件数据（对应 `data:` 字段）
    public let data: String

    /// 事件 ID（对应 `id:` 字段，可选）
    public let id: String?

    /// 重试间隔（对应 `retry:` 字段，可选，毫秒）
    public let retry: Int?

    public init(event: String = "message", data: String, id: String? = nil, retry: Int? = nil) {
        self.event = event
        self.data = data
        self.id = id
        self.retry = retry
    }
}

// MARK: - JSON Decoding Helper

public extension SSEEvent {
    /// 将 data 解码为指定类型
    /// - Parameter type: 目标类型
    /// - Parameter decoder: JSON 解码器
    /// - Returns: 解码后的对象
    func decode<T: Decodable>(_ type: T.Type, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard let data = data.data(using: .utf8) else {
            throw NetworkError.decodingFailed(
                NSError(domain: "SSEEvent", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid UTF-8 data"])
            )
        }
        return try decoder.decode(type, from: data)
    }
}
