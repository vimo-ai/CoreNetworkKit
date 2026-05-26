import XCTest
@testable import CoreNetworkKit

final class ConnectTransportTests: XCTestCase {

    // MARK: - HTTP Status Code Mapping

    func testMapHTTPStatusCodes() {
        let engine = MockNetworkEngine.successWithJSON([:])
        let transport = ConnectTransport(
            engine: engine,
            tokenStorage: MockTokenStorage()
        )

        // Access the private mapping via a unary call and inspect the response code
        let expectations: [(Int, String)] = [
            (200, "ok"),
            (400, "invalidArgument"),
            (401, "unauthenticated"),
            (403, "permissionDenied"),
            (404, "notFound"),
            (408, "deadlineExceeded"),
            (409, "aborted"),
            (429, "resourceExhausted"),
            (500, "internalError"),
            (501, "unimplemented"),
            (503, "unavailable"),
        ]

        for (statusCode, expectedCodeName) in expectations {
            let responseEngine = MockNetworkEngine.successWith(
                data: Data(),
                statusCode: statusCode
            )
            let t = ConnectTransport(
                engine: responseEngine,
                tokenStorage: MockTokenStorage()
            )

            let expectation = expectation(description: "unary \(statusCode)")
            let request = HTTPRequest(
                url: URL(string: "https://api.example.com/test")!,
                headers: [:],
                message: nil,
                method: .post,
                trailers: nil,
                idempotencyLevel: .unknown
            )

            t.unary(request: request, onMetrics: { _ in }) { response in
                XCTAssertEqual(
                    "\(response.code)",
                    expectedCodeName,
                    "Status \(statusCode) should map to \(expectedCodeName)"
                )
                expectation.fulfill()
            }

            wait(for: [expectation], timeout: 2)
        }
    }

    // MARK: - Auth Header Injection

    func testAuthHeaderInjected() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 200)
        let tokenStorage = MockTokenStorage(token: "test-bearer-token")
        let transport = ConnectTransport(
            engine: engine,
            tokenStorage: tokenStorage
        )

        let expectation = expectation(description: "auth header")
        let request = HTTPRequest(
            url: URL(string: "https://api.example.com/test")!,
            headers: [:],
            message: nil,
            method: .post,
            trailers: nil,
            idempotencyLevel: .unknown
        )

        transport.unary(request: request, onMetrics: { _ in }) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(engine.requestCount, 1)
        let sentRequest = engine.requestHistory[0]
        let authHeader = sentRequest.value(forHTTPHeaderField: "Authorization")
        XCTAssertNotNil(authHeader, "Auth header should be present")
        XCTAssertTrue(authHeader?.contains("test-bearer-token") == true)
    }

    // MARK: - Request Body Forwarding

    func testRequestBodyForwarded() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 200)
        let transport = ConnectTransport(
            engine: engine,
            tokenStorage: MockTokenStorage()
        )

        let body = "test body".data(using: .utf8)
        let expectation = expectation(description: "body forwarded")
        let request = HTTPRequest(
            url: URL(string: "https://api.example.com/test")!,
            headers: ["content-type": ["application/proto"]],
            message: body,
            method: .post,
            trailers: nil,
            idempotencyLevel: .unknown
        )

        transport.unary(request: request, onMetrics: { _ in }) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)

        XCTAssertEqual(engine.requestHistory[0].httpBody, body)
    }

    // MARK: - Network Error Mapping

    func testNetworkErrorMappedToConnectError() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.timeout
        )
        let transport = ConnectTransport(
            engine: engine,
            tokenStorage: MockTokenStorage()
        )

        let expectation = expectation(description: "error mapping")
        let request = HTTPRequest(
            url: URL(string: "https://api.example.com/test")!,
            headers: [:],
            message: nil,
            method: .post,
            trailers: nil,
            idempotencyLevel: .unknown
        )

        transport.unary(request: request, onMetrics: { _ in }) { response in
            XCTAssertNotNil(response.error, "Should have an error")
            XCTAssertEqual(response.code, .deadlineExceeded)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2)
    }

    // MARK: - Cancellation

    func testCancellationPropagated() {
        let engine = MockNetworkEngine.delayed(
            seconds: 10,
            then: .success(Data(), HTTPURLResponse())
        )
        let transport = ConnectTransport(
            engine: engine,
            tokenStorage: MockTokenStorage()
        )

        let request = HTTPRequest(
            url: URL(string: "https://api.example.com/test")!,
            headers: [:],
            message: nil,
            method: .post,
            trailers: nil,
            idempotencyLevel: .unknown
        )

        let expectation = expectation(description: "cancel")
        let cancelable = transport.unary(request: request, onMetrics: { _ in }) { response in
            // Should get canceled or unknown code
            expectation.fulfill()
        }

        cancelable.cancel()
        wait(for: [expectation], timeout: 2)
    }
}

// MARK: - Test Doubles

private final class MockTokenStorage: TokenStorage {
    var token: String?

    init(token: String? = nil) {
        self.token = token
    }

    func getToken() -> String? { token }
    func setToken(_ token: String?) { self.token = token }
}
