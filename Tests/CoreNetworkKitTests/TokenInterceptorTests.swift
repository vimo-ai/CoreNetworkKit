import XCTest
@testable import CoreNetworkKit

final class TokenInterceptorTests: XCTestCase {

    // MARK: - 默认注入 Authorization: Bearer <token>

    func testInjectsAuthorizationHeaderWithBearerScheme() async throws {
        let interceptor = createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { "my-jwt-token" }
        ))

        let config = RequestConfig(url: "https://api.test.com/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["Authorization"], "Bearer my-jwt-token")
    }

    // MARK: - 自定义 header 名称和 scheme

    func testCustomHeaderNameAndScheme() async throws {
        let interceptor = createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { "api-key-123" },
            headerName: "X-API-Key",
            scheme: "Token"
        ))

        let config = RequestConfig(url: "https://api.test.com/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertNil(result.headers["Authorization"], "Should not set Authorization when custom header is used")
        XCTAssertEqual(result.headers["X-API-Key"], "Token api-key-123")
    }

    func testEmptyScheme() async throws {
        let interceptor = createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { "raw-token" },
            scheme: ""
        ))

        let config = RequestConfig(url: "https://api.test.com/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["Authorization"], "raw-token", "Empty scheme should send raw token")
    }

    // MARK: - token 为 nil 时不注入 header

    func testNoHeaderWhenTokenIsNil() async throws {
        let interceptor = createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { nil }
        ))

        let config = RequestConfig(url: "https://api.test.com/data", method: .get)
        let result = try await interceptor.onRequest(config)

        XCTAssertNil(result.headers["Authorization"], "Should not inject header when token is nil")
    }

    // MARK: - 不修改已有的其他 header

    func testPreservesExistingHeaders() async throws {
        let interceptor = createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { "token" }
        ))

        let config = RequestConfig(
            url: "https://api.test.com/data",
            method: .post,
            headers: ["Content-Type": "application/json", "Accept": "text/plain"]
        )
        let result = try await interceptor.onRequest(config)

        XCTAssertEqual(result.headers["Content-Type"], "application/json")
        XCTAssertEqual(result.headers["Accept"], "text/plain")
        XCTAssertEqual(result.headers["Authorization"], "Bearer token")
    }

    // MARK: - token 动态更新

    func testTokenRefreshesDynamically() async throws {
        var currentToken: String? = "old-token"
        let interceptor = createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { currentToken }
        ))

        let config = RequestConfig(url: "https://api.test.com/data", method: .get)

        let result1 = try await interceptor.onRequest(config)
        XCTAssertEqual(result1.headers["Authorization"], "Bearer old-token")

        // token 更新
        currentToken = "new-token"
        let result2 = try await interceptor.onRequest(config)
        XCTAssertEqual(result2.headers["Authorization"], "Bearer new-token")

        // token 变为 nil
        currentToken = nil
        let result3 = try await interceptor.onRequest(config)
        XCTAssertNil(result3.headers["Authorization"])
    }
}
