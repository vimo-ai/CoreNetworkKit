import Foundation

// MARK: - BeaconFlow Wrapped Response

/// BeaconFlow系统专用的包装响应格式
/// 支持有数据和无数据两种响应格式
/// 
/// 有数据响应格式：
/// ```json
/// {
///   "success": true,
///   "data": { ... },
///   "message": "操作成功",
///   "timestamp": "2024-01-01T10:00:00.000Z"
/// }
/// ```
/// 
/// 无数据响应格式（操作类API）：
/// ```json
/// {
///   "success": true,
///   "message": "操作成功", 
///   "timestamp": "2024-01-01T10:00:00.000Z"
/// }
/// ```
public struct BeaconFlowWrappedResponse<T: Decodable>: Decodable {
    /// 业务状态，true表示业务成功，false表示业务失败
    public let success: Bool
    
    /// 实际的业务数据（操作类API可能为空）
    public let data: T?
    
    /// 响应消息，成功时为空或成功消息，失败时为错误描述
    public let message: String
    
    /// 服务器响应时间戳
    public let timestamp: String
    
    public init(success: Bool, data: T?, message: String, timestamp: String) {
        self.success = success
        self.data = data
        self.message = message
        self.timestamp = timestamp
    }
}

// MARK: - BeaconFlow Business Error

// MARK: - Empty Response

/// 空响应类型 - 用于操作类API，不返回具体数据
public struct EmptyResponse: Decodable {
    public init() {}
    
    public init(from decoder: Decoder) throws {
        // 什么都不做，这是空响应
    }
}

// MARK: - BeaconFlow Business Error

/// BeaconFlow业务层面的错误（success=false但HTTP状态码正常）
public struct BeaconFlowBusinessError: LocalizedError {
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