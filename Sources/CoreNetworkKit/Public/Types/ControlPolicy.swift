import Foundation

/// 请求控制策略
///
/// 提供防抖、节流、去重和优先级控制能力：
/// - debounce: 等待指定时间无新请求后才执行
/// - throttle: 限制执行频率
/// - deduplicate: 相同请求复用正在进行的任务
/// - priority: 请求优先级
public struct ControlPolicy {
    /// 防抖：等待指定时间无新请求后才执行
    /// 适用场景：搜索框输入
    public var debounce: TimeInterval?

    /// 节流：限制执行频率
    /// 适用场景：滚动加载
    public var throttle: TimeInterval?

    /// 去重：相同请求复用正在进行的任务
    /// 适用场景：避免重复请求
    public var deduplicate: Bool

    /// 请求优先级
    public var priority: Priority

    /// 创建控制策略
    /// - Parameters:
    ///   - debounce: 防抖时间间隔
    ///   - throttle: 节流时间间隔
    ///   - deduplicate: 是否去重
    ///   - priority: 请求优先级
    public init(
        debounce: TimeInterval? = nil,
        throttle: TimeInterval? = nil,
        deduplicate: Bool = false,
        priority: Priority = .normal
    ) {
        self.debounce = debounce
        self.throttle = throttle
        self.deduplicate = deduplicate
        self.priority = priority
    }

    /// 请求优先级
    public enum Priority: Int, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}
