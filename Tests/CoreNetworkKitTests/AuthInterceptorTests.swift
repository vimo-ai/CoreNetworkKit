import XCTest
@testable import CoreNetworkKit

final class AuthInterceptorTests: XCTestCase {

    // MARK: - 401 错误触发 onUnauthorized

    func testCallsOnUnauthorizedFor401() async throws {
        let callLog = CallLog()
        let interceptor = createAuthInterceptor(config: AuthInterceptorConfig(
            onUnauthorized: { error in callLog.record(error) }
        ))

        let error = RequestError(code: .auth, status: 401, url: "/secure", method: "GET", message: "unauthorized")
        _ = try await interceptor.onError(error)

        XCTAssertEqual(callLog.count, 1)
        XCTAssertEqual(callLog.lastError?.status, 401)
    }

    // MARK: - 403 错误触发 onUnauthorized

    func testCallsOnUnauthorizedFor403() async throws {
        let callLog = CallLog()
        let interceptor = createAuthInterceptor(config: AuthInterceptorConfig(
            onUnauthorized: { error in callLog.record(error) }
        ))

        let error = RequestError(code: .auth, status: 403, url: "/admin", method: "GET", message: "forbidden")
        _ = try await interceptor.onError(error)

        XCTAssertEqual(callLog.count, 1)
        XCTAssertEqual(callLog.lastError?.status, 403)
    }

    // MARK: - 其他状态码不触发

    func testDoesNotCallForOtherStatusCodes() async throws {
        let callLog = CallLog()
        let interceptor = createAuthInterceptor(config: AuthInterceptorConfig(
            onUnauthorized: { error in callLog.record(error) }
        ))

        let error404 = RequestError(code: .http, status: 404, url: "/missing", method: "GET", message: "not found")
        _ = try await interceptor.onError(error404)

        let error500 = RequestError(code: .http, status: 500, url: "/broken", method: "GET", message: "server error")
        _ = try await interceptor.onError(error500)

        XCTAssertEqual(callLog.count, 0, "Should not call onUnauthorized for non-auth status codes")
    }

    func testDoesNotCallForNilStatus() async throws {
        let callLog = CallLog()
        let interceptor = createAuthInterceptor(config: AuthInterceptorConfig(
            onUnauthorized: { error in callLog.record(error) }
        ))

        let error = RequestError(code: .network, url: "/api", method: "GET", message: "no connection")
        _ = try await interceptor.onError(error)

        XCTAssertEqual(callLog.count, 0, "Should not call onUnauthorized when status is nil")
    }

    // MARK: - 自定义 statusCodes 列表

    func testCustomStatusCodesList() async throws {
        let callLog = CallLog()
        let interceptor = createAuthInterceptor(config: AuthInterceptorConfig(
            onUnauthorized: { error in callLog.record(error) },
            statusCodes: [401, 419] // 自定义列表，不包含 403
        ))

        // 401 仍应触发
        let error401 = RequestError(code: .auth, status: 401, url: "/a", method: "GET", message: "unauth")
        _ = try await interceptor.onError(error401)
        XCTAssertEqual(callLog.count, 1)

        // 419 应触发
        let error419 = RequestError(code: .auth, status: 419, url: "/b", method: "GET", message: "session expired")
        _ = try await interceptor.onError(error419)
        XCTAssertEqual(callLog.count, 2)

        // 403 不在自定义列表中，不应触发
        let error403 = RequestError(code: .auth, status: 403, url: "/c", method: "GET", message: "forbidden")
        _ = try await interceptor.onError(error403)
        XCTAssertEqual(callLog.count, 2, "403 should not trigger with custom statusCodes [401, 419]")
    }

    // MARK: - 错误对象原样返回

    func testReturnsErrorUnchanged() async throws {
        let interceptor = createAuthInterceptor(config: AuthInterceptorConfig(
            onUnauthorized: { _ in }
        ))

        let error = RequestError(code: .auth, status: 401, url: "/api", method: "POST", message: "unauthorized")
        let result = try await interceptor.onError(error)

        XCTAssertEqual(result.code, .auth)
        XCTAssertEqual(result.status, 401)
        XCTAssertEqual(result.url, "/api")
        XCTAssertEqual(result.method, "POST")
        XCTAssertEqual(result.message, "unauthorized")
    }
}

// MARK: - 辅助类型

/// 线程安全的调用记录器
private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [RequestError] = []

    func record(_ error: RequestError) {
        lock.lock()
        errors.append(error)
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return errors.count
    }

    var lastError: RequestError? {
        lock.lock()
        defer { lock.unlock() }
        return errors.last
    }
}
