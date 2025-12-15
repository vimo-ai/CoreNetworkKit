import Foundation

/// 请求构建器
///
/// 提供链式 API 构建和执行网络请求：
/// - 支持灵活配置生命周期、控制策略、缓存、重试等
/// - 提供类型安全的请求执行
///
/// 使用示例：
/// ```swift
/// let user = try await RequestBuilder(request: GetUserRequest(id: "123"))
///     .lifecycle(.view(owner: self))
///     .cache(.cacheFirst(maxAge: 60))
///     .retry(.exponential(maxAttempts: 3, initialDelay: 1, multiplier: 2))
///     .execute()
/// ```
public final class RequestBuilder<R: Request> {
    private let request: R
    private var config: TaskConfig

    // MARK: - Dependencies (需要外部注入)

    private let executor: TaskExecutor
    private let authContext: AuthenticationContext
    private let jsonDecoder: JSONDecoder
    private let userFeedbackHandler: UserFeedbackHandler?

    // MARK: - Initialization

    /// 创建请求构建器
    /// - Parameters:
    ///   - request: Request 对象
    ///   - executor: 任务执行器
    ///   - authContext: 认证上下文
    ///   - jsonDecoder: JSON 解码器
    ///   - userFeedbackHandler: 用户反馈处理器（可选）
    public init(
        request: R,
        executor: TaskExecutor,
        authContext: AuthenticationContext,
        jsonDecoder: JSONDecoder = JSONDecoder(),
        userFeedbackHandler: UserFeedbackHandler? = nil
    ) {
        self.request = request
        self.config = TaskConfig()
        self.executor = executor
        self.authContext = authContext
        self.jsonDecoder = jsonDecoder
        self.userFeedbackHandler = userFeedbackHandler
    }

    // MARK: - Configuration Methods

    /// 设置生命周期
    @discardableResult
    public func lifecycle(_ lifecycle: Lifecycle) -> Self {
        config.lifecycle = lifecycle
        return self
    }

    /// 设置防抖
    @discardableResult
    public func debounce(_ interval: TimeInterval) -> Self {
        config.control.debounce = interval
        return self
    }

    /// 设置节流
    @discardableResult
    public func throttle(_ interval: TimeInterval) -> Self {
        config.control.throttle = interval
        return self
    }

    /// 设置去重
    @discardableResult
    public func deduplicate() -> Self {
        config.control.deduplicate = true
        return self
    }

    /// 设置优先级
    @discardableResult
    public func priority(_ priority: ControlPolicy.Priority) -> Self {
        config.control.priority = priority
        return self
    }

    /// 设置缓存策略
    @discardableResult
    public func cache(_ policy: CachePolicy) -> Self {
        config.cache = policy
        return self
    }

    /// 设置重试策略
    @discardableResult
    public func retry(_ policy: RetryPolicy) -> Self {
        config.retry = policy
        return self
    }

    /// 设置单次请求超时
    @discardableResult
    public func timeout(_ interval: TimeInterval) -> Self {
        config.timeout = interval
        return self
    }

    /// 设置整体超时（包含所有重试）
    @discardableResult
    public func totalTimeout(_ interval: TimeInterval) -> Self {
        config.totalTimeout = interval
        return self
    }

    // MARK: - Execution

    /// 执行请求
    /// - Returns: 解码后的响应对象
    /// - Throws: NetworkError
    public func execute() async throws -> R.Response {
        return try await executeWithLifecycle()
    }

    // MARK: - Private Methods

    /// 构建 URLRequest
    private func buildURLRequest() async throws -> URLRequest {
        // 1. 构建 URL
        var components = URLComponents()
        components.scheme = request.baseURL.scheme
        components.host = request.baseURL.host
        components.port = request.baseURL.port

        // 组合路径（使用与 APIClient 相同的方式）
        let fullURL = request.baseURL.appendingPathComponent(request.path)
        components.path = fullURL.path

        // 添加查询参数
        if let query = request.query, !query.isEmpty {
            components.queryItems = query.map { key, value in
                URLQueryItem(name: key, value: "\(value)")
            }
        }

        guard let url = components.url else {
            throw NetworkError.invalidURL
        }

        // 2. 创建 URLRequest
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue

        // 设置超时
        if let timeout = request.timeoutInterval {
            urlRequest.timeoutInterval = timeout
        }

        // 3. 设置请求头
        if let headers = request.headers {
            for (key, value) in headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        // 4. 设置请求体
        // 对于 POST/PUT/PATCH/DELETE 请求，如果设置了 Content-Type: application/json 但没有 body，
        // 需要发送空 JSON 对象 {}，否则某些后端框架（如 NestJS）会报错
        if let body = request.body {
            let encoder = JSONEncoder()
            urlRequest.httpBody = try encoder.encode(body)
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        } else if request.method == .post || request.method == .put || request.method == .patch || request.method == .delete {
            // body 为 nil，但如果设置了 Content-Type: application/json，需要发送空对象
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == "application/json" {
                urlRequest.httpBody = Data("{}".utf8)
            }
        }

        // 5. 应用认证
        urlRequest = try await request.authentication.apply(to: urlRequest, context: authContext)

        return urlRequest
    }

    /// 解码响应
    private func decodeResponse(data: Data) throws -> R.Response {
        do {
            // 检查是否为 VimoRequest，需要解包
            if request is any VimoRequest {
                return try decodeVimoResponse(data: data)
            } else {
                // 普通请求，直接解码
                return try jsonDecoder.decode(R.Response.self, from: data)
            }
        } catch let error as VimoBusinessError {
            // Vimo 业务错误，显示 toast 后重新抛出
            userFeedbackHandler?.showError(message: error.message)
            throw error
        } catch let error as DecodingError {
            throw NetworkError.decodingFailed(error)
        } catch {
            throw error
        }
    }

    /// 解码 Vimo 响应（自动解包 WrappedResponse）
    private func decodeVimoResponse(data: Data) throws -> R.Response {
        // 1. 解码为包装响应
        let wrappedResponse = try jsonDecoder.decode(VimoWrappedResponse<R.Response>.self, from: data)

        // 2. 检查业务状态
        if !wrappedResponse.success {
            // 业务失败，抛出业务错误
            throw VimoBusinessError(message: wrappedResponse.message, timestamp: wrappedResponse.timestamp)
        }

        // 3. 返回解包后的数据
        if let responseData = wrappedResponse.data {
            return responseData
        } else {
            // 对于操作类 API（EmptyResponse），创建空实例
            if R.Response.self == EmptyResponse.self {
                return EmptyResponse() as! R.Response
            } else {
                // 其他类型要求 data 字段必须存在
                throw NetworkError.decodingFailed(
                    DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing required data field in Vimo response"))
                )
            }
        }
    }

    /// 创建生命周期绑定的执行任务
    /// - Returns: 执行任务，会在 owner 释放时自动取消
    private func executeWithLifecycle() async throws -> R.Response {
        // 如果绑定到视图，创建可取消的任务
        if case .view(_) = config.lifecycle {
            // 使用 withTaskCancellationHandler 支持取消传播
            // 注意：真正的生命周期绑定（owner 释放时自动取消）
            // 应该在更高层（如 NetworkClient）通过 Task 管理实现
            return try await withTaskCancellationHandler {
                try await self.executeTask()
            } onCancel: {
                // 任务被取消时的清理逻辑（由外部 Task.cancel() 触发）
            }
        } else {
            return try await executeTask()
        }
    }

    /// 执行核心任务逻辑
    private func executeTask() async throws -> R.Response {
        // 1. 构建 URLRequest
        let urlRequest = try await buildURLRequest()

        // 2. 使用完整信息计算 CacheKey（排序后的 query）
        let cacheKey = CacheKey.from(
            method: request.method.rawValue,
            baseURL: request.baseURL,
            path: request.path,
            query: request.query,
            body: urlRequest.httpBody
        )

        // 3. 创建 NetworkTask
        let task = NetworkTask(
            request: urlRequest,
            config: config,
            cacheKey: cacheKey
        )

        // 4. 执行任务
        let data = try await executor.execute(task: task)

        // 5. 解码响应
        let response = try decodeResponse(data: data)

        return response
    }
}
