import Foundation
import MLoggerKit

/// 网络客户端 - 统一入口
///
/// 提供统一的网络请求接口，支持：
/// - 单请求执行（简单 / 链式配置）
/// - SSE 流式请求
/// - DAG 编排
/// - 批量请求
/// - 轮询调度
///
/// 使用示例：
/// ```swift
/// let client = NetworkClient(
///     engine: AlamofireEngine(),
///     tokenStorage: MyTokenStorage(),
///     tokenRefresher: MyTokenRefresher()
/// )
///
/// // 简单请求（推荐，80% 场景）
/// let user = try await client.send(GetUserRequest(id: "123"))
///
/// // 需要配置时，使用链式 API
/// let user = try await client.request(GetUserRequest(id: "123"))
///     .cache(.cacheFirst(maxAge: 60))
///     .retry(.exponential(maxAttempts: 3))
///     .execute()
///
/// // SSE 流式请求（AI 对话等场景）
/// let stream = try await client.stream(ChatRequest(message: "Hello"))
/// for try await event in stream {
///     print(event.data)
/// }
///
/// // 批量请求
/// let users = try await client.batch([
///     GetUserRequest(id: "1"),
///     GetUserRequest(id: "2")
/// ])
///
/// // DAG 编排
/// let (user, config) = try await client.orchestrate {
///     ("user", OrchestratorNode(request: GetUserRequest()))
///     ("config", OrchestratorNode(request: GetConfigRequest()))
/// }
///
/// // 轮询
/// client.poll(every: 5) { GetOrderStatusRequest(orderId: orderId) }
///     .onUpdate { status in print("Status: \(status)") }
///     .start()
/// ```
public final class NetworkClient {
    private let logger = LoggerFactory.network

    // MARK: - Dependencies

    private let engine: NetworkEngine
    private let executor: TaskExecutor
    private let orchestrator: Orchestrator
    private let tokenStorage: TokenStorage
    private let authContext: AuthenticationContext

    /// 自定义 JSON 解码器
    public let jsonDecoder: JSONDecoder

    /// 用户反馈处理器（用于 Vimo 业务错误时显示 toast）
    public let userFeedbackHandler: UserFeedbackHandler?

    // MARK: - Initialization

    /// 创建网络客户端
    /// - Parameters:
    ///   - engine: 网络引擎，默认为 AlamofireEngine
    ///   - tokenStorage: Token 存储
    ///   - tokenRefresher: Token 刷新器（可选）
    ///   - jsonDecoder: 自定义 JSON 解码器（可选，默认使用标准解码器）
    ///   - userFeedbackHandler: 用户反馈处理器（可选，用于业务错误时显示 toast）
    public init(
        engine: NetworkEngine,
        tokenStorage: TokenStorage,
        tokenRefresher: TokenRefresher? = nil,
        jsonDecoder: JSONDecoder = JSONDecoder(),
        userFeedbackHandler: UserFeedbackHandler? = nil
    ) {
        self.engine = engine
        self.tokenStorage = tokenStorage
        self.authContext = AuthenticationContext(tokenStorage: tokenStorage)
        self.executor = TaskExecutor(
            engine: engine,
            tokenStorage: tokenStorage,
            tokenRefresher: tokenRefresher
        )
        self.orchestrator = Orchestrator(executor: executor)
        self.jsonDecoder = jsonDecoder
        self.userFeedbackHandler = userFeedbackHandler
    }

    // MARK: - Single Request

    /// 发送请求（便捷方法）
    ///
    /// 最简单的请求方式，适用于不需要额外配置的场景：
    /// ```swift
    /// let user = try await client.send(GetUserRequest(id: "123"))
    /// ```
    ///
    /// - Parameter request: Request 对象
    /// - Returns: 解码后的响应
    /// - Throws: NetworkError 或 VimoBusinessError
    public func send<R: Request>(_ request: R) async throws -> R.Response {
        return try await self.request(request).execute()
    }

    /// 发起单个请求（链式配置）
    ///
    /// 需要配置缓存、重试等高级功能时使用：
    /// ```swift
    /// let user = try await client.request(GetUserRequest(id: "123"))
    ///     .cache(.cacheFirst(maxAge: 60))
    ///     .retry(.exponential(maxAttempts: 3))
    ///     .execute()
    /// ```
    ///
    /// - Parameter request: Request 对象
    /// - Returns: RequestBuilder，支持链式配置
    public func request<R: Request>(_ request: R) -> RequestBuilder<R> {
        return RequestBuilder(
            request: request,
            executor: executor,
            authContext: authContext,
            jsonDecoder: jsonDecoder,
            userFeedbackHandler: userFeedbackHandler
        )
    }

    // MARK: - DAG Orchestration

    /// DAG 编排
    /// - Parameters:
    ///   - failureStrategy: 失败策略，默认为 failFast
    ///   - builder: 编排构建器
    /// - Returns: 编排结果
    /// - Throws: NetworkError
    public func orchestrate<T>(
        onFailure failureStrategy: FailureStrategy = .failFast,
        @OrchestratorBuilder builder: () -> OrchestratorPlan<T>
    ) async throws -> T {
        let rawPlan = builder()
        // 将原始节点转换为可执行节点（注入 executor 和 authContext）
        let plan = rawPlan.withExecutor(executor, authContext: authContext)
        return try await orchestrator.execute(plan: plan, failureStrategy: failureStrategy)
    }

    // MARK: - Batch Requests

    /// 批量请求（并发执行）
    /// - Parameter requests: 请求列表
    /// - Returns: 响应列表（顺序与请求列表一致）
    /// - Throws: NetworkError（任何一个请求失败都会抛出错误）
    public func batch<R: Request>(_ requests: [R]) async throws -> [R.Response] {
        logger.debug("[NetworkClient] Batch request with \(requests.count) items")

        return try await withThrowingTaskGroup(of: (Int, R.Response).self) { group in
            // 并发执行所有请求
            for (index, request) in requests.enumerated() {
                group.addTask {
                    let response = try await self.request(request).execute()
                    return (index, response)
                }
            }

            // 收集结果，按原始顺序排序
            var results: [(Int, R.Response)] = []
            for try await result in group {
                results.append(result)
            }

            results.sort { $0.0 < $1.0 }
            return results.map { $0.1 }
        }
    }

    /// 批量请求（继续执行模式，失败不影响其他请求）
    /// - Parameter requests: 请求列表
    /// - Returns: 结果列表（成功返回 .success，失败返回 .failure）
    public func batchWithResults<R: Request>(_ requests: [R]) async -> [Result<R.Response, Error>] {
        logger.debug("[NetworkClient] Batch request (continueOnError) with \(requests.count) items")

        return await withTaskGroup(of: (Int, Result<R.Response, Error>).self) { group in
            // 并发执行所有请求
            for (index, request) in requests.enumerated() {
                group.addTask {
                    do {
                        let response = try await self.request(request).execute()
                        return (index, .success(response))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }

            // 收集结果，按原始顺序排序
            var results: [(Int, Result<R.Response, Error>)] = []
            for await result in group {
                results.append(result)
            }

            results.sort { $0.0 < $1.0 }
            return results.map { $0.1 }
        }
    }

    // MARK: - Polling

    /// 创建轮询器
    /// - Parameters:
    ///   - interval: 轮询间隔（秒）
    ///   - request: 请求生成函数
    /// - Returns: 轮询器，需要手动调用 start() 启动
    public func poll<R: Request>(
        every interval: TimeInterval,
        request: @escaping () -> R
    ) -> Poller<R.Response> {
        let requestFn: () async throws -> R.Response = {
            try await self.request(request()).execute()
        }

        return Poller(interval: interval, request: requestFn)
    }

    // MARK: - Lifecycle Management

    /// 创建与生命周期绑定的请求
    /// - Parameters:
    ///   - owner: 生命周期拥有者
    ///   - request: Request 对象
    /// - Returns: RequestBuilder
    public func request<R: Request>(
        lifecycle owner: AnyObject,
        _ request: R
    ) -> RequestBuilder<R> {
        return self.request(request).lifecycle(.view(owner: owner))
    }

    // MARK: - SSE Streaming

    /// 发起 SSE 流式请求（原始事件流）
    ///
    /// 返回 SSE 事件流，适用于需要处理原始事件的场景：
    /// ```swift
    /// let stream = try await client.stream(ChatStreamRequest(message: "Hello"))
    /// for try await event in stream {
    ///     print("Event: \(event.event), Data: \(event.data)")
    /// }
    /// ```
    ///
    /// - Parameter request: Request 对象
    /// - Returns: SSE 事件流
    public func stream<R: Request>(_ request: R) async throws -> SSEStream {
        let urlRequest = try await buildStreamRequest(request)
        let dataStream = engine.streamRequest(urlRequest)
        return SSEStream(dataStream: dataStream)
    }

    /// 发起 SSE 流式请求（类型化事件流）
    ///
    /// 自动将 SSE data 解码为指定类型：
    /// ```swift
    /// let stream: TypedSSEStream<ChatChunk> = try await client.stream(ChatStreamRequest(message: "Hello"))
    /// for try await chunk in stream {
    ///     print(chunk.text)
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - request: Request 对象
    ///   - type: 响应数据类型
    /// - Returns: 类型化 SSE 事件流
    public func stream<R: Request, T: Decodable>(
        _ request: R,
        as type: T.Type
    ) async throws -> TypedSSEStream<T> {
        let urlRequest = try await buildStreamRequest(request)
        let dataStream = engine.streamRequest(urlRequest)
        return TypedSSEStream<T>(dataStream: dataStream, decoder: jsonDecoder)
    }

    // MARK: - Private Helpers

    /// 构建流式请求的 URLRequest
    private func buildStreamRequest<R: Request>(_ request: R) async throws -> URLRequest {
        // 构建 URL
        var components = URLComponents()
        components.scheme = request.baseURL.scheme
        components.host = request.baseURL.host
        components.port = request.baseURL.port

        let basePath = request.baseURL.path
        let requestPath = request.path
        if basePath.hasSuffix("/") || requestPath.hasPrefix("/") {
            components.path = basePath + requestPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            components.path = basePath + "/" + requestPath
        }

        if let query = request.query, !query.isEmpty {
            components.queryItems = query.map { key, value in
                URLQueryItem(name: key, value: "\(value)")
            }
        }

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        // 设置 SSE 相关头
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        urlRequest.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        // 设置自定义头
        if let headers = request.headers {
            for (key, value) in headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        // 设置请求体
        if let body = request.body {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(body)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        // 应用认证
        urlRequest = try await request.authentication.apply(to: urlRequest, context: authContext)

        return urlRequest
    }
}

// MARK: - Convenience Extensions

extension NetworkClient {
    /// 创建批量加载器
    /// - Parameters:
    ///   - maxBatchSize: 最大批量大小
    ///   - maxWaitTime: 最大等待时间（秒）
    ///   - batchFn: 批量加载函数
    /// - Returns: BatchLoader
    public func createBatchLoader<Key: Hashable, Value>(
        maxBatchSize: Int = 50,
        maxWaitTime: TimeInterval = 0.05,
        batchFn: @escaping ([Key]) async throws -> [Key: Value]
    ) -> BatchLoader<Key, Value> {
        return BatchLoader(
            maxBatchSize: maxBatchSize,
            maxWaitTime: maxWaitTime,
            batchFn: batchFn
        )
    }
}
