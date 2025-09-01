import Foundation

/// 网络引擎协议，抽象了执行网络请求和接收数据的底层机制。
///
/// 这是网络层解耦的核心。任何遵守此协议的类（如默认的 `URLSessionEngine` 或测试用的 `MockNetworkEngine`）
/// 都可以被 `APIClient` 用来执行网络请求。
public protocol NetworkEngine {
    
    /// 执行一个网络请求并返回原始数据和URL响应。
    ///
    /// - Parameter request: 一个 `URLRequest` 对象，由 `APIClient` 根据 `Request` 协议构建。
    /// - Returns: 一个包含 `Data` 和 `URLResponse` 的元组。
    /// - Throws: 如果网络请求失败（例如，无网络连接，DNS错误），将抛出错误。
    func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse)
}