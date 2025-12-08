import Foundation

/// 请求生命周期配置
///
/// 定义请求的自动取消策略：
/// - view: 绑定到视图对象，对象销毁时自动取消
/// - persistent: 持久执行，不会自动取消（适用于上传、支付等关键操作）
/// - manual: 手动控制，需要显式取消
public enum Lifecycle {
    /// 绑定到视图
    /// - 触发时机：owner 对象 deinit 时自动取消
    /// - 实现：使用 weak 引用监听
    case view(owner: AnyObject)

    /// 持久执行，不会自动取消
    case persistent

    /// 手动控制
    case manual
}
