import Foundation

/// 重试策略
///
/// 定义请求失败后的重试行为：
/// - none: 不重试
/// - fixed: 固定次数重试
/// - exponential: 指数退避重试
///
/// 语义说明：
/// - `maxAttempts` 包含首次请求，即 maxAttempts=3 表示最多尝试 3 次（首次 + 2 次重试）
/// - `delay(for:)` 的 attempt 参数表示第几次重试（0 = 第一次重试，即第二次请求）
/// - 首次请求失败后才会调用 delay(for: 0) 计算第一次重试的等待时间
public enum RetryPolicy: Sendable {
    /// 不重试
    case none

    /// 固定次数重试
    /// - Parameters:
    ///   - maxAttempts: 最大尝试次数（包括首次请求），必须 >= 1
    ///   - delay: 重试间隔（秒），必须 >= 0
    case fixed(maxAttempts: Int, delay: TimeInterval)

    /// 指数退避重试
    /// - Parameters:
    ///   - maxAttempts: 最大尝试次数（包括首次请求），必须 >= 1
    ///   - initialDelay: 初始重试间隔（秒），必须 > 0
    ///   - multiplier: 延迟倍增系数，必须 >= 1
    ///   - maxDelay: 最大重试间隔（秒）
    case exponential(
        maxAttempts: Int,
        initialDelay: TimeInterval,
        multiplier: Double,
        maxDelay: TimeInterval = 30
    )

    // MARK: - 便捷工厂方法

    /// 创建固定重试策略（带参数验证）
    public static func fixedRetry(
        maxAttempts: Int,
        delay: TimeInterval
    ) -> RetryPolicy {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
        precondition(delay >= 0, "delay must be >= 0")
        return .fixed(maxAttempts: maxAttempts, delay: delay)
    }

    /// 创建指数退避策略（带参数验证）
    public static func exponentialBackoff(
        maxAttempts: Int,
        initialDelay: TimeInterval,
        multiplier: Double = 2.0,
        maxDelay: TimeInterval = 30
    ) -> RetryPolicy {
        precondition(maxAttempts >= 1, "maxAttempts must be >= 1")
        precondition(initialDelay > 0, "initialDelay must be > 0")
        precondition(multiplier >= 1, "multiplier must be >= 1")
        return .exponential(
            maxAttempts: maxAttempts,
            initialDelay: initialDelay,
            multiplier: multiplier,
            maxDelay: maxDelay
        )
    }

    // MARK: - 属性

    /// 获取最大尝试次数
    public var maxAttempts: Int {
        switch self {
        case .none:
            return 1
        case .fixed(let maxAttempts, _):
            return max(1, maxAttempts)
        case .exponential(let maxAttempts, _, _, _):
            return max(1, maxAttempts)
        }
    }

    /// 最大重试次数（不含首次请求）
    public var maxRetries: Int {
        return maxAttempts - 1
    }

    /// 是否允许重试
    public var allowsRetry: Bool {
        return maxAttempts > 1
    }

    // MARK: - 方法

    /// 判断是否可以进行指定次数的重试
    /// - Parameter attempt: 重试次数（从 0 开始，0 表示第一次重试）
    /// - Returns: 是否允许该次重试
    public func canRetry(attempt: Int) -> Bool {
        guard attempt >= 0 else { return false }
        return attempt < maxRetries
    }

    /// 计算指定重试次数的延迟时间
    ///
    /// - Parameter attempt: 重试次数（从 0 开始，0 = 第一次重试）
    /// - Returns: 延迟时间（秒）；如果超出重试次数则返回 0
    ///
    /// 使用示例：
    /// ```swift
    /// let policy = RetryPolicy.exponential(maxAttempts: 3, initialDelay: 1, multiplier: 2)
    /// // 首次请求失败
    /// let delay0 = policy.delay(for: 0) // 1 秒后第一次重试
    /// // 第一次重试失败
    /// let delay1 = policy.delay(for: 1) // 2 秒后第二次重试
    /// // 第二次重试失败
    /// let delay2 = policy.delay(for: 2) // 0（已达最大次数，不再重试）
    /// ```
    public func delay(for attempt: Int) -> TimeInterval {
        // 如果超出重试次数，返回 0
        guard canRetry(attempt: attempt) else {
            return 0
        }

        switch self {
        case .none:
            return 0

        case .fixed(_, let delay):
            return delay

        case .exponential(_, let initialDelay, let multiplier, let maxDelay):
            // attempt=0 对应 initialDelay
            // attempt=1 对应 initialDelay * multiplier
            // attempt=n 对应 initialDelay * multiplier^n
            let delay = initialDelay * pow(multiplier, Double(attempt))
            return min(delay, maxDelay)
        }
    }
}
