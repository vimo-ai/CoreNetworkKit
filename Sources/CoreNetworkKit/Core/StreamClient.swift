import Foundation
import MLoggerKit

/// 流式请求客户端，用于处理 SSE (Server-Sent Events) 响应。
///
/// 主要用于 AI 流式对话场景，支持：
/// - OpenAI 兼容的 SSE 格式解析
/// - 认证策略复用
/// - 可取消的流式请求
///
/// 使用示例：
/// ```swift
/// let client = StreamClient(engine: URLSessionEngine(), tokenStorage: storage)
///
/// for try await chunk in client.stream(AICompletionRequest(prompt: "Hello")) {
///     print(chunk.content)
/// }
/// ```
public final class StreamClient {

    // MARK: - Properties

    private let session: URLSession
    private let tokenStorage: any TokenStorage
    private let jsonDecoder: JSONDecoder
    private let logger = LoggerFactory.network

    // MARK: - Initialization

    /// 初始化流式客户端
    /// - Parameters:
    ///   - configuration: URLSession 配置，默认为 `.default`
    ///   - tokenStorage: Token 存储
    ///   - jsonDecoder: JSON 解码器，可自定义解码策略
    public init(
        configuration: URLSessionConfiguration = .default,
        tokenStorage: any TokenStorage,
        jsonDecoder: JSONDecoder = JSONDecoder()
    ) {
        self.session = URLSession(configuration: configuration)
        self.tokenStorage = tokenStorage
        self.jsonDecoder = jsonDecoder
    }

    // MARK: - Public Methods

    /// 发起流式请求，返回异步序列
    /// - Parameter request: 遵循 `StreamRequest` 协议的请求
    /// - Returns: 异步抛出序列，逐个产出解码后的 Chunk
    public func stream<R: StreamRequest>(_ request: R) -> AsyncThrowingStream<R.Chunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await performStream(request, continuation: continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    /// 发起流式请求，通过回调处理每个 Chunk
    /// - Parameters:
    ///   - request: 遵循 `StreamRequest` 协议的请求
    ///   - onChunk: 每收到一个 Chunk 调用
    ///   - onComplete: 流结束时调用
    ///   - onError: 发生错误时调用
    /// - Returns: 可用于取消请求的 Task
    @discardableResult
    public func stream<R: StreamRequest>(
        _ request: R,
        onChunk: @escaping (R.Chunk) -> Void,
        onComplete: @escaping () -> Void = {},
        onError: @escaping (Error) -> Void = { _ in }
    ) -> Task<Void, Never> {
        Task {
            do {
                for try await chunk in stream(request) {
                    onChunk(chunk)
                }
                onComplete()
            } catch {
                onError(error)
            }
        }
    }

    // MARK: - Private Methods

    private func performStream<R: StreamRequest>(
        _ request: R,
        continuation: AsyncThrowingStream<R.Chunk, Error>.Continuation
    ) async throws {
        // 1. 构建 URLRequest
        let urlRequest = try buildURLRequest(from: request)

        // 2. 应用认证
        let authContext = AuthenticationContext(tokenStorage: tokenStorage)
        let authenticatedRequest = try await request.authentication.apply(to: urlRequest, context: authContext)

        logger.debug("🌊 Stream: \(authenticatedRequest.httpMethod ?? "GET") \(authenticatedRequest.url?.path ?? "")", tag: "stream")

        // 3. 发起流式请求
        let (bytes, response) = try await session.bytes(for: authenticatedRequest)

        // 4. 验证响应
        guard let httpResponse = response as? HTTPURLResponse else {
            throw StreamError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // 收集错误信息
            var errorData = Data()
            for try await byte in bytes {
                errorData.append(byte)
            }
            let errorMessage = String(data: errorData, encoding: .utf8)
            throw StreamError.serverError(statusCode: httpResponse.statusCode, message: errorMessage)
        }

        // 5. 逐行解析 SSE
        for try await line in bytes.lines {
            try Task.checkCancellation()

            // 跳过空行和非数据行
            guard line.hasPrefix(request.streamDataPrefix) else { continue }

            // 提取 JSON 数据
            let payload = line
                .dropFirst(request.streamDataPrefix.count)
                .trimmingCharacters(in: .whitespaces)

            // 检查流结束标记
            if payload == request.streamDoneMarker {
                break
            }

            // 解码 Chunk
            guard let data = payload.data(using: .utf8) else { continue }

            do {
                let chunk = try jsonDecoder.decode(R.Chunk.self, from: data)
                continuation.yield(chunk)
            } catch {
                logger.warning("Stream chunk decode failed: \(error.localizedDescription)", tag: "stream-decode")
                // 继续处理下一个 chunk，不中断流
            }
        }

        continuation.finish()
    }

    private func buildURLRequest<R: Request>(from request: R) throws -> URLRequest {
        let fullURL = request.baseURL.appendingPathComponent(request.path)
        var components = URLComponents(url: fullURL, resolvingAgainstBaseURL: false)

        if let queryParams = request.query, !queryParams.isEmpty {
            components?.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        }

        guard let url = components?.url else {
            throw StreamError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        // 设置请求头
        request.headers?.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        // 设置超时
        if let timeout = request.timeoutInterval {
            urlRequest.timeoutInterval = timeout
        }

        // 编码请求体
        if let body = request.body, !(body is EmptyBody) {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(body)
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }

        return urlRequest
    }
}

// MARK: - Stream Errors

public enum StreamError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case serverError(statusCode: Int, message: String?)
    case decodingFailed(Error)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response"
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message ?? "Unknown")"
        case .decodingFailed(let error):
            return "Decoding failed: \(error.localizedDescription)"
        case .cancelled:
            return "Stream cancelled"
        }
    }
}
