import Foundation

// MARK: - Network Stack Builder

/// 网络栈建造者
/// 提供流式API来配置和构建网络请求栈
public class NetworkStackBuilder {
    
    // MARK: - Configuration State
    
    private var rateLimitStrategies: [RateLimitStrategy] = []
    private var requestStackConfig = RequestStackConfiguration.default
    private var networkExecutor: ((any Request) async throws -> Any)?
    
    // MARK: - Rate Limiting Configuration
    
    /// 添加频率限制
    /// - Parameters:
    ///   - maxRequests: 最大请求数
    ///   - timeWindow: 时间窗口（秒）
    ///   - perEndpoint: 是否按端点分别计数
    /// - Returns: 建造者实例，支持链式调用
    public func addFrequencyLimit(
        maxRequests: Int,
        per timeWindow: TimeInterval,
        perEndpoint: Bool = true
    ) -> Self {
        let strategy = FrequencyLimitStrategy(
            maxRequests: maxRequests,
            timeWindow: timeWindow,
            perEndpoint: perEndpoint
        )
        rateLimitStrategies.append(strategy)
        return self
    }
    
    /// 添加每分钟频率限制
    /// - Parameters:
    ///   - maxRequests: 每分钟最大请求数
    ///   - perEndpoint: 是否按端点分别计数
    /// - Returns: 建造者实例，支持链式调用
    public func addFrequencyLimitPerMinute(
        _ maxRequests: Int,
        perEndpoint: Bool = true
    ) -> Self {
        return addFrequencyLimit(maxRequests: maxRequests, per: 60, perEndpoint: perEndpoint)
    }
    
    /// 添加每秒频率限制
    /// - Parameters:
    ///   - maxRequests: 每秒最大请求数
    ///   - perEndpoint: 是否按端点分别计数
    /// - Returns: 建造者实例，支持链式调用
    public func addFrequencyLimitPerSecond(
        _ maxRequests: Int,
        perEndpoint: Bool = true
    ) -> Self {
        return addFrequencyLimit(maxRequests: maxRequests, per: 1, perEndpoint: perEndpoint)
    }
    
    /// 添加自定义限流策略
    /// - Parameter strategy: 自定义限流策略
    /// - Returns: 建造者实例，支持链式调用
    public func addRateLimitStrategy(_ strategy: RateLimitStrategy) -> Self {
        rateLimitStrategies.append(strategy)
        return self
    }
    
    // MARK: - Request Stack Configuration
    
    /// 配置最大并发数
    /// - Parameter maxConcurrency: 最大并发请求数
    /// - Returns: 建造者实例，支持链式调用
    public func setMaxConcurrency(_ maxConcurrency: Int) -> Self {
        requestStackConfig = RequestStackConfiguration(
            maxConcurrency: maxConcurrency,
            deduplicationEnabled: requestStackConfig.deduplicationEnabled,
            defaultTimeout: requestStackConfig.defaultTimeout,
            prioritySchedulingEnabled: requestStackConfig.prioritySchedulingEnabled
        )
        return self
    }
    
    /// 启用或禁用重复请求去重
    /// - Parameter enabled: 是否启用去重
    /// - Returns: 建造者实例，支持链式调用
    public func setDeduplicationEnabled(_ enabled: Bool) -> Self {
        requestStackConfig = RequestStackConfiguration(
            maxConcurrency: requestStackConfig.maxConcurrency,
            deduplicationEnabled: enabled,
            defaultTimeout: requestStackConfig.defaultTimeout,
            prioritySchedulingEnabled: requestStackConfig.prioritySchedulingEnabled
        )
        return self
    }
    
    /// 设置默认超时时间
    /// - Parameter timeout: 超时时间（秒）
    /// - Returns: 建造者实例，支持链式调用
    public func setDefaultTimeout(_ timeout: TimeInterval) -> Self {
        requestStackConfig = RequestStackConfiguration(
            maxConcurrency: requestStackConfig.maxConcurrency,
            deduplicationEnabled: requestStackConfig.deduplicationEnabled,
            defaultTimeout: timeout,
            prioritySchedulingEnabled: requestStackConfig.prioritySchedulingEnabled
        )
        return self
    }
    
    /// 启用或禁用优先级调度
    /// - Parameter enabled: 是否启用优先级调度
    /// - Returns: 建造者实例，支持链式调用
    public func setPrioritySchedulingEnabled(_ enabled: Bool) -> Self {
        requestStackConfig = RequestStackConfiguration(
            maxConcurrency: requestStackConfig.maxConcurrency,
            deduplicationEnabled: requestStackConfig.deduplicationEnabled,
            defaultTimeout: requestStackConfig.defaultTimeout,
            prioritySchedulingEnabled: enabled
        )
        return self
    }
    
    // MARK: - Network Executor Configuration
    
    /// 设置网络执行器
    /// - Parameter executor: 网络执行器闭包
    /// - Returns: 建造者实例，支持链式调用
    public func setNetworkExecutor(_ executor: @escaping (any Request) async throws -> Any) -> Self {
        self.networkExecutor = executor
        return self
    }
    
    // MARK: - Build Methods
    
    /// 构建请求执行器
    /// - Returns: 配置好的请求执行器
    /// - Throws: 如果配置不完整则抛出错误
    public func buildRequestExecutor() throws -> RequestExecutor {
        guard let networkExecutor = networkExecutor else {
            throw NetworkStackError.missingNetworkExecutor
        }
        
        let rateLimiter = createCompositeRateLimiter()
        
        return RequestStack(
            configuration: requestStackConfig,
            rateLimiter: rateLimiter,
            networkExecutor: networkExecutor
        )
    }
    
    /// 构建限流策略
    /// - Returns: 组合的限流策略
    public func buildRateLimiter() -> RateLimitStrategy {
        return createCompositeRateLimiter()
    }
    
    // MARK: - Private Helpers
    
    private func createCompositeRateLimiter() -> RateLimitStrategy {
        if rateLimitStrategies.isEmpty {
            return NoRateLimitStrategy()
        } else if rateLimitStrategies.count == 1 {
            return rateLimitStrategies[0]
        } else {
            return CompositeRateLimitStrategy(strategies: rateLimitStrategies)
        }
    }
}

// MARK: - Composite Rate Limit Strategy

/// 组合限流策略
/// 支持多个限流策略的组合使用
private class CompositeRateLimitStrategy: RateLimitStrategy {
    private let strategies: [RateLimitStrategy]
    
    init(strategies: [RateLimitStrategy]) {
        self.strategies = strategies
    }
    
    func shouldAllow(request: RequestContext) -> RateLimitResult {
        // 所有策略都必须允许才能通过
        for strategy in strategies {
            let result = strategy.shouldAllow(request: request)
            if !result.isAllowed {
                return result
            }
        }
        return .allow
    }
    
    func onRequestCompleted(request: RequestContext, result: RequestResult) {
        // 通知所有策略请求完成
        for strategy in strategies {
            strategy.onRequestCompleted(request: request, result: result)
        }
    }
    
    func reset() {
        // 重置所有策略
        for strategy in strategies {
            strategy.reset()
        }
    }
}

// MARK: - Network Stack Factory

/// 网络栈工厂
/// 提供预定义的网络栈配置
public class NetworkStackFactory {
    
    /// 创建默认配置的网络栈建造者
    /// - Returns: 预配置的建造者
    public static func createDefault() -> NetworkStackBuilder {
        return NetworkStackBuilder()
            .addFrequencyLimitPerMinute(60, perEndpoint: true)  // 每端点每分钟60次
            .setMaxConcurrency(3)                               // 最多3个并发
            .setDeduplicationEnabled(true)                      // 启用去重
            .setDefaultTimeout(30)                              // 30秒超时
    }
    
    /// 创建严格限制的网络栈建造者
    /// - Returns: 预配置的建造者
    public static func createStrict() -> NetworkStackBuilder {
        return NetworkStackBuilder()
            .addFrequencyLimitPerMinute(30, perEndpoint: true)  // 每端点每分钟30次
            .addFrequencyLimitPerSecond(2, perEndpoint: true)   // 每端点每秒2次
            .setMaxConcurrency(2)                               // 最多2个并发
            .setDeduplicationEnabled(true)                      // 启用去重
            .setDefaultTimeout(20)                              // 20秒超时
    }
    
    /// 创建宽松限制的网络栈建造者
    /// - Returns: 预配置的建造者
    public static func createPermissive() -> NetworkStackBuilder {
        return NetworkStackBuilder()
            .addFrequencyLimitPerMinute(120, perEndpoint: true) // 每端点每分钟120次
            .setMaxConcurrency(5)                               // 最多5个并发
            .setDeduplicationEnabled(false)                     // 禁用去重
            .setDefaultTimeout(60)                              // 60秒超时
    }
    
    /// 创建无限制的网络栈建造者（仅用于开发测试）
    /// - Returns: 预配置的建造者
    public static func createUnlimited() -> NetworkStackBuilder {
        return NetworkStackBuilder()
            .setMaxConcurrency(10)                              // 最多10个并发
            .setDeduplicationEnabled(false)                     // 禁用去重
            .setDefaultTimeout(30)                              // 30秒超时
            // 不添加任何限流策略
    }
}

// MARK: - Network Stack Errors

/// 网络栈配置错误
public enum NetworkStackError: LocalizedError {
    case missingNetworkExecutor
    case invalidConfiguration(String)
    
    public var errorDescription: String? {
        switch self {
        case .missingNetworkExecutor:
            return "缺少网络执行器配置"
        case .invalidConfiguration(let message):
            return "无效的配置: \(message)"
        }
    }
}