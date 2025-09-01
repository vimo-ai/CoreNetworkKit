import Foundation

// MARK: - Request Stack Configuration

/// 请求栈配置
public struct RequestStackConfiguration {
    /// 最大并发请求数
    public let maxConcurrency: Int
    /// 是否启用重复请求去重
    public let deduplicationEnabled: Bool
    /// 请求超时时间（秒）
    public let defaultTimeout: TimeInterval
    /// 是否启用请求优先级调度
    public let prioritySchedulingEnabled: Bool
    
    public init(
        maxConcurrency: Int = 3,
        deduplicationEnabled: Bool = true,
        defaultTimeout: TimeInterval = 30,
        prioritySchedulingEnabled: Bool = false
    ) {
        self.maxConcurrency = maxConcurrency
        self.deduplicationEnabled = deduplicationEnabled
        self.defaultTimeout = defaultTimeout
        self.prioritySchedulingEnabled = prioritySchedulingEnabled
    }
    
    /// 默认配置
    public static let `default` = RequestStackConfiguration()
}

// MARK: - Request Stack Implementation

/// 请求栈实现
/// 提供请求队列管理、并发控制、重复请求去重等功能
public class RequestStack: RequestExecutor {
    
    // MARK: - Configuration & Dependencies
    
    private let configuration: RequestStackConfiguration
    private let rateLimiter: RateLimitStrategy
    private let networkExecutor: (any Request) async throws -> Any
    
    // MARK: - State Management
    
    /// 活跃请求跟踪
    private var activeTasks: [String: Task<Any, Error>] = [:]
    /// 等待队列（按优先级排序）
    private var waitingQueue: [RequestMetadata] = []
    /// 并发控制信号量
    private let concurrencySemaphore: DispatchSemaphore
    /// 线程安全锁
    private let queue = DispatchQueue(label: "com.corenetworkkit.request-stack", attributes: .concurrent)
    
    // MARK: - Initialization
    
    /// 初始化请求栈
    /// - Parameters:
    ///   - configuration: 请求栈配置
    ///   - rateLimiter: 限流策略
    ///   - networkExecutor: 实际网络执行器
    public init(
        configuration: RequestStackConfiguration = .default,
        rateLimiter: RateLimitStrategy = NoRateLimitStrategy(),
        networkExecutor: @escaping (any Request) async throws -> Any
    ) {
        self.configuration = configuration
        self.rateLimiter = rateLimiter
        self.networkExecutor = networkExecutor
        self.concurrencySemaphore = DispatchSemaphore(value: configuration.maxConcurrency)
    }
    
    // MARK: - RequestExecutor Implementation
    
    public func execute<T: Request>(_ request: T) async throws -> T.Response {
        let metadata = RequestMetadata(path: request.path, priority: request.priority)
        let requestContext = RequestContext(endpoint: request.path)
        
        // 1. 限流检查
        let rateLimitResult = rateLimiter.shouldAllow(request: requestContext)
        switch rateLimitResult {
        case .allow:
            break
        case .deny(let reason, let retryAfter):
            throw RequestStackError.rateLimited(reason: reason, retryAfter: retryAfter)
        case .delayRequest(let delay):
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        
        // 2. 重复请求检查
        if configuration.deduplicationEnabled {
            if let existingTask = getActiveTask(for: metadata.id) {
                // 等待现有请求完成
                return try await withTaskCancellationHandler {
                    let result = try await existingTask.value
                    return result as! T.Response
                } onCancel: {
                    existingTask.cancel()
                }
            }
        }
        
        // 3. 并发控制
        concurrencySemaphore.wait()
        
        // 4. 执行请求
        let task = Task<Any, Error> {
            defer {
                removeActiveTask(for: metadata.id)
                concurrencySemaphore.signal()
            }
            
            do {
                let result = try await networkExecutor(request)
                rateLimiter.onRequestCompleted(request: requestContext, result: .success)
                return result
            } catch {
                if error is CancellationError {
                    rateLimiter.onRequestCompleted(request: requestContext, result: .cancelled)
                } else {
                    rateLimiter.onRequestCompleted(request: requestContext, result: .failure(error))
                }
                throw error
            }
        }
        
        // 5. 注册活跃任务
        setActiveTask(task, for: metadata.id)
        
        // 6. 等待结果
        let result = try await task.value
        return result as! T.Response
    }
    
    public func cancelRequest(id requestId: String) {
        queue.async(flags: .barrier) {
            self.activeTasks[requestId]?.cancel()
            self.activeTasks.removeValue(forKey: requestId)
        }
    }
    
    public func cancelAllRequests() {
        queue.async(flags: .barrier) {
            for task in self.activeTasks.values {
                task.cancel()
            }
            self.activeTasks.removeAll()
            self.waitingQueue.removeAll()
        }
    }
    
    public var activeRequestCount: Int {
        return queue.sync {
            return activeTasks.count
        }
    }
    
    // MARK: - Private Helpers
    
    private func getActiveTask(for requestId: String) -> Task<Any, Error>? {
        return queue.sync {
            return activeTasks[requestId]
        }
    }
    
    private func setActiveTask(_ task: Task<Any, Error>, for requestId: String) {
        queue.async(flags: .barrier) {
            self.activeTasks[requestId] = task
        }
    }
    
    private func removeActiveTask(for requestId: String) {
        queue.async(flags: .barrier) {
            self.activeTasks.removeValue(forKey: requestId)
        }
    }
}

// MARK: - Request Stack Errors

/// 请求栈相关错误
public enum RequestStackError: LocalizedError {
    case rateLimited(reason: String, retryAfter: TimeInterval?)
    case concurrencyLimitExceeded
    case requestCancelled
    case configurationError(String)
    
    public var errorDescription: String? {
        switch self {
        case .rateLimited(let reason, _):
            return "请求被限流: \(reason)"
        case .concurrencyLimitExceeded:
            return "并发请求数超过限制"
        case .requestCancelled:
            return "请求已被取消"
        case .configurationError(let message):
            return "配置错误: \(message)"
        }
    }
}

// MARK: - Async Semaphore Helper

/// 异步信号量实现
private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    
    init(value: Int) {
        self.value = value
    }
    
    func wait() async {
        if value > 0 {
            value -= 1
            return
        }
        
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
    
    func signal() {
        if waiters.isEmpty {
            value += 1
        } else {
            let waiter = waiters.removeFirst()
            waiter.resume()
        }
    }
}