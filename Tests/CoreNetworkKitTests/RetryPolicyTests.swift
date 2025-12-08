import XCTest
@testable import CoreNetworkKit

final class RetryPolicyTests: XCTestCase {

    // MARK: - none 策略测试

    func testNonePolicyMaxAttempts() {
        let policy = RetryPolicy.none
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.maxRetries, 0)
        XCTAssertFalse(policy.allowsRetry)
    }

    func testNonePolicyDelay() {
        let policy = RetryPolicy.none
        XCTAssertEqual(policy.delay(for: 0), 0)
        XCTAssertEqual(policy.delay(for: 1), 0)
    }

    func testNonePolicyCanRetry() {
        let policy = RetryPolicy.none
        XCTAssertFalse(policy.canRetry(attempt: 0))
        XCTAssertFalse(policy.canRetry(attempt: 1))
    }

    // MARK: - fixed 策略测试

    func testFixedPolicyMaxAttempts() {
        let policy = RetryPolicy.fixed(maxAttempts: 3, delay: 1.0)
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.maxRetries, 2)
        XCTAssertTrue(policy.allowsRetry)
    }

    func testFixedPolicyDelay() {
        let policy = RetryPolicy.fixed(maxAttempts: 3, delay: 2.5)

        // 可以重试
        XCTAssertEqual(policy.delay(for: 0), 2.5) // 第一次重试
        XCTAssertEqual(policy.delay(for: 1), 2.5) // 第二次重试

        // 超出重试次数
        XCTAssertEqual(policy.delay(for: 2), 0) // 第三次重试 - 超出
        XCTAssertEqual(policy.delay(for: 3), 0) // 超出
    }

    func testFixedPolicyCanRetry() {
        let policy = RetryPolicy.fixed(maxAttempts: 3, delay: 1.0)

        XCTAssertTrue(policy.canRetry(attempt: 0))  // 可以第一次重试
        XCTAssertTrue(policy.canRetry(attempt: 1))  // 可以第二次重试
        XCTAssertFalse(policy.canRetry(attempt: 2)) // 不能第三次重试（超出）
        XCTAssertFalse(policy.canRetry(attempt: -1)) // 无效
    }

    // MARK: - exponential 策略测试

    func testExponentialPolicyMaxAttempts() {
        let policy = RetryPolicy.exponential(
            maxAttempts: 4,
            initialDelay: 1.0,
            multiplier: 2.0,
            maxDelay: 30
        )
        XCTAssertEqual(policy.maxAttempts, 4)
        XCTAssertEqual(policy.maxRetries, 3)
        XCTAssertTrue(policy.allowsRetry)
    }

    func testExponentialPolicyDelaySequence() {
        let policy = RetryPolicy.exponential(
            maxAttempts: 5,
            initialDelay: 1.0,
            multiplier: 2.0,
            maxDelay: 30
        )

        // 延迟序列：1, 2, 4, 8（4 次重试机会）
        XCTAssertEqual(policy.delay(for: 0), 1.0, accuracy: 0.001) // 1 * 2^0 = 1
        XCTAssertEqual(policy.delay(for: 1), 2.0, accuracy: 0.001) // 1 * 2^1 = 2
        XCTAssertEqual(policy.delay(for: 2), 4.0, accuracy: 0.001) // 1 * 2^2 = 4
        XCTAssertEqual(policy.delay(for: 3), 8.0, accuracy: 0.001) // 1 * 2^3 = 8

        // 超出重试次数
        XCTAssertEqual(policy.delay(for: 4), 0) // 超出
    }

    func testExponentialPolicyMaxDelayClamp() {
        let policy = RetryPolicy.exponential(
            maxAttempts: 10,
            initialDelay: 1.0,
            multiplier: 10.0,
            maxDelay: 30
        )

        // 延迟序列：1, 10, 30(clamped), 30(clamped)...
        XCTAssertEqual(policy.delay(for: 0), 1.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 1), 10.0, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 2), 30.0, accuracy: 0.001)  // clamped from 100
        XCTAssertEqual(policy.delay(for: 3), 30.0, accuracy: 0.001)  // clamped from 1000
    }

    func testExponentialPolicyCanRetry() {
        let policy = RetryPolicy.exponential(
            maxAttempts: 3,
            initialDelay: 1.0,
            multiplier: 2.0,
            maxDelay: 30
        )

        XCTAssertTrue(policy.canRetry(attempt: 0))  // 可以第一次重试
        XCTAssertTrue(policy.canRetry(attempt: 1))  // 可以第二次重试
        XCTAssertFalse(policy.canRetry(attempt: 2)) // 不能第三次重试
    }

    // MARK: - 工厂方法测试

    func testFixedRetryFactory() {
        let policy = RetryPolicy.fixedRetry(maxAttempts: 3, delay: 5.0)
        XCTAssertEqual(policy.maxAttempts, 3)
        XCTAssertEqual(policy.delay(for: 0), 5.0)
    }

    func testExponentialBackoffFactory() {
        let policy = RetryPolicy.exponentialBackoff(
            maxAttempts: 4,
            initialDelay: 0.5,
            multiplier: 3.0,
            maxDelay: 60
        )
        XCTAssertEqual(policy.maxAttempts, 4)
        XCTAssertEqual(policy.delay(for: 0), 0.5, accuracy: 0.001)
        XCTAssertEqual(policy.delay(for: 1), 1.5, accuracy: 0.001)
    }

    // MARK: - 边界测试

    func testMinimalMaxAttempts() {
        let policy = RetryPolicy.fixed(maxAttempts: 1, delay: 1.0)
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.maxRetries, 0)
        XCTAssertFalse(policy.allowsRetry)
        XCTAssertFalse(policy.canRetry(attempt: 0))
    }

    func testInvalidMaxAttemptsClampedToOne() {
        // 使用枚举直接构造（绕过工厂方法的 precondition）
        let policy = RetryPolicy.fixed(maxAttempts: 0, delay: 1.0)
        XCTAssertEqual(policy.maxAttempts, 1, "无效的 maxAttempts 应被限制为 1")
    }

    func testNegativeAttemptReturnsZero() {
        let policy = RetryPolicy.fixed(maxAttempts: 3, delay: 1.0)
        XCTAssertEqual(policy.delay(for: -1), 0)
        XCTAssertFalse(policy.canRetry(attempt: -1))
    }

    // MARK: - Sendable 测试

    func testSendableConformance() async {
        let policy = RetryPolicy.exponential(
            maxAttempts: 3,
            initialDelay: 1.0,
            multiplier: 2.0,
            maxDelay: 30
        )

        // 在并发上下文中使用
        let delay = await Task {
            policy.delay(for: 0)
        }.value

        XCTAssertEqual(delay, 1.0, accuracy: 0.001)
    }
}
