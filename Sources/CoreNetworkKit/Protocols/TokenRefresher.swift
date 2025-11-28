import Foundation

/// 刷新令牌的抽象接口，由上层注入具体实现。
public protocol TokenRefresher {
    /// 触发一次令牌刷新，返回新令牌。
    func refreshToken() async throws -> String
}
