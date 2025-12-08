import Foundation

// MARK: - Vimo Wrapped Response

/// Vimo 系统专用的包装响应格式
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
/// 无数据响应格式（操作类 API）：
/// ```json
/// {
///   "success": true,
///   "message": "操作成功",
///   "timestamp": "2024-01-01T10:00:00.000Z"
/// }
/// ```
public struct VimoWrappedResponse<T: Decodable>: Decodable {
    /// 业务状态，true 表示业务成功，false 表示业务失败
    public let success: Bool

    /// 实际的业务数据（操作类 API 可能为空）
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

// MARK: - Empty Response

/// 空响应类型 - 用于操作类 API，不返回具体数据
public struct EmptyResponse: Decodable {
    public init() {}

    public init(from decoder: Decoder) throws {
        // 什么都不做，这是空响应
    }
}

// MARK: - Vimo Business Error

/// Vimo 业务层面的错误（success=false 但 HTTP 状态码正常）
public struct VimoBusinessError: LocalizedError {
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

// MARK: - Backward Compatibility

/// 向后兼容别名（已废弃，请使用 VimoWrappedResponse）
@available(*, deprecated, renamed: "VimoWrappedResponse")
public typealias BeaconFlowWrappedResponse = VimoWrappedResponse

/// 向后兼容别名（已废弃，请使用 VimoBusinessError）
@available(*, deprecated, renamed: "VimoBusinessError")
public typealias BeaconFlowBusinessError = VimoBusinessError