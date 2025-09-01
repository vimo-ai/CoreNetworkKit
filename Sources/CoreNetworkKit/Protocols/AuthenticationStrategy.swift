import Foundation

/// 一个上下文对象，为认证策略提供必要的依赖。
/// 这使得策略可以访问共享资源（如令牌存储），而无需与它们的创建紧密耦合。
public struct AuthenticationContext {
    public let tokenStorage: any TokenStorage
    
    public init(tokenStorage: any TokenStorage) {
        self.tokenStorage = tokenStorage
    }
}

/// 一个定义了如何将认证应用于URLRequest的策略协议。
/// 这可能涉及添加头、签署参数或附加令牌。
public protocol AuthenticationStrategy {
    /// 异步地将认证策略应用于给定的URLRequest。
    /// - Parameter request: 原始的 `URLRequest`。
    /// - Parameter context: 提供像令牌存储这样的依赖的上下文。
    /// - Returns: 一个应用了认证的新 `URLRequest`。
    /// - Throws: 如果认证过程失败，则抛出错误。
    func apply(to request: URLRequest, context: AuthenticationContext) async throws -> URLRequest
}

/// 一个你需要在使用 `APIClient` 的项目中定义的协议，
/// 用于抽象令牌的存储和检索。
public protocol TokenStorage {
    func getToken() async -> String?
}