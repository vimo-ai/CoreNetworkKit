import XCTest
@testable import CoreNetworkKit

final class TracingInterceptorTests: XCTestCase {

    // MARK: - 注入 x-request-id header

    func testInjectsRequestIdHeader() async throws {
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: { "test-id-001" }
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/users", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["x-request-id"], "test-id-001")
    }

    // MARK: - 已有 id 时传播 x-parent-request-id

    func testPropagatesParentRequestId() async throws {
        var idCounter = 0
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: {
                idCounter += 1
                return "gen-\(idCounter)"
            }
        ))

        // 请求已有 x-request-id
        let config = RequestConfig(
            url: "https://api.test.com/v1/data",
            method: .post,
            headers: ["x-request-id": "existing-parent-id"]
        )
        let result = try await interceptor.onRequest(config)

        // 原有 id 应成为 parent
        XCTAssertEqual(result.headers["x-parent-request-id"], "existing-parent-id")
        // 新生成的 id 替换原有
        XCTAssertEqual(result.headers["x-request-id"], "gen-1")
    }

    func testNoParentHeaderWhenNoExistingId() async throws {
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: { "fresh-id" }
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/users", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["x-request-id"], "fresh-id")
        XCTAssertNil(result.headers["x-parent-request-id"], "Should not set parent header when no existing id")
    }

    // MARK: - onTrace 回调

    func testOnTraceCallbackFires() async throws {
        var tracedContexts: [TraceContext] = []
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: { "traced-id" },
            onTrace: { context in tracedContexts.append(context) }
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/items", method: .post)
        _ = try await interceptor.onRequest(config)

        XCTAssertEqual(tracedContexts.count, 1)
        XCTAssertEqual(tracedContexts[0].requestId, "traced-id")
        XCTAssertEqual(tracedContexts[0].method, "POST")
        XCTAssertEqual(tracedContexts[0].url, "https://api.test.com/v1/items")
        XCTAssertNil(tracedContexts[0].parentRequestId)
    }

    func testOnTraceCallbackWithParent() async throws {
        var tracedContexts: [TraceContext] = []
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: { "child-id" },
            onTrace: { context in tracedContexts.append(context) }
        ))

        let config = RequestConfig(
            url: "https://api.test.com/v1/sub",
            method: .get,
            headers: ["x-request-id": "parent-id"]
        )
        _ = try await interceptor.onRequest(config)

        XCTAssertEqual(tracedContexts.count, 1)
        XCTAssertEqual(tracedContexts[0].requestId, "child-id")
        XCTAssertEqual(tracedContexts[0].parentRequestId, "parent-id")
    }

    // MARK: - 自定义 header 名称

    func testCustomHeaderNames() async throws {
        let interceptor = createTracingInterceptor(config: TracingConfig(
            headerName: "X-Trace-ID",
            parentHeaderName: "X-Parent-Trace-ID",
            generateId: { "custom-id" }
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/users", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["X-Trace-ID"], "custom-id")
        XCTAssertNil(result.headers["x-request-id"], "Default header should not be set with custom config")
    }

    // MARK: - 每次请求生成唯一 id

    func testEachRequestGetsUniqueId() async throws {
        var counter = 0
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: {
                counter += 1
                return "id-\(counter)"
            }
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/users", method: .get)

        let r1 = try await interceptor.onRequest(config)
        let r2 = try await interceptor.onRequest(config)

        XCTAssertEqual(r1.headers["x-request-id"], "id-1")
        XCTAssertEqual(r2.headers["x-request-id"], "id-2")
    }

    // MARK: - 不修改其他 header

    func testPreservesExistingHeaders() async throws {
        let interceptor = createTracingInterceptor(config: TracingConfig(
            generateId: { "trace-id" }
        ))

        let config = RequestConfig(
            url: "https://api.test.com/v1/users",
            method: .get,
            headers: ["Content-Type": "application/json", "Accept": "text/html"]
        )
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["Content-Type"], "application/json")
        XCTAssertEqual(result.headers["Accept"], "text/html")
        XCTAssertEqual(result.headers["x-request-id"], "trace-id")
    }
}
