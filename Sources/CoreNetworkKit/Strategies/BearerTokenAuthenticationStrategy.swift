import Foundation

/// Bearer Token认证策略
/// 将从TokenStorage获取的token作为Authorization头添加到请求中
public struct BearerTokenAuthenticationStrategy: AuthenticationStrategy {
    public init() {}
    
    public func apply(to request: URLRequest, context: AuthenticationContext) async throws -> URLRequest {
        var authenticatedRequest = request
        
        // 从token storage获取token
        if let token = await context.tokenStorage.getToken() {
            // 添加Bearer token到Authorization头
            authenticatedRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        return authenticatedRequest
    }
}