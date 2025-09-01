import Foundation

/// 一种不执行任何操作的认证策略。
/// 对于不需要认证的公共API端点，这是一个有用的默认值。
public struct NoAuthenticationStrategy: AuthenticationStrategy {
    public init() {}
    
    public func apply(to request: URLRequest, context: AuthenticationContext) async throws -> URLRequest {
        // 直接返回原始请求，不进行任何修改。
        return request
    }
}