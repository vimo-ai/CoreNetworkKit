import Foundation
import MLoggerKit

/// 控制门 - 处理防抖、节流、去重
///
/// 功能：
/// - 防抖（debounce）：等待指定时间无新请求后才执行
/// - 节流（throttle）：限制执行频率
/// - 去重（deduplicate）：相同请求复用正在进行的任务
public actor ControlGate {
    private let logger = LoggerFactory.network

    /// 防抖计时器：存储每个 CacheKey 的防抖任务
    private var debounceTimers: [CacheKey: Task<Void, Error>] = [:]

    /// 节流记录：存储每个 CacheKey 的最后执行时间
    private var throttleTimestamps: [CacheKey: Date] = [:]

    /// 去重记录：存储正在执行的任务
    private var inFlightTasks: [CacheKey: Any] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// 通过控制门检查（原子化去重检查和占位）
    /// - Parameter task: 网络任务
    /// - Returns: 检查结果
    public func pass(task: NetworkTask) async throws -> PassResult {
        let cacheKey = task.cacheKey
        let control = task.config.control

        try Task.checkCancellation()

        // 1. 去重检查（原子化：检查并立即占位）
        if control.deduplicate {
            let deduplicateResult = checkAndReserveDeduplicate(cacheKey: cacheKey)
            switch deduplicateResult {
            case .existing(let existingTask):
                logger.debug("[ControlGate] Request deduplicated: \(cacheKey.value)")
                return .waitingForData(existingTask)
            case .reserved:
                // 已占位，继续执行
                break
            case .notApplicable:
                break
            }
        }

        // 2. 节流检查
        if let throttle = control.throttle {
            try await applyThrottle(cacheKey: cacheKey, interval: throttle)
        }

        // 3. 防抖检查
        if let debounce = control.debounce {
            try await applyDebounce(cacheKey: cacheKey, interval: debounce)
        }

        logger.debug("[ControlGate] Request passed: \(cacheKey.value)")
        return .proceed
    }

    /// 更新已占位的任务为实际执行的任务
    public func updateInFlight(cacheKey: CacheKey, task: Task<Data, Error>) {
        inFlightTasks[cacheKey] = task
    }

    /// 取消注册正在执行的任务
    public func unregisterInFlight(cacheKey: CacheKey) {
        inFlightTasks.removeValue(forKey: cacheKey)
    }

    // MARK: - 去重辅助

    private enum DeduplicateResult {
        case existing(Task<Data, Error>)  // 已有任务正在执行
        case reserved                      // 成功占位
        case notApplicable                 // 不适用
    }

    /// 原子化检查并占位（解决竞态问题）
    private func checkAndReserveDeduplicate(cacheKey: CacheKey) -> DeduplicateResult {
        // 检查是否有正在执行的任务
        if let existingTask = inFlightTasks[cacheKey] as? Task<Data, Error> {
            return .existing(existingTask)
        }

        // 没有正在执行的任务，立即占位（用 placeholder 标记）
        // 实际任务会在 executeWithRetry 中通过 updateInFlight 更新
        inFlightTasks[cacheKey] = PlaceholderTask()

        return .reserved
    }

    /// 占位标记（表示任务即将开始但还未创建）
    private final class PlaceholderTask {}

    /// 清空所有状态
    public func clear() {
        debounceTimers.values.forEach { $0.cancel() }
        debounceTimers.removeAll()
        throttleTimestamps.removeAll()
        inFlightTasks.removeAll()
    }

    // MARK: - Private Methods

    /// 应用节流
    private func applyThrottle(cacheKey: CacheKey, interval: TimeInterval) async throws {
        if let lastTimestamp = throttleTimestamps[cacheKey] {
            let elapsed = Date().timeIntervalSince(lastTimestamp)
            if elapsed < interval {
                let remaining = interval - elapsed
                logger.debug("[ControlGate] Throttling request for \(remaining)s: \(cacheKey.value)")
                try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
        throttleTimestamps[cacheKey] = Date()
    }

    /// 应用防抖
    private func applyDebounce(cacheKey: CacheKey, interval: TimeInterval) async throws {
        // 取消之前的防抖计时器
        debounceTimers[cacheKey]?.cancel()

        // 创建新的防抖计时器
        let timer = Task<Void, Error> {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        debounceTimers[cacheKey] = timer

        logger.debug("[ControlGate] Debouncing request for \(interval)s: \(cacheKey.value)")

        // 等待防抖时间
        try await timer.value

        // 清理计时器
        debounceTimers.removeValue(forKey: cacheKey)

        try Task.checkCancellation()
    }
}

// MARK: - PassResult

/// 控制门检查结果
public enum PassResult {
    /// 可以继续执行
    case proceed

    /// 等待正在执行的任务（返回 Data）
    case waitingForData(Task<Data, Error>)
}
