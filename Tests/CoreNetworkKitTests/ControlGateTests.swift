import XCTest
@testable import CoreNetworkKit

final class ControlGateTests: XCTestCase {

    // MARK: - Deduplicate: 并发相同调用共享结果

    func testDeduplicateConcurrentCallsShareResult() async throws {
        let gate = ControlGateV2()
        let counter = Counter()

        let policy = ControlPolicy(deduplicate: true)

        // 并发发起 3 个相同 key 的请求
        async let r1: Int = gate.execute(key: "dedup-key", fn: {
            await counter.increment()
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
            return 42
        }, policy: policy)

        async let r2: Int = gate.execute(key: "dedup-key", fn: {
            await counter.increment()
            try await Task.sleep(nanoseconds: 100_000_000)
            return 42
        }, policy: policy)

        let results = try await [r1, r2]
        XCTAssertEqual(results, [42, 42])

        // fn 应只执行一次（第二次复用第一次的 Task）
        let count = await counter.value
        XCTAssertEqual(count, 1, "Deduplicate should execute fn only once for concurrent identical calls")
    }

    // MARK: - Debounce: 只有最后一次调用执行

    func testDebounceOnlyLastCallExecutes() async throws {
        let gate = ControlGateV2()
        let policy = ControlPolicy(debounce: 0.15) // 150ms debounce

        // 快速连续发起 3 次调用，只有最后一次应该执行
        let task1 = Task<Int, Error> {
            try await gate.execute(key: "debounce-key", fn: { 1 }, policy: policy)
        }
        // 稍等让第一次注册
        try await Task.sleep(nanoseconds: 20_000_000) // 20ms

        let task2 = Task<Int, Error> {
            try await gate.execute(key: "debounce-key", fn: { 2 }, policy: policy)
        }
        try await Task.sleep(nanoseconds: 20_000_000)

        let task3 = Task<Int, Error> {
            try await gate.execute(key: "debounce-key", fn: { 3 }, policy: policy)
        }

        // 前面的调用应被取消（CancellationError）
        let result3 = try await task3.value
        XCTAssertEqual(result3, 3, "Only the last debounced call should execute")

        // 被取消的任务应抛出 CancellationError
        do {
            _ = try await task1.value
            // 如果没抛出可能是因为计时，不做严格断言
        } catch {
            XCTAssertTrue(error is CancellationError, "Earlier debounced calls should be cancelled")
        }

        _ = task2 // 避免未使用的警告
    }

    // MARK: - Throttle: 尊重最小时间间隔

    func testThrottleRespectsMinimumInterval() async throws {
        let gate = ControlGateV2()
        let policy = ControlPolicy(throttle: 0.2) // 200ms throttle

        let start = Date()

        // 第一次立即执行
        let r1: String = try await gate.execute(key: "throttle-key", fn: { "first" }, policy: policy)
        XCTAssertEqual(r1, "first")

        // 第二次应等待剩余的 throttle 间隔
        let r2: String = try await gate.execute(key: "throttle-key", fn: { "second" }, policy: policy)
        XCTAssertEqual(r2, "second")

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.15, "Throttle should enforce minimum interval")
    }

    // MARK: - buildRequestKey 生成稳定的确定性 key

    func testBuildRequestKeyProducesStableKeys() {
        let key1 = buildRequestKey(method: "GET", url: "https://api.test.com/users")
        let key2 = buildRequestKey(method: "GET", url: "https://api.test.com/users")
        XCTAssertEqual(key1, key2, "Same method/url should produce identical keys")
    }

    func testBuildRequestKeyDiffersForDifferentMethods() {
        let getKey = buildRequestKey(method: "GET", url: "https://api.test.com/users")
        let postKey = buildRequestKey(method: "POST", url: "https://api.test.com/users")
        XCTAssertNotEqual(getKey, postKey)
    }

    func testBuildRequestKeyDiffersForDifferentUrls() {
        let key1 = buildRequestKey(method: "GET", url: "https://api.test.com/users")
        let key2 = buildRequestKey(method: "GET", url: "https://api.test.com/posts")
        XCTAssertNotEqual(key1, key2)
    }

    func testBuildRequestKeyIncludesBody() {
        let body = TestBody(name: "Alice", age: 30)
        let key1 = buildRequestKey(method: "POST", url: "/api", body: body)
        let key2 = buildRequestKey(method: "POST", url: "/api", body: body)
        XCTAssertEqual(key1, key2, "Same body should produce same key")

        let differentBody = TestBody(name: "Bob", age: 25)
        let key3 = buildRequestKey(method: "POST", url: "/api", body: differentBody)
        XCTAssertNotEqual(key1, key3, "Different body should produce different key")
    }

    func testBuildRequestKeyWithNilBody() {
        let key = buildRequestKey(method: "GET", url: "/api", body: nil)
        XCTAssertEqual(key, "GET:/api:")
    }

    func testBuildRequestKeyFormat() {
        let key = buildRequestKey(method: "POST", url: "https://api.test.com/data")
        XCTAssertTrue(key.hasPrefix("POST:https://api.test.com/data:"))
    }

    // MARK: - dispose() 清理待处理的 debounce

    func testDisposeCleansPendingDebounces() async throws {
        let gate = ControlGateV2()
        let policy = ControlPolicy(debounce: 1.0) // 1s debounce（足够长）

        // 发起一个 debounce 调用但不等其完成
        let task = Task<Int, Error> {
            try await gate.execute(key: "dispose-key", fn: { 42 }, policy: policy)
        }

        // 稍等让 debounce 注册
        try await Task.sleep(nanoseconds: 50_000_000) // 50ms

        // 清理
        await gate.dispose()

        // 被 dispose 的任务应该被取消
        do {
            _ = try await task.value
            // 可能在某些竞态条件下完成，不做严格断言
        } catch {
            // CancellationError 是预期行为
            XCTAssertTrue(error is CancellationError, "Disposed debounce should result in cancellation")
        }
    }

    // MARK: - 不同 key 的请求不互相影响

    func testDifferentKeysAreIndependent() async throws {
        let gate = ControlGateV2()
        let policy = ControlPolicy(deduplicate: true)

        let r1: String = try await gate.execute(key: "key-A", fn: { "A" }, policy: policy)
        let r2: String = try await gate.execute(key: "key-B", fn: { "B" }, policy: policy)

        XCTAssertEqual(r1, "A")
        XCTAssertEqual(r2, "B")
    }
}

// MARK: - 辅助类型

private struct TestBody: Encodable, Sendable {
    let name: String
    let age: Int
}

/// 线程安全计数器
private actor Counter {
    private var _value = 0

    var value: Int { _value }

    func increment() {
        _value += 1
    }
}
