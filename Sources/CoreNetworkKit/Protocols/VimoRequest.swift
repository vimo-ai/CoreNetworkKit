import Foundation

/// Vimo 系统的 API 请求协议
/// 继承此协议的请求将自动使用 Vimo 的响应解包策略
///
/// Vimo 后端返回格式：
/// {
///   "success": bool,
///   "data": T,
///   "message": string,
///   "timestamp": string
/// }
public protocol VimoRequest: Request {
    // 继承 Request 的所有要求，无需额外实现
}

// MARK: - Default Implementation

public extension VimoRequest {
    // VimoRequest 使用全局 APIConfiguration 的配置
    // 具体实现在 Infrastructure/Network/Base/APIConfiguration.swift 中
}

// MARK: - Backward Compatibility

/// 向后兼容别名（已废弃，请使用 VimoRequest）
@available(*, deprecated, renamed: "VimoRequest")
public typealias BeaconFlowRequest = VimoRequest