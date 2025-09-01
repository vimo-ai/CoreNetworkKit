import Foundation

// MARK: - Frequency Limit Strategy

/// 频率限制策略
/// 使用滑动时间窗口算法，限制特定时间窗口内的请求次数
public class FrequencyLimitStrategy: RateLimitStrategy {
    
    // MARK: - Configuration
    
    /// 时间窗口内最大请求次数
    private let maxRequests: Int
    /// 时间窗口长度（秒）
    private let timeWindow: TimeInterval
    /// 是否按端点分别计数
    private let perEndpoint: Bool
    
    // MARK: - State Management
    
    /// 请求记录存储
    /// Key: endpoint (如果perEndpoint=true) 或 "global" (如果perEndpoint=false)
    /// Value: 请求时间戳数组
    private var requestRecords: [String: [Date]] = [:]
    /// 线程安全锁
    private let queue = DispatchQueue(label: "com.corenetworkkit.frequency-limit", attributes: .concurrent)
    
    // MARK: - Initialization
    
    /// 初始化频率限制策略
    /// - Parameters:
    ///   - maxRequests: 时间窗口内最大请求次数
    ///   - timeWindow: 时间窗口长度（秒）
    ///   - perEndpoint: 是否按端点分别计数，默认为true
    public init(maxRequests: Int, timeWindow: TimeInterval, perEndpoint: Bool = true) {
        self.maxRequests = maxRequests
        self.timeWindow = timeWindow
        self.perEndpoint = perEndpoint
    }
    
    // MARK: - RateLimitStrategy Implementation
    
    public func shouldAllow(request: RequestContext) -> RateLimitResult {
        return queue.sync {
            let key = perEndpoint ? request.endpoint : "global"
            let now = request.timestamp
            
            // 获取当前记录，如果不存在则创建新数组
            var records = requestRecords[key] ?? []
            
            // 清理过期记录（超出时间窗口的记录）
            let windowStart = now.addingTimeInterval(-timeWindow)
            records = records.filter { $0 >= windowStart }
            
            // 检查是否超过限制
            if records.count >= maxRequests {
                // 计算最早记录到期时间，作为重试建议
                if let oldestRecord = records.first {
                    let retryAfter = oldestRecord.addingTimeInterval(timeWindow).timeIntervalSince(now)
                    return .deny(
                        reason: "频率限制：\(timeWindow)秒内最多\(maxRequests)次请求",
                        retryAfter: max(0, retryAfter)
                    )
                } else {
                    return .deny(
                        reason: "频率限制：\(timeWindow)秒内最多\(maxRequests)次请求",
                        retryAfter: timeWindow
                    )
                }
            }
            
            // 允许请求，记录时间戳
            records.append(now)
            requestRecords[key] = records
            
            return .allow
        }
    }
    
    public func onRequestCompleted(request: RequestContext, result: RequestResult) {
        // 频率限制策略不需要处理请求完成事件
        // 因为我们只关心请求发起的频率，不关心请求结果
    }
    
    public func reset() {
        queue.async(flags: .barrier) {
            self.requestRecords.removeAll()
        }
    }
    
    // MARK: - Statistics (Optional)
    
    /// 获取当前统计信息（用于调试和监控）
    public func getCurrentStats() -> [String: Int] {
        return queue.sync {
            var stats: [String: Int] = [:]
            let now = Date()
            let windowStart = now.addingTimeInterval(-timeWindow)
            
            for (key, records) in requestRecords {
                let validRecords = records.filter { $0 >= windowStart }
                stats[key] = validRecords.count
            }
            
            return stats
        }
    }
    
    /// 获取指定端点的剩余请求次数
    public func getRemainingRequests(for endpoint: String) -> Int {
        return queue.sync {
            let key = perEndpoint ? endpoint : "global"
            let now = Date()
            let windowStart = now.addingTimeInterval(-timeWindow)
            
            let records = requestRecords[key] ?? []
            let validRecords = records.filter { $0 >= windowStart }
            
            return max(0, maxRequests - validRecords.count)
        }
    }
}

// MARK: - Convenience Initializers

public extension FrequencyLimitStrategy {
    /// 创建每分钟限制策略
    static func perMinute(_ maxRequests: Int, perEndpoint: Bool = true) -> FrequencyLimitStrategy {
        return FrequencyLimitStrategy(maxRequests: maxRequests, timeWindow: 60, perEndpoint: perEndpoint)
    }
    
    /// 创建每秒限制策略
    static func perSecond(_ maxRequests: Int, perEndpoint: Bool = true) -> FrequencyLimitStrategy {
        return FrequencyLimitStrategy(maxRequests: maxRequests, timeWindow: 1, perEndpoint: perEndpoint)
    }
    
    /// 创建每小时限制策略
    static func perHour(_ maxRequests: Int, perEndpoint: Bool = true) -> FrequencyLimitStrategy {
        return FrequencyLimitStrategy(maxRequests: maxRequests, timeWindow: 3600, perEndpoint: perEndpoint)
    }
}