import Foundation
import OSLog

/// 使用 Apple 原生 `URLSession` 实现 `NetworkEngine` 协议的默认网络引擎。
public final class URLSessionEngine: NetworkEngine {
    
    private let session: URLSession
    private let logger = Logger(subsystem: "com.example.CoreNetworkKit", category: "URLSessionEngine")
    
    /// 初始化一个新的 `URLSessionEngine`。
    /// - Parameter configuration: 用于 `URLSession` 的配置。默认为 `.default`。
    public init(configuration: URLSessionConfiguration = .default) {
        // 为调试器环境优化配置
        let optimizedConfig = Self.optimizeConfigurationForDebugging(configuration)
        
        // 调试 URLSession 配置
        // logger.debug("URLSessionEngine 初始化配置:")
        // logger.debug("- timeoutIntervalForRequest: \(optimizedConfig.timeoutIntervalForRequest)")
        // logger.debug("- timeoutIntervalForResource: \(optimizedConfig.timeoutIntervalForResource)")
        // logger.debug("- httpMaximumConnectionsPerHost: \(optimizedConfig.httpMaximumConnectionsPerHost)")
        // logger.debug("- networkServiceType: \(optimizedConfig.networkServiceType.rawValue)")
        
        self.session = URLSession(configuration: optimizedConfig)
    }
    
    /// 为调试器环境优化URLSession配置
    private static func optimizeConfigurationForDebugging(_ config: URLSessionConfiguration) -> URLSessionConfiguration {
        let optimized = config.copy() as! URLSessionConfiguration
        
        // 在调试环境下适当增加超时时间
        #if DEBUG
        if optimized.timeoutIntervalForRequest < 30 {
            optimized.timeoutIntervalForRequest = 30 // 增加到30秒
        }
        if optimized.timeoutIntervalForResource < 120 {
            optimized.timeoutIntervalForResource = 120 // 增加到2分钟
        }
        #endif
        
        return optimized
    }
    
    /// 使用 `URLSession` 的 `data(for:)` async/await 方法执行请求。
    public func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // logger.debug("网络请求: \(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "Unknown URL")")
        // logger.debug("请求超时设置: \(request.timeoutInterval)s")
        
        return try await performNetworkRequest(request)
    }
    
    /// 执行网络请求
    private func performNetworkRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse {
                // logger.debug("网络响应: \(httpResponse.statusCode)")
            }
            
            return (data, response)
            
        } catch {
            // 详细的错误处理和日志记录
            return try handleNetworkError(error, request: request)
        }
    }
    
    /// 处理网络错误
    private func handleNetworkError(_ error: Error, request: URLRequest) throws -> (Data, URLResponse) {
        logger.error("网络请求失败: \(error.localizedDescription)")
        
        // 特殊处理取消错误
        if let nsError = error as NSError?, nsError.code == NSURLErrorCancelled {
            logger.debug("请求取消: \(request.url?.absoluteString ?? "Unknown URL")")
        }
        
        throw error
    }
}