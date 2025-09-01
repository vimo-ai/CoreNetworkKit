import Foundation

// MARK: - Rate Limiting Types

/// 请求上下文信息，用于限流策略判断
public struct RequestContext {
    /// 请求的端点路径
    public let endpoint: String
    /// 请求时间戳
    public let timestamp: Date
    /// 用户标识（可选）
    public let userID: String?
    /// 请求大小（可选，字节数）
    public let requestSize: Int?
    
    public init(
        endpoint: String,
        timestamp: Date = Date(),
        userID: String? = nil,
        requestSize: Int? = nil
    ) {
        self.endpoint = endpoint
        self.timestamp = timestamp
        self.userID = userID
        self.requestSize = requestSize
    }
}

/// 限流结果
public enum RateLimitResult: Equatable {
    /// 允许请求
    case allow
    /// 拒绝请求
    case deny(reason: String, retryAfter: TimeInterval?)
    /// 延迟请求
    case delayRequest(delay: TimeInterval)
    
    public var isAllowed: Bool {
        switch self {
        case .allow: return true
        case .deny, .delayRequest: return false
        }
    }
}

/// 请求完成结果
public enum RequestResult {
    /// 请求成功
    case success
    /// 请求失败
    case failure(Error)
    /// 请求被取消
    case cancelled
}

// MARK: - Rate Limit Strategy Protocol

/// 限流策略协议
/// 定义了限流策略的核心接口，支持可插拔的限流算法
public protocol RateLimitStrategy {
    /// 判断请求是否应该被允许
    /// - Parameter request: 请求上下文信息
    /// - Returns: 限流结果
    func shouldAllow(request: RequestContext) -> RateLimitResult
    
    /// 请求完成后的回调，用于更新策略内部状态
    /// - Parameters:
    ///   - request: 请求上下文信息
    ///   - result: 请求完成结果
    func onRequestCompleted(request: RequestContext, result: RequestResult)
    
    /// 重置策略状态（可选，用于清理或重新初始化）
    func reset()
}

// MARK: - Default Implementation

public extension RateLimitStrategy {
    /// 默认实现：不需要处理请求完成事件
    func onRequestCompleted(request: RequestContext, result: RequestResult) {
        // 默认空实现
    }
    
    /// 默认实现：不需要重置状态
    func reset() {
        // 默认空实现
    }
}

// MARK: - No Rate Limit Strategy

/// 无限流策略 - 允许所有请求通过
public struct NoRateLimitStrategy: RateLimitStrategy {
    public init() {}
    
    public func shouldAllow(request: RequestContext) -> RateLimitResult {
        return .allow
    }
}