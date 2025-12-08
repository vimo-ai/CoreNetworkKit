import Foundation

/// 任务配置
///
/// 定义请求执行的各种策略：
/// - lifecycle: 生命周期管理
/// - control: 控制策略（防抖、节流、去重、优先级）
/// - cache: 缓存策略
/// - retry: 重试策略
/// - timeout: 单次请求超时
/// - totalTimeout: 整体超时（包含所有重试）
public struct TaskConfig {
    /// 生命周期管理
    public var lifecycle: Lifecycle

    /// 控制策略
    public var control: ControlPolicy

    /// 缓存策略
    public var cache: CachePolicy

    /// 重试策略
    public var retry: RetryPolicy

    /// 单次请求超时（秒）
    public var timeout: TimeInterval?

    /// 整体超时，包含所有重试（秒）
    public var totalTimeout: TimeInterval?

    /// 创建任务配置
    /// - Parameters:
    ///   - lifecycle: 生命周期管理，默认为 manual
    ///   - control: 控制策略，默认为空策略
    ///   - cache: 缓存策略，默认为 none
    ///   - retry: 重试策略，默认为 none
    ///   - timeout: 单次请求超时
    ///   - totalTimeout: 整体超时
    public init(
        lifecycle: Lifecycle = .manual,
        control: ControlPolicy = ControlPolicy(),
        cache: CachePolicy = .none,
        retry: RetryPolicy = .none,
        timeout: TimeInterval? = nil,
        totalTimeout: TimeInterval? = nil
    ) {
        self.lifecycle = lifecycle
        self.control = control
        self.cache = cache
        self.retry = retry
        self.timeout = timeout
        self.totalTimeout = totalTimeout
    }
}
