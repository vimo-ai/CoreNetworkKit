import Foundation
import MLoggerKit

/// 批量加载器 - DataLoader 模式
///
/// 将多个单独的请求聚合成一个批量请求，优化网络效率：
/// - 在指定时间窗口内收集请求
/// - 达到批量大小或超时后执行
/// - 支持去重
///
/// 使用示例：
/// ```swift
/// let loader = BatchLoader<String, User>(maxBatchSize: 10, maxWaitTime: 0.05) { userIds in
///     // 批量获取用户信息
///     let users = try await api.getUsers(ids: userIds)
///     return Dictionary(uniqueKeysWithValues: users.map { ($0.id, $0) })
/// }
///
/// // 多个调用会自动聚合
/// let user1 = try await loader.load("user1")
/// let user2 = try await loader.load("user2")
/// ```
public actor BatchLoader<Key: Hashable, Value> {
    private let logger = LoggerFactory.network

    // MARK: - Configuration

    private let maxBatchSize: Int
    private let maxWaitTime: TimeInterval
    private let batchFn: ([Key]) async throws -> [Key: Value]

    // MARK: - State

    /// 等待的 continuation 条目
    private struct PendingEntry {
        let continuation: CheckedContinuation<Value, Error>
        let taskId: UUID
    }

    private var pendingKeys: Set<Key> = []
    private var pendingContinuations: [Key: [PendingEntry]] = [:]
    private var batchTask: Task<Void, Never>?

    // MARK: - Initialization

    /// 创建批量加载器
    /// - Parameters:
    ///   - maxBatchSize: 最大批量大小，达到后立即执行
    ///   - maxWaitTime: 最大等待时间（秒），超时后执行
    ///   - batchFn: 批量加载函数，接收 key 数组，返回 key-value 字典
    public init(
        maxBatchSize: Int = 50,
        maxWaitTime: TimeInterval = 0.05,
        batchFn: @escaping ([Key]) async throws -> [Key: Value]
    ) {
        self.maxBatchSize = maxBatchSize
        self.maxWaitTime = maxWaitTime
        self.batchFn = batchFn
    }

    // MARK: - Public Methods

    /// 加载单个 key
    /// - Parameter key: 要加载的 key
    /// - Returns: 对应的 value
    /// - Throws: 加载失败时抛出错误
    public func load(_ key: Key) async throws -> Value {
        let taskId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    await self.enqueue(key: key, continuation: continuation, taskId: taskId)
                }
            }
        } onCancel: {
            Task {
                await self.cancelTask(taskId: taskId, key: key)
            }
        }
    }

    /// 加载多个 key
    /// - Parameter keys: 要加载的 key 数组
    /// - Returns: key-value 字典
    /// - Throws: 加载失败时抛出错误
    public func loadMany(_ keys: [Key]) async throws -> [Key: Value] {
        try await withThrowingTaskGroup(of: (Key, Value).self) { group in
            // 并发加载所有 key
            for key in keys {
                group.addTask {
                    let value = try await self.load(key)
                    return (key, value)
                }
            }

            // 收集结果
            var results: [Key: Value] = [:]
            for try await (key, value) in group {
                results[key] = value
            }

            return results
        }
    }

    /// 清空队列（取消所有等待的请求）
    public func clear() {
        batchTask?.cancel()
        batchTask = nil

        for entries in pendingContinuations.values {
            for entry in entries {
                entry.continuation.resume(throwing: CancellationError())
            }
        }

        pendingKeys.removeAll()
        pendingContinuations.removeAll()
    }

    // MARK: - Private Methods

    /// 将 key 加入队列
    private func enqueue(key: Key, continuation: CheckedContinuation<Value, Error>, taskId: UUID) {
        // 检查任务是否已被取消
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }

        // 添加到等待列表
        pendingKeys.insert(key)
        let entry = PendingEntry(continuation: continuation, taskId: taskId)
        pendingContinuations[key, default: []].append(entry)

        logger.debug("[BatchLoader] Enqueued key, pending count: \(pendingKeys.count)")

        // 检查是否需要立即执行
        if pendingKeys.count >= maxBatchSize {
            logger.debug("[BatchLoader] Batch size reached, dispatching immediately")
            dispatchBatch()
        } else if batchTask == nil {
            // 启动延迟执行任务
            batchTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(maxWaitTime * 1_000_000_000))
                await self.dispatchBatch()
            }
        }
    }

    /// 取消特定任务
    private func cancelTask(taskId: UUID, key: Key) {
        guard var entries = pendingContinuations[key] else { return }

        // 找到并移除对应的 continuation
        if let index = entries.firstIndex(where: { $0.taskId == taskId }) {
            let entry = entries.remove(at: index)
            entry.continuation.resume(throwing: CancellationError())

            if entries.isEmpty {
                pendingContinuations.removeValue(forKey: key)
                pendingKeys.remove(key)
            } else {
                pendingContinuations[key] = entries
            }

            logger.debug("[BatchLoader] Cancelled task for key: \(key)")
        }
    }

    /// 分发批量请求
    private func dispatchBatch() {
        // 取消延迟任务
        batchTask?.cancel()
        batchTask = nil

        // 如果没有待处理的 key，直接返回
        guard !pendingKeys.isEmpty else {
            return
        }

        // 取出当前批次
        let keys = Array(pendingKeys)
        let entries = pendingContinuations
        pendingKeys.removeAll()
        pendingContinuations.removeAll()

        logger.debug("[BatchLoader] Dispatching batch with \(keys.count) keys")

        // 执行批量请求
        Task {
            do {
                let results = try await self.batchFn(keys)

                // 分发结果
                for (key, entryList) in entries {
                    if let value = results[key] {
                        // 成功：返回结果
                        for entry in entryList {
                            entry.continuation.resume(returning: value)
                        }
                    } else {
                        // 失败：key 未找到
                        let error = NetworkError.unknown(NSError(
                            domain: "BatchLoader",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Key not found in batch result: \(key)"]
                        ))
                        for entry in entryList {
                            entry.continuation.resume(throwing: error)
                        }
                    }
                }

                self.logger.debug("[BatchLoader] Batch completed successfully")

            } catch {
                // 批量请求失败，所有等待的请求都失败
                self.logger.error("[BatchLoader] Batch failed: \(error)")

                for entryList in entries.values {
                    for entry in entryList {
                        entry.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }
}
