import Foundation

/// 增强版API客户端
/// 集成了请求栈管理、限流策略等高级功能
public final class EnhancedAPIClient {
    
    // MARK: - Dependencies
    
    private let baseAPIClient: APIClient
    private let requestExecutor: RequestExecutor
    
    // MARK: - Initialization
    
    /// 使用现有APIClient和请求执行器初始化
    /// - Parameters:
    ///   - baseAPIClient: 基础API客户端
    ///   - requestExecutor: 请求执行器
    public init(baseAPIClient: APIClient, requestExecutor: RequestExecutor) {
        self.baseAPIClient = baseAPIClient
        self.requestExecutor = requestExecutor
    }
    
    /// 使用建造者模式初始化
    /// - Parameters:
    ///   - baseAPIClient: 基础API客户端
    ///   - builder: 网络栈建造者配置闭包
    public convenience init(
        baseAPIClient: APIClient,
        configureWith builder: (NetworkStackBuilder) -> NetworkStackBuilder
    ) throws {
        let networkExecutor: (any Request) async throws -> Any = { request in
            return try await baseAPIClient.send(request)
        }
        
        let requestExecutor = try builder(NetworkStackBuilder())
            .setNetworkExecutor(networkExecutor)
            .buildRequestExecutor()
        
        self.init(baseAPIClient: baseAPIClient, requestExecutor: requestExecutor)
    }
    
    // MARK: - Public API
    
    /// 发送网络请求（通过请求栈管理）
    /// - Parameter request: 要发送的请求
    /// - Returns: 请求响应
    /// - Throws: 网络错误或限流错误
    public func send<R: Request>(_ request: R) async throws -> R.Response {
        return try await requestExecutor.execute(request)
    }
    
    /// 取消指定请求
    /// - Parameter requestId: 请求ID
    public func cancelRequest(id requestId: String) {
        requestExecutor.cancelRequest(id: requestId)
    }
    
    /// 取消所有请求
    public func cancelAllRequests() {
        requestExecutor.cancelAllRequests()
    }
    
    /// 获取当前活跃请求数
    public var activeRequestCount: Int {
        return requestExecutor.activeRequestCount
    }
}

// MARK: - Factory Methods

public extension EnhancedAPIClient {
    
    /// 创建默认配置的增强API客户端
    /// - Parameter baseAPIClient: 基础API客户端
    /// - Returns: 配置好的增强API客户端
    static func createDefault(baseAPIClient: APIClient) throws -> EnhancedAPIClient {
        return try EnhancedAPIClient(baseAPIClient: baseAPIClient) { builder in
            return NetworkStackFactory.createDefault()
        }
    }
    
    /// 创建严格限制的增强API客户端
    /// - Parameter baseAPIClient: 基础API客户端
    /// - Returns: 配置好的增强API客户端
    static func createStrict(baseAPIClient: APIClient) throws -> EnhancedAPIClient {
        return try EnhancedAPIClient(baseAPIClient: baseAPIClient) { builder in
            return NetworkStackFactory.createStrict()
        }
    }
    
    /// 创建宽松限制的增强API客户端
    /// - Parameter baseAPIClient: 基础API客户端
    /// - Returns: 配置好的增强API客户端
    static func createPermissive(baseAPIClient: APIClient) throws -> EnhancedAPIClient {
        return try EnhancedAPIClient(baseAPIClient: baseAPIClient) { builder in
            return NetworkStackFactory.createPermissive()
        }
    }
}

// MARK: - Request Extension for Enhanced Features

public extension Request {
    /// 便利方法：通过增强API客户端发送请求
    /// - Parameter client: 增强API客户端
    /// - Returns: 请求响应
    func send(through client: EnhancedAPIClient) async throws -> Response {
        return try await client.send(self)
    }
}