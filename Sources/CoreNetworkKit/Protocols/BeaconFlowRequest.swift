import Foundation

/// BeaconFlow系统的API请求协议
/// 继承此协议的请求将自动使用BeaconFlow的响应解包策略
/// 
/// BeaconFlow后端返回格式：
/// {
///   "success": bool,
///   "data": T,
///   "message": string,
///   "timestamp": string
/// }
public protocol BeaconFlowRequest: Request {
    // 继承Request的所有要求，无需额外实现
}

// MARK: - Default Implementation

public extension BeaconFlowRequest {
    // BeaconFlowRequest使用全局APIConfiguration的配置
    // 具体实现在 Infrastructure/Network/Base/APIConfiguration.swift 中
}