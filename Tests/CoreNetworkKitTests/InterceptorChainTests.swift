import XCTest
@testable import CoreNetworkKit

final class InterceptorChainTests: XCTestCase {

    // MARK: - 辅助拦截器

    /// 记录调用顺序并可选地修改请求/响应/错误的测试拦截器
    private final class RecordingInterceptor: RequestInterceptor, @unchecked Sendable {
        let id: String
        let log: OrderedLog
        var requestTransform: ((RequestConfig) -> RequestConfig)?
        var responseTransform: ((Any) -> Any)?
        var errorTransform: ((RequestError) -> RequestError)?

        init(id: String, log: OrderedLog) {
            self.id = id
            self.log = log
        }

        func onRequest(_ config: RequestConfig) async throws -> RequestConfig {
            log.append("\(id):request")
            if let t = requestTransform { return t(config) }
            return config
        }

        func onResponse<T: Sendable>(_ response: ResponseData<T>) async throws -> ResponseData<T> {
            log.append("\(id):response")
            return response
        }

        func onError(_ error: RequestError) async throws -> RequestError {
            log.append("\(id):error")
            if let t = errorTransform { return t(error) }
            return error
        }
    }

    /// 线程安全的有序日志
    private final class OrderedLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []

        func append(_ entry: String) {
            lock.lock()
            entries.append(entry)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }
    }

    // MARK: - use() 返回取消闭包

    func testUseReturnsUnsubscribeClosure() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()
        let interceptor = RecordingInterceptor(id: "A", log: log)

        let unsubscribe = chain.use(interceptor)

        let config = makeConfig()
        _ = try await chain.applyRequest(config)
        XCTAssertEqual(log.values, ["A:request"])

        // 取消订阅后拦截器不再被调用
        unsubscribe()
        _ = try await chain.applyRequest(config)
        XCTAssertEqual(log.values, ["A:request"]) // 没有新增
    }

    // MARK: - applyRequest 按注册顺序执行

    func testApplyRequestRunsInterceptorsInOrder() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()

        chain.use(RecordingInterceptor(id: "1", log: log))
        chain.use(RecordingInterceptor(id: "2", log: log))
        chain.use(RecordingInterceptor(id: "3", log: log))

        _ = try await chain.applyRequest(makeConfig())
        XCTAssertEqual(log.values, ["1:request", "2:request", "3:request"])
    }

    // MARK: - applyResponse 按注册顺序执行

    func testApplyResponseRunsInterceptorsInOrder() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()

        chain.use(RecordingInterceptor(id: "A", log: log))
        chain.use(RecordingInterceptor(id: "B", log: log))

        let response = ResponseData(status: 200, headers: [:], data: "ok")
        _ = try await chain.applyResponse(response)
        XCTAssertEqual(log.values, ["A:response", "B:response"])
    }

    // MARK: - applyError 按注册顺序执行

    func testApplyErrorRunsInterceptorsInOrder() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()

        chain.use(RecordingInterceptor(id: "X", log: log))
        chain.use(RecordingInterceptor(id: "Y", log: log))

        let error = RequestError(code: .network, url: "https://example.com", method: "GET", message: "fail")
        _ = try await chain.applyError(error)
        XCTAssertEqual(log.values, ["X:error", "Y:error"])
    }

    // MARK: - 空链路直接透传

    func testEmptyChainPassesThroughRequest() async throws {
        let chain = InterceptorChain()
        let config = makeConfig(url: "https://test.com/api")
        let result = try await chain.applyRequest(config)
        XCTAssertEqual(result.url, "https://test.com/api")
    }

    func testEmptyChainPassesThroughResponse() async throws {
        let chain = InterceptorChain()
        let response = ResponseData(status: 201, headers: ["x": "y"], data: 42)
        let result = try await chain.applyResponse(response)
        XCTAssertEqual(result.status, 201)
        XCTAssertEqual(result.data, 42)
    }

    func testEmptyChainPassesThroughError() async throws {
        let chain = InterceptorChain()
        let error = RequestError(code: .timeout, url: "/a", method: "POST", message: "timeout")
        let result = try await chain.applyError(error)
        XCTAssertEqual(result.code, .timeout)
        XCTAssertEqual(result.message, "timeout")
    }

    // MARK: - 多个拦截器组合变换

    func testMultipleInterceptorsComposeCorrectly() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()

        let first = RecordingInterceptor(id: "1", log: log)
        first.requestTransform = { config in
            var c = config
            c.headers["X-First"] = "true"
            return c
        }

        let second = RecordingInterceptor(id: "2", log: log)
        second.requestTransform = { config in
            var c = config
            c.headers["X-Second"] = "true"
            return c
        }

        chain.use(first)
        chain.use(second)

        let result = try await chain.applyRequest(makeConfig())
        XCTAssertEqual(result.headers["X-First"], "true")
        XCTAssertEqual(result.headers["X-Second"], "true")
        XCTAssertEqual(log.values, ["1:request", "2:request"])
    }

    // MARK: - 中途取消订阅不影响正在执行的链路

    func testUnsubscribeMidwayDoesNotAffectInFlightChain() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()

        var unsubscribeB: (() -> Void)?

        let a = RecordingInterceptor(id: "A", log: log)
        a.requestTransform = { config in
            // 在 A 的 onRequest 中取消 B 的订阅
            unsubscribeB?()
            return config
        }

        let b = RecordingInterceptor(id: "B", log: log)

        chain.use(a)
        unsubscribeB = chain.use(b)

        // applyRequest 会先做 snapshot，所以即使 A 在执行中取消了 B，
        // 当前链路的 snapshot 仍包含 B
        _ = try await chain.applyRequest(makeConfig())
        XCTAssertEqual(log.values, ["A:request", "B:request"])

        // 但下一次调用 B 已经被移除
        _ = try await chain.applyRequest(makeConfig())
        XCTAssertEqual(log.values, ["A:request", "B:request", "A:request"])
    }

    // MARK: - 错误链变换

    func testErrorChainTransformsError() async throws {
        let chain = InterceptorChain()
        let log = OrderedLog()

        let interceptor = RecordingInterceptor(id: "mapper", log: log)
        interceptor.errorTransform = { error in
            RequestError(code: .auth, status: 401, url: error.url, method: error.method, message: "remapped")
        }

        chain.use(interceptor)

        let original = RequestError(code: .network, url: "/api", method: "GET", message: "original")
        let result = try await chain.applyError(original)
        XCTAssertEqual(result.code, .auth)
        XCTAssertEqual(result.message, "remapped")
    }

    // MARK: - Private Helpers

    private func makeConfig(url: String = "https://api.example.com/v1/test") -> RequestConfig {
        RequestConfig(url: url, method: .get)
    }
}
