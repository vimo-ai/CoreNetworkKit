import Foundation

/// 定义一个流式请求所需的所有基本元素（SSE/Server-Sent Events）。
///
/// 继承自 `Request` 协议，额外定义流式响应的解析规则。
/// 主要用于 AI 流式对话等场景。
///
/// 使用示例：
/// ```swift
/// struct AICompletionRequest: StreamRequest {
///     typealias Response = AICompletionResponse  // 完整响应（可选）
///     typealias Chunk = AICompletionChunk        // 流式块
///
///     var baseURL: URL { URL(string: "https://api.example.com")! }
///     var path: String { "/v1/chat/completions" }
///     var method: HTTPMethod { .post }
///     var body: RequestBody? { RequestBody(messages: messages, stream: true) }
/// }
/// ```
public protocol StreamRequest: Request {
    /// 流式响应中每个数据块的类型
    associatedtype Chunk: Decodable

    /// SSE 数据行前缀，默认为 "data:"
    /// 用于从 SSE 格式中提取 JSON 数据
    var streamDataPrefix: String { get }

    /// 流结束标记，默认为 "[DONE]"
    /// 当收到此标记时，流式传输结束
    var streamDoneMarker: String { get }
}

// MARK: - 默认实现

public extension StreamRequest {
    /// 默认 SSE 数据前缀（OpenAI 兼容格式）
    var streamDataPrefix: String { "data:" }

    /// 默认流结束标记（OpenAI 兼容格式）
    var streamDoneMarker: String { "[DONE]" }
}
