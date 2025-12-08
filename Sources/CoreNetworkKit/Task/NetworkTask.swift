import Foundation

/// 网络任务
///
/// 网络请求的最小执行单元，包含：
/// - request: 请求定义（URLRequest）
/// - config: 执行配置（生命周期、缓存、重试等）
public struct NetworkTask {
    /// 请求对象
    public let request: URLRequest

    /// 任务配置
    public var config: TaskConfig

    /// 缓存键（用于缓存和去重）
    public let cacheKey: CacheKey

    /// 创建网络任务
    /// - Parameters:
    ///   - request: URLRequest 对象
    ///   - config: 任务配置
    ///   - cacheKey: 缓存键
    public init(
        request: URLRequest,
        config: TaskConfig = TaskConfig(),
        cacheKey: CacheKey
    ) {
        self.request = request
        self.config = config
        self.cacheKey = cacheKey
    }
}
