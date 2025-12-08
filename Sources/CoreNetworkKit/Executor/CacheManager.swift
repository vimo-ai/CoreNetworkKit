import Foundation
import MLoggerKit

/// 缓存管理器
///
/// 提供内存缓存能力：
/// - 支持 TTL 过期
/// - 线程安全（actor）
/// - 类型安全的读写
public actor CacheManager {
    private let logger = LoggerFactory.network

    /// 缓存条目
    private struct CacheEntry {
        let data: Data
        let timestamp: Date
        let maxAge: TimeInterval?

        /// 判断缓存是否过期
        func isExpired() -> Bool {
            guard let maxAge = maxAge else {
                return false // 无过期时间
            }
            let elapsed = Date().timeIntervalSince(timestamp)
            return elapsed > maxAge
        }
    }

    /// 内存缓存存储
    private var storage: [CacheKey: CacheEntry] = [:]

    // MARK: - Initialization

    public init() {}

    // MARK: - Public Methods

    /// 读取缓存
    /// - Parameters:
    ///   - key: 缓存键
    ///   - maxAge: 最大有效期（秒），nil 表示永不过期
    /// - Returns: 解码后的对象，如果不存在或已过期则返回 nil
    public func read<T: Decodable>(key: CacheKey, maxAge: TimeInterval?) async -> T? {
        guard let entry = storage[key] else {
            logger.debug("[CacheManager] Cache miss: \(key.value)")
            return nil
        }

        // 检查是否过期（使用参数指定的 maxAge，如果没有则使用条目自带的 maxAge）
        let effectiveMaxAge = maxAge ?? entry.maxAge
        if let maxAge = effectiveMaxAge {
            let elapsed = Date().timeIntervalSince(entry.timestamp)
            if elapsed > maxAge {
                logger.debug("[CacheManager] Cache expired: \(key.value) (age: \(elapsed)s, maxAge: \(maxAge)s)")
                storage.removeValue(forKey: key)
                return nil
            }
        }

        // 尝试解码
        do {
            let decoder = JSONDecoder()
            let value = try decoder.decode(T.self, from: entry.data)
            logger.debug("[CacheManager] Cache hit: \(key.value)")
            return value
        } catch {
            logger.error("[CacheManager] Cache decode failed: \(key.value), error: \(error)")
            storage.removeValue(forKey: key) // 删除损坏的缓存
            return nil
        }
    }

    /// 写入缓存
    /// - Parameters:
    ///   - key: 缓存键
    ///   - value: 要缓存的对象
    ///   - maxAge: 最大有效期（秒），nil 表示永不过期
    public func write<T: Encodable>(key: CacheKey, value: T, maxAge: TimeInterval?) async {
        do {
            let encoder = JSONEncoder()
            let data = try encoder.encode(value)

            let entry = CacheEntry(
                data: data,
                timestamp: Date(),
                maxAge: maxAge
            )
            storage[key] = entry
            logger.debug("[CacheManager] Cache written: \(key.value), size: \(data.count) bytes")
        } catch {
            logger.error("[CacheManager] Cache encode failed: \(key.value), error: \(error)")
        }
    }

    /// 使失效
    /// - Parameter key: 缓存键
    public func invalidate(key: CacheKey) async {
        if storage.removeValue(forKey: key) != nil {
            logger.debug("[CacheManager] Cache invalidated: \(key.value)")
        }
    }

    /// 清空所有缓存
    public func clear() async {
        let count = storage.count
        storage.removeAll()
        logger.debug("[CacheManager] Cache cleared: \(count) entries removed")
    }

    /// 清理过期缓存
    public func cleanupExpired() async {
        let beforeCount = storage.count
        storage = storage.filter { !$0.value.isExpired() }
        let afterCount = storage.count
        let removedCount = beforeCount - afterCount
        if removedCount > 0 {
            logger.debug("[CacheManager] Expired cache cleaned: \(removedCount) entries removed")
        }
    }
}
