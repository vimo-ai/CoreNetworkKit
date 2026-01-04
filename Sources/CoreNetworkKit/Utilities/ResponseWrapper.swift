import Foundation

// MARK: - Wrapped Response Models

/// 后端API包装响应格式
/// 统一的响应结构，所有后端接口都遵循此格式
/// 
/// BeaconFlow系统返回格式：
/// ```json
/// {
///   "success": true,
///   "data": { ... },
///   "message": "操作成功",
///   "timestamp": "2024-01-01T10:00:00.000Z"
/// }
/// ```
public struct WrappedResponse<T: Codable>: Codable {
    /// 业务状态，true表示业务成功，false表示业务失败
    public let success: Bool
    
    /// 实际的业务数据
    public let data: T
    
    /// 响应消息，成功时为空或成功消息，失败时为错误描述
    public let message: String
    
    /// 服务器响应时间戳
    public let timestamp: String
    
    public init(success: Bool, data: T, message: String, timestamp: String) {
        self.success = success
        self.data = data
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - Business Error

/// 业务层面的错误（success=false但HTTP状态码正常）
public struct BusinessError: LocalizedError {
    public let message: String
    public let timestamp: String
    
    public init(message: String, timestamp: String) {
        self.message = message
        self.timestamp = timestamp
    }
    
    public var errorDescription: String? {
        return message
    }
}

// MARK: - User Feedback Protocol

/// 用户反馈协议，用于Toast通知和日志记录
public protocol UserFeedbackHandler {
    /// 显示成功消息
    func showSuccess(message: String)

    /// 显示错误消息
    func showError(message: String)

    /// 显示警告消息
    func showWarning(message: String)

    /// 记录日志
    func log(level: LogLevel, message: String)

    /// 处理认证失败（401 且 token 刷新失败时调用）
    /// 实现方应清除本地登录状态并跳转到登录页
    func handleAuthenticationFailure()
}

/// 日志级别
public enum LogLevel {
    case debug
    case info
    case warning
    case error
}

// MARK: - Default User Feedback Handler

/// 默认的用户反馈处理器（仅日志，不显示Toast）
public class DefaultUserFeedbackHandler: UserFeedbackHandler {
    public init() {}

    public func showSuccess(message: String) {
        log(level: .info, message: "Success: \(message)")
    }

    public func showError(message: String) {
        log(level: .error, message: "Error: \(message)")
    }

    public func showWarning(message: String) {
        log(level: .warning, message: "Warning: \(message)")
    }

    public func log(level: LogLevel, message: String) {
        print("[\(level)] \(message)")
    }

    public func handleAuthenticationFailure() {
        log(level: .warning, message: "Authentication failed - user should be logged out")
    }
}