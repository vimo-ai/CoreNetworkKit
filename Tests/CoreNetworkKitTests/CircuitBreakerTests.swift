import XCTest
@testable import CoreNetworkKit

final class CircuitBreakerTests: XCTestCase {

    // MARK: - 初始状态为 CLOSED

    func testInitialStateIsClosed() async {
        let breaker = CircuitBreaker(config: defaultConfig())
        let state = await breaker.state
        XCTAssertEqual(state, .closed)
    }

    // MARK: - 成功时保持 CLOSED

    func testStaysClosedOnSuccess() async throws {
        let breaker = CircuitBreaker(config: defaultConfig())

        let result = try await breaker.execute { "ok" }
        XCTAssertEqual(result, "ok")

        let state = await breaker.state
        XCTAssertEqual(state, .closed)
    }

    // MARK: - 连续失败达到阈值后从 CLOSED 转为 OPEN

    func testTransitionsClosedToOpenAfterThreshold() async {
        let transitions = TransitionLog()
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 3,
            resetTimeout: 60,
            onStateChange: { from, to in transitions.append((from, to)) }
        ))

        // 连续 3 次失败
        for _ in 0 ..< 3 {
            do {
                let _: String = try await breaker.execute {
                    throw self.networkError()
                }
                XCTFail("Should have thrown")
            } catch {
                // expected
            }
        }

        let state = await breaker.state
        XCTAssertEqual(state, .open)
        XCTAssertEqual(transitions.values.count, 1)
        XCTAssertEqual(transitions.values[0].from, .closed)
        XCTAssertEqual(transitions.values[0].to, .open)
    }

    // MARK: - OPEN 状态拒绝请求并抛出 CircuitOpenError

    func testRejectsWithCircuitOpenErrorWhenOpen() async {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 60
        ))

        // 触发熔断
        do {
            let _: String = try await breaker.execute { throw self.networkError() }
        } catch {}

        let state = await breaker.state
        XCTAssertEqual(state, .open)

        // 后续请求应被拒绝
        do {
            let _: String = try await breaker.execute { "should not run" }
            XCTFail("Should have thrown CircuitOpenError")
        } catch let error as CircuitOpenError {
            XCTAssertEqual(error.state, .open)
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    // MARK: - resetTimeout 后从 OPEN 转为 HALF_OPEN

    func testTransitionsOpenToHalfOpenAfterTimeout() async throws {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 0.1 // 100ms
        ))

        // 触发熔断
        do {
            let _: String = try await breaker.execute { throw self.networkError() }
        } catch {}

        let openState = await breaker.state
        XCTAssertEqual(openState, .open)

        // 等待 resetTimeout + 余量
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        let state = await breaker.state
        XCTAssertEqual(state, .halfOpen)
    }

    // MARK: - HALF_OPEN 成功后转为 CLOSED

    func testTransitionsHalfOpenToClosedOnSuccess() async throws {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 0.1
        ))

        // 触发熔断
        do {
            let _: String = try await breaker.execute { throw self.networkError() }
        } catch {}

        // 等待进入 half-open
        try await Task.sleep(nanoseconds: 200_000_000)
        let halfOpenState = await breaker.state
        XCTAssertEqual(halfOpenState, .halfOpen)

        // 成功的探测请求
        let result = try await breaker.execute { "probe-ok" }
        XCTAssertEqual(result, "probe-ok")

        let state = await breaker.state
        XCTAssertEqual(state, .closed)
    }

    // MARK: - HALF_OPEN 失败后转为 OPEN

    func testTransitionsHalfOpenToOpenOnFailure() async throws {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 0.1
        ))

        // 触发熔断
        do {
            let _: String = try await breaker.execute { throw self.networkError() }
        } catch {}

        // 等待进入 half-open
        try await Task.sleep(nanoseconds: 200_000_000)
        let halfOpenState = await breaker.state
        XCTAssertEqual(halfOpenState, .halfOpen)

        // 失败的探测请求
        do {
            let _: String = try await breaker.execute { throw self.networkError() }
        } catch {}

        let state = await breaker.state
        XCTAssertEqual(state, .open)
    }

    // MARK: - reset() 恢复到 CLOSED

    func testResetReturnsToClosed() async {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 1,
            resetTimeout: 60
        ))

        // 触发熔断
        do {
            let _: String = try await breaker.execute { throw self.networkError() }
        } catch {}

        let openState = await breaker.state
        XCTAssertEqual(openState, .open)

        // 手动重置
        await breaker.reset()

        let state = await breaker.state
        XCTAssertEqual(state, .closed)

        // 重置后可以正常执行
        let result = try? await breaker.execute { "after-reset" }
        XCTAssertEqual(result, "after-reset")
    }

    // MARK: - onStateChange 回调触发

    func testOnStateChangeCallbackFires() async {
        let transitions = TransitionLog()
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 2,
            resetTimeout: 60,
            onStateChange: { from, to in transitions.append((from, to)) }
        ))

        // 第一次失败 — 不触发状态变化
        do { let _: String = try await breaker.execute { throw self.networkError() } } catch {}
        XCTAssertTrue(transitions.values.isEmpty)

        // 第二次失败 — 触发 CLOSED → OPEN
        do { let _: String = try await breaker.execute { throw self.networkError() } } catch {}
        XCTAssertEqual(transitions.values.count, 1)
        XCTAssertEqual(transitions.values[0].from, .closed)
        XCTAssertEqual(transitions.values[0].to, .open)
    }

    // MARK: - shouldTrip 过滤不匹配的错误

    func testNonMatchingErrorsDoNotCount() async {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 2,
            resetTimeout: 60,
            shouldTrip: { error in error.isTimeout } // 仅 timeout 才计数
        ))

        // 网络错误不匹配 shouldTrip，不计入失败
        for _ in 0 ..< 5 {
            do {
                let _: String = try await breaker.execute { throw self.networkError() }
            } catch {}
        }

        let state = await breaker.state
        XCTAssertEqual(state, .closed, "Non-matching errors should not trip the breaker")
    }

    func testMatchingErrorsDoCount() async {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 2,
            resetTimeout: 60,
            shouldTrip: { error in error.isTimeout }
        ))

        // timeout 错误匹配 shouldTrip
        for _ in 0 ..< 2 {
            do {
                let _: String = try await breaker.execute { throw self.timeoutError() }
            } catch {}
        }

        let state = await breaker.state
        XCTAssertEqual(state, .open, "Matching errors should trip the breaker")
    }

    // MARK: - 失败计数在成功后重置

    func testFailureCountResetsOnSuccess() async throws {
        let breaker = CircuitBreaker(config: CircuitBreakerConfig(
            failureThreshold: 3,
            resetTimeout: 60
        ))

        // 2 次失败（阈值 3）
        for _ in 0 ..< 2 {
            do { let _: String = try await breaker.execute { throw self.networkError() } } catch {}
        }

        // 1 次成功 — 重置失败计数
        _ = try await breaker.execute { "success" }

        // 再次 2 次失败 — 仍不到阈值
        for _ in 0 ..< 2 {
            do { let _: String = try await breaker.execute { throw self.networkError() } } catch {}
        }

        let state = await breaker.state
        XCTAssertEqual(state, .closed, "Success should reset failure count")
    }

    // MARK: - Private Helpers

    private func defaultConfig() -> CircuitBreakerConfig {
        CircuitBreakerConfig(failureThreshold: 5, resetTimeout: 30)
    }

    private func networkError() -> RequestError {
        RequestError(code: .network, url: "https://api.test.com", method: "GET", message: "network error")
    }

    private func timeoutError() -> RequestError {
        RequestError(code: .timeout, url: "https://api.test.com", method: "GET", message: "timeout")
    }
}

// MARK: - TransitionLog

/// 线程安全的状态转换记录器
private final class TransitionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(from: CircuitState, to: CircuitState)] = []

    func append(_ transition: (CircuitState, CircuitState)) {
        lock.lock()
        entries.append((from: transition.0, to: transition.1))
        lock.unlock()
    }

    var values: [(from: CircuitState, to: CircuitState)] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}
