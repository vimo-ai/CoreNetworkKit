import Foundation

/// 缓存策略
///
/// 定义请求的缓存行为：
/// - none: 不使用缓存
/// - cacheFirst: 优先使用缓存，过期后请求网络
/// - staleWhileRevalidate: 先返回缓存，同时请求网络更新
public enum CachePolicy {
    /// 不使用缓存
    case none

    /// 优先使用缓存，过期后请求网络
    /// - Parameter maxAge: 缓存有效期（秒）
    case cacheFirst(maxAge: TimeInterval)

    /// 先返回缓存，同时请求网络更新
    /// 适用场景：提升用户体验，允许展示过期数据
    case staleWhileRevalidate
}
