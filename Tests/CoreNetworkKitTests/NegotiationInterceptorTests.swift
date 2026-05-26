import XCTest
@testable import CoreNetworkKit

final class NegotiationInterceptorTests: XCTestCase {

    // MARK: - 发送 x-client-version header

    func testSendsClientVersionHeader() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "2.1.0"
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["x-client-version"], "2.1.0")
    }

    func testDoesNotSendClientVersionWhenNil() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: nil
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertNil(result.headers["x-client-version"])
    }

    // MARK: - 从响应 header 解析服务端能力

    func testParsesServerCapabilitiesFromResponseHeaders() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0"
        ))

        // onRequest 先注册 origin
        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config)

        // 模拟服务端响应
        let response = ResponseData(
            status: 200,
            headers: [
                "x-api-version": "3.2.1",
                "x-supported-encodings": "gzip, br",
                "x-server-features": "streaming, batch, websocket"
            ],
            data: "ok"
        )
        _ = try await interceptor.onResponse(response)

        // 验证缓存的能力
        let capabilities = interceptor.getCapabilities(baseURL: "https://api.test.com/v1/data")
        XCTAssertNotNil(capabilities)
        XCTAssertEqual(capabilities?.apiVersion, "3.2.1")
        XCTAssertEqual(capabilities?.supportedEncodings, ["gzip", "br"])
        XCTAssertEqual(capabilities?.features, Set(["streaming", "batch", "websocket"]))
    }

    // MARK: - 缓存能力

    func testCachesCapabilities() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0",
            cacheTtlSeconds: 300
        ))

        // 第一次请求/响应
        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config)

        let response = ResponseData(
            status: 200,
            headers: ["x-api-version": "2.0.0"],
            data: "data"
        )
        _ = try await interceptor.onResponse(response)

        // 缓存应存在
        let cached = interceptor.getCapabilities(baseURL: "https://api.test.com")
        XCTAssertNotNil(cached)
        XCTAssertEqual(cached?.apiVersion, "2.0.0")

        // 再次查询，仍然命中缓存
        let cachedAgain = interceptor.getCapabilities(baseURL: "https://api.test.com")
        XCTAssertNotNil(cachedAgain)
        XCTAssertEqual(cachedAgain?.apiVersion, "2.0.0")
    }

    // MARK: - 缓存过期

    func testCacheExpiresAfterTTL() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0",
            cacheTtlSeconds: 0.1 // 100ms TTL
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config)

        let response = ResponseData(
            status: 200,
            headers: ["x-api-version": "1.0.0"],
            data: "data"
        )
        _ = try await interceptor.onResponse(response)

        // 立即应命中缓存
        let cached = interceptor.getCapabilities(baseURL: "https://api.test.com")
        XCTAssertNotNil(cached)

        // 等待 TTL 过期
        try await Task.sleep(nanoseconds: 200_000_000) // 200ms

        // 缓存应已过期
        let expired = interceptor.getCapabilities(baseURL: "https://api.test.com")
        XCTAssertNil(expired, "Cache should expire after TTL")
    }

    // MARK: - onCapabilities 回调

    func testOnCapabilitiesCallback() async throws {
        var receivedOrigin: String?
        var receivedCapabilities: ServerCapabilities?

        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0",
            onCapabilities: { origin, caps in
                receivedOrigin = origin
                receivedCapabilities = caps
            }
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config)

        let response = ResponseData(
            status: 200,
            headers: ["x-api-version": "5.0.0"],
            data: "callback-test"
        )
        _ = try await interceptor.onResponse(response)

        XCTAssertEqual(receivedOrigin, "https://api.test.com")
        XCTAssertEqual(receivedCapabilities?.apiVersion, "5.0.0")
    }

    // MARK: - clearCache 清除所有缓存

    func testClearCacheRemovesAll() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0"
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config)

        let response = ResponseData(
            status: 200,
            headers: ["x-api-version": "1.0.0"],
            data: "data"
        )
        _ = try await interceptor.onResponse(response)

        XCTAssertNotNil(interceptor.getCapabilities(baseURL: "https://api.test.com"))

        interceptor.clearCache()

        XCTAssertNil(interceptor.getCapabilities(baseURL: "https://api.test.com"),
                      "clearCache should remove all cached capabilities")
    }

    // MARK: - 无服务端能力 header 时不缓存

    func testNoCacheWhenNoCapabilityHeaders() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0"
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config)

        // 响应不包含任何能力 header
        let response = ResponseData(
            status: 200,
            headers: ["content-type": "application/json"],
            data: "no-caps"
        )
        _ = try await interceptor.onResponse(response)

        let caps = interceptor.getCapabilities(baseURL: "https://api.test.com")
        XCTAssertNil(caps, "Should not cache when response has no capability headers")
    }

    // MARK: - 自定义 header 前缀

    func testCustomHeaderPrefix() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            headerPrefix: "x-custom-",
            clientVersionHeader: "X-App-Version",
            clientVersion: "3.0.0"
        ))

        let config = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["X-App-Version"], "3.0.0")
        XCTAssertNil(result.headers["x-client-version"], "Default header should not be set with custom config")
    }

    // MARK: - 缓存的编码能力被注入到后续请求

    func testCachedEncodingsInjectedIntoRequest() async throws {
        let interceptor = createNegotiationInterceptor(config: NegotiationConfig(
            clientVersion: "1.0.0"
        ))

        // 第一次请求 + 响应建立缓存
        let config1 = RequestConfig(url: "https://api.test.com/v1/data", method: .get)
        _ = try await interceptor.onRequest(config1)

        let response = ResponseData(
            status: 200,
            headers: ["x-supported-encodings": "gzip, br"],
            data: "data"
        )
        _ = try await interceptor.onResponse(response)

        // 第二次请求应注入 accept-encoding
        let config2 = RequestConfig(url: "https://api.test.com/v1/other", method: .get)
        let result = try await interceptor.onRequest(config2)

        XCTAssertEqual(result.headers["accept-encoding"], "gzip, br")
    }
}
