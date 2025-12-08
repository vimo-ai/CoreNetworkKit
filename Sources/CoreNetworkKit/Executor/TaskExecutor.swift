import Foundation
import MLoggerKit

/// 任务执行器 - 核心执行管道
///
/// 执行流程：
/// [Control Gate] → [Cache Read] → [Auth+Retry+Send] → [Cache Write]
///
/// 特性：
/// - 支持取消传播
/// - 自动处理 401 刷新 Token（Single-Flight 模式）
/// - 重试时区分幂等/非幂等
/// - 全局超时控制
public final class TaskExecutor {
    private let logger = LoggerFactory.network

    // MARK: - Dependencies

    private let engine: NetworkEngine
    private let controlGate: ControlGate
    private let cacheManager: CacheManager
    private let tokenStorage: TokenStorage
    private let tokenRefresher: TokenRefresher?

    // MARK: - Token Refresh State (Single-Flight)

    private let refreshCoordinator = TokenRefreshCoordinator()

    // MARK: - Initialization

    public init(
        engine: NetworkEngine,
        controlGate: ControlGate = ControlGate(),
        cacheManager: CacheManager = CacheManager(),
        tokenStorage: TokenStorage,
        tokenRefresher: TokenRefresher? = nil
    ) {
        self.engine = engine
        self.controlGate = controlGate
        self.cacheManager = cacheManager
        self.tokenStorage = tokenStorage
        self.tokenRefresher = tokenRefresher
    }

    // MARK: - Public Methods

    /// 执行网络任务
    /// - Parameter task: 网络任务
    /// - Returns: 原始响应数据
    /// - Throws: NetworkError
    public func execute(task: NetworkTask) async throws -> Data {
        let startTime = Date()
        logger.debug("[TaskExecutor] Task started: \(task.request.url?.absoluteString ?? "unknown")")

        // 整体超时保护
        if let totalTimeout = task.config.totalTimeout {
            return try await withThrowingTimeout(seconds: totalTimeout) {
                try await self.executeInternal(task: task, startTime: startTime)
            }
        } else {
            return try await executeInternal(task: task, startTime: startTime)
        }
    }

    // MARK: - Private Methods

    private func executeInternal(task: NetworkTask, startTime: Date) async throws -> Data {
        // 检查取消
        try Task.checkCancellation()

        // 1. Control Gate
        let passResult = try await controlGate.pass(task: task)
        try Task.checkCancellation()

        switch passResult {
        case .proceed:
            // 继续执行
            break

        case .waitingForData(let existingTask):
            // 复用正在执行的任务
            logger.debug("[TaskExecutor] Reusing in-flight task")
            return try await existingTask.value
        }

        // 2. Cache Read
        switch task.config.cache {
        case .cacheFirst(let maxAge):
            if let cachedData: Data = await cacheManager.read(key: task.cacheKey, maxAge: maxAge) {
                logger.debug("[TaskExecutor] Cache hit (cacheFirst), returning cached data")
                return cachedData
            }

        case .staleWhileRevalidate:
            // SWR: 先返回缓存（如果有），同时后台刷新
            if let cachedData: Data = await cacheManager.read(key: task.cacheKey, maxAge: nil) {
                logger.debug("[TaskExecutor] Cache hit (SWR), returning stale data and revalidating")
                // 后台刷新（不阻塞返回）
                Task {
                    do {
                        let freshData = try await self.executeWithRetry(task: task)
                        await self.cacheManager.write(key: task.cacheKey, value: freshData, maxAge: nil)
                        self.logger.debug("[TaskExecutor] SWR revalidation completed")
                    } catch {
                        self.logger.warning("[TaskExecutor] SWR revalidation failed: \(error)")
                    }
                }
                return cachedData
            }

        case .none:
            break
        }

        try Task.checkCancellation()

        // 3. Execute with Retry
        let result = try await executeWithRetry(task: task)

        try Task.checkCancellation()

        // 4. Cache Write
        await writeCacheIfNeeded(task: task, data: result)

        let duration = Date().timeIntervalSince(startTime)
        logger.debug("[TaskExecutor] Task completed in \(String(format: "%.3f", duration))s")

        return result
    }

    /// 执行请求（带重试）
    private func executeWithRetry(task: NetworkTask) async throws -> Data {
        let retryPolicy = task.config.retry

        // 创建执行任务（用于去重）
        let executionTask = Task<Data, Error> {
            defer {
                Task {
                    await self.controlGate.unregisterInFlight(cacheKey: task.cacheKey)
                }
            }

            var currentAttempt = 0
            var currentError: Error?
            var tokenRefreshAttempted = false  // 限制 Token 刷新只尝试一次

            while currentAttempt < retryPolicy.maxAttempts {
                try Task.checkCancellation()

                do {
                    // 每次重试都重新应用 Token（支持刷新后的新 Token）
                    let request = try await self.applyCurrentToken(to: task.request)
                    let data = try await self.executeSingleRequest(request: request, timeout: task.config.timeout)
                    return data
                } catch {
                    currentError = error
                    let networkError = mapToNetworkError(error)

                    // 如果是取消，立即抛出
                    if case .cancelled = networkError {
                        throw networkError
                    }

                    // 检查是否需要刷新 Token（只尝试一次）
                    if networkError.isUnauthorized,
                       self.tokenRefresher != nil,
                       !tokenRefreshAttempted {
                        tokenRefreshAttempted = true
                        logger.info("[TaskExecutor] 401 detected, attempting token refresh")
                        do {
                            _ = try await self.refreshTokenIfNeeded()
                            // 刷新成功，重试当前请求（计入重试次数以防止无限循环）
                            currentAttempt += 1
                            logger.info("[TaskExecutor] Token refreshed, retrying request (attempt \(currentAttempt)/\(retryPolicy.maxAttempts))")
                            continue
                        } catch {
                            logger.error("[TaskExecutor] Token refresh failed: \(error)")
                            throw NetworkError.authenticationFailed
                        }
                    }

                    // 判断是否可以重试
                    let retryAttempt = currentAttempt // 第一次失败对应 retry attempt 0
                    if retryPolicy.canRetry(attempt: retryAttempt) {
                        // 检查是否允许重试（幂等性检查）
                        if shouldRetry(task: task, error: networkError) {
                            let delay = retryPolicy.delay(for: retryAttempt)
                            logger.info("[TaskExecutor] Retrying after \(delay)s (attempt \(currentAttempt + 1)/\(retryPolicy.maxAttempts))")
                            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            currentAttempt += 1
                            continue
                        }
                    }

                    // 不能重试，抛出错误
                    throw networkError
                }
            }

            // 重试次数用尽
            throw NetworkError.retryExhausted(lastError: currentError ?? NetworkError.unknown(NSError(domain: "Unknown", code: -1)))
        }

        // 如果启用去重，更新占位为实际任务
        if task.config.control.deduplicate {
            await controlGate.updateInFlight(cacheKey: task.cacheKey, task: executionTask)
        }

        return try await executionTask.value
    }

    /// 重新应用当前 Token 到请求
    private func applyCurrentToken(to request: URLRequest) async throws -> URLRequest {
        var mutableRequest = request

        // 获取当前 Token
        if let token = await tokenStorage.getToken() {
            mutableRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return mutableRequest
    }

    /// 执行单次请求
    private func executeSingleRequest(request: URLRequest, timeout: TimeInterval?) async throws -> Data {
        // 单次请求超时
        if let timeout = timeout {
            return try await withThrowingTimeout(seconds: timeout) {
                try await self.performRequest(request)
            }
        } else {
            return try await performRequest(request)
        }
    }

    /// 执行网络请求
    private func performRequest(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await engine.performRequest(request)

            // 检查 HTTP 状态码
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NetworkError.unknown(NSError(domain: "Invalid response", code: -1))
            }

            // 2xx 表示成功
            if (200..<300).contains(httpResponse.statusCode) {
                return data
            }

            // 4xx/5xx 表示错误
            let message = String(data: data, encoding: .utf8)
            throw NetworkError.serverError(statusCode: httpResponse.statusCode, message: message)

        } catch let error as NetworkError {
            throw error
        } catch {
            throw mapToNetworkError(error)
        }
    }

    /// 写入缓存（如果需要）
    private func writeCacheIfNeeded(task: NetworkTask, data: Data) async {
        switch task.config.cache {
        case .cacheFirst(let maxAge):
            await cacheManager.write(key: task.cacheKey, value: data, maxAge: maxAge)

        case .staleWhileRevalidate:
            await cacheManager.write(key: task.cacheKey, value: data, maxAge: nil)

        case .none:
            break
        }
    }

    /// 判断是否应该重试
    private func shouldRetry(task: NetworkTask, error: NetworkError) -> Bool {
        // 如果是 GET 请求，通常是幂等的，可以重试
        if task.request.httpMethod?.uppercased() == "GET" {
            return true
        }

        // POST/PUT/DELETE 等非幂等请求，只在特定错误时重试
        // - 网络错误（超时、无网络）可以重试
        // - 5xx 服务器错误可以重试
        // - 4xx 客户端错误不应该重试
        switch error {
        case .timeout, .noNetwork:
            return true
        case .serverError where error.isServerError:
            return true
        default:
            return false
        }
    }

    /// 刷新 Token（Single-Flight 模式）
    private func refreshTokenIfNeeded() async throws -> String {
        guard let refresher = tokenRefresher else {
            throw NetworkError.authenticationFailed
        }

        logger.info("[TaskExecutor] Starting token refresh")
        try await refreshCoordinator.refresh(using: refresher)
        logger.info("[TaskExecutor] Token refresh completed")

        // 返回新 token（从 tokenStorage 获取）
        guard let newToken = await tokenStorage.getToken() else {
            throw NetworkError.authenticationFailed
        }

        return newToken
    }

    /// 将错误映射为 NetworkError
    private func mapToNetworkError(_ error: Error) -> NetworkError {
        if let networkError = error as? NetworkError {
            return networkError
        }

        let nsError = error as NSError

        // 取消错误
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return .cancelled
            case NSURLErrorTimedOut:
                return .timeout
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost:
                return .noNetwork
            default:
                break
            }
        }

        // Task 取消
        if error is CancellationError {
            return .cancelled
        }

        return .unknown(error)
    }
}


// MARK: - Timeout Helper

/// 带超时的异步执行
private func withThrowingTimeout<T>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        // 实际任务
        group.addTask {
            try await operation()
        }

        // 超时任务
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw NetworkError.timeout
        }

        // 等待第一个完成的任务
        guard let result = try await group.next() else {
            throw NetworkError.timeout
        }

        // 取消其他任务
        group.cancelAll()

        return result
    }
}
