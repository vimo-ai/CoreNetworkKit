import Foundation

// MARK: - Request Execution Types

/// 请求执行器协议
/// 定义了请求执行的核心接口，支持可插拔的执行策略
public protocol RequestExecutor {
    /// 执行网络请求
    /// - Parameter request: 要执行的请求
    /// - Returns: 请求响应结果
    /// - Throws: 网络错误或业务错误
    func execute<T: Request>(_ request: T) async throws -> T.Response
    
    /// 取消指定请求（如果支持）
    /// - Parameter requestId: 请求标识符
    func cancelRequest(id requestId: String)
    
    /// 取消所有进行中的请求
    func cancelAllRequests()
    
    /// 获取当前活跃请求数量
    var activeRequestCount: Int { get }
}

// MARK: - Request Metadata

/// 请求元数据，用于请求跟踪和管理
public struct RequestMetadata {
    /// 唯一标识符
    public let id: String
    /// 请求路径
    public let path: String
    /// 创建时间
    public let createdAt: Date
    /// 请求优先级
    public let priority: RequestPriority
    
    public init(id: String = UUID().uuidString, path: String, priority: RequestPriority = .normal) {
        self.id = id
        self.path = path
        self.createdAt = Date()
        self.priority = priority
    }
}

/// 请求优先级
public enum RequestPriority: Int, Comparable {
    case low = 0
    case normal = 1
    case high = 2
    case critical = 3
    
    public static func < (lhs: RequestPriority, rhs: RequestPriority) -> Bool {
        return lhs.rawValue < rhs.rawValue
    }
}

// MARK: - Request Extension for Metadata

public extension Request {
    /// 生成请求的唯一标识符
    var requestId: String {
        return "\(method.rawValue):\(path)"
    }
    
    /// 请求的优先级（可以在具体实现中重写）
    var priority: RequestPriority {
        return .normal
    }
}