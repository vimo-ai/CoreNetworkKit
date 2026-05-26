import XCTest
@testable import CoreNetworkKit

final class RequestErrorTests: XCTestCase {

    // MARK: - 所有 ErrorCode 变体的构造测试

    func testConstructionWithNetworkCode() {
        let error = RequestError(code: .network, url: "/api", method: "GET", message: "no internet")
        XCTAssertEqual(error.code, .network)
        XCTAssertEqual(error.url, "/api")
        XCTAssertEqual(error.method, "GET")
        XCTAssertEqual(error.message, "no internet")
        XCTAssertNil(error.status)
        XCTAssertNil(error.cause)
    }

    func testConstructionWithTimeoutCode() {
        let error = RequestError(code: .timeout, url: "/slow", method: "POST", message: "timed out")
        XCTAssertEqual(error.code, .timeout)
    }

    func testConstructionWithAbortCode() {
        let error = RequestError(code: .abort, url: "/cancel", method: "GET", message: "aborted")
        XCTAssertEqual(error.code, .abort)
    }

    func testConstructionWithHttpCode() {
        let error = RequestError(code: .http, status: 404, url: "/missing", method: "GET", message: "not found")
        XCTAssertEqual(error.code, .http)
        XCTAssertEqual(error.status, 404)
    }

    func testConstructionWithParseCode() {
        let error = RequestError(code: .parse, url: "/data", method: "GET", message: "invalid JSON")
        XCTAssertEqual(error.code, .parse)
    }

    func testConstructionWithAuthCode() {
        let error = RequestError(code: .auth, status: 401, url: "/secure", method: "GET", message: "unauthorized")
        XCTAssertEqual(error.code, .auth)
        XCTAssertEqual(error.status, 401)
    }

    func testConstructionWithCircuitOpenCode() {
        let error = RequestError(code: .circuitOpen, url: "/api", method: "GET", message: "circuit open")
        XCTAssertEqual(error.code, .circuitOpen)
    }

    func testConstructionWithUnknownCode() {
        let error = RequestError(code: .unknown, url: "/api", method: "GET", message: "mystery")
        XCTAssertEqual(error.code, .unknown)
    }

    // MARK: - 便捷属性测试

    func testIsTimeout() {
        let timeout = RequestError(code: .timeout, url: "/a", method: "GET", message: "t")
        XCTAssertTrue(timeout.isTimeout)
        XCTAssertFalse(timeout.isAbort)
        XCTAssertFalse(timeout.isNetwork)
        XCTAssertFalse(timeout.isAuth)
        XCTAssertFalse(timeout.isCircuitOpen)
    }

    func testIsAbort() {
        let abort = RequestError(code: .abort, url: "/a", method: "GET", message: "a")
        XCTAssertTrue(abort.isAbort)
        XCTAssertFalse(abort.isTimeout)
        XCTAssertFalse(abort.isNetwork)
        XCTAssertFalse(abort.isAuth)
    }

    func testIsNetwork() {
        let network = RequestError(code: .network, url: "/a", method: "GET", message: "n")
        XCTAssertTrue(network.isNetwork)
        XCTAssertFalse(network.isTimeout)
        XCTAssertFalse(network.isAbort)
        XCTAssertFalse(network.isAuth)
    }

    func testIsAuth() {
        let auth = RequestError(code: .auth, url: "/a", method: "GET", message: "auth")
        XCTAssertTrue(auth.isAuth)
        XCTAssertFalse(auth.isNetwork)
        XCTAssertFalse(auth.isTimeout)
        XCTAssertFalse(auth.isAbort)
    }

    func testIsCircuitOpen() {
        let circuitOpen = RequestError(code: .circuitOpen, url: "/a", method: "GET", message: "open")
        XCTAssertTrue(circuitOpen.isCircuitOpen)
        XCTAssertFalse(circuitOpen.isNetwork)
    }

    // MARK: - isServerError 测试

    func testIsServerErrorFor5xx() {
        let error500 = RequestError(code: .http, status: 500, url: "/a", method: "GET", message: "server")
        XCTAssertTrue(error500.isServerError)

        let error503 = RequestError(code: .http, status: 503, url: "/a", method: "GET", message: "unavailable")
        XCTAssertTrue(error503.isServerError)

        let error599 = RequestError(code: .http, status: 599, url: "/a", method: "GET", message: "edge")
        XCTAssertTrue(error599.isServerError)
    }

    func testIsNotServerErrorFor4xx() {
        let error404 = RequestError(code: .http, status: 404, url: "/a", method: "GET", message: "not found")
        XCTAssertFalse(error404.isServerError)
    }

    func testIsNotServerErrorForNilStatus() {
        let error = RequestError(code: .network, url: "/a", method: "GET", message: "no status")
        XCTAssertFalse(error.isServerError)
    }

    // MARK: - status 和 cause 可选性测试

    func testStatusIsOptional() {
        let withStatus = RequestError(code: .http, status: 200, url: "/a", method: "GET", message: "ok")
        XCTAssertEqual(withStatus.status, 200)

        let withoutStatus = RequestError(code: .network, url: "/a", method: "GET", message: "fail")
        XCTAssertNil(withoutStatus.status)
    }

    func testCauseIsOptional() {
        let underlying = NSError(domain: "test", code: -1)
        let withCause = RequestError(code: .network, url: "/a", method: "GET", message: "wrap", cause: underlying)
        XCTAssertNotNil(withCause.cause)

        let withoutCause = RequestError(code: .network, url: "/a", method: "GET", message: "solo")
        XCTAssertNil(withoutCause.cause)
    }

    // MARK: - CustomStringConvertible

    func testDescriptionFormat() {
        let error = RequestError(code: .http, status: 502, url: "https://api.test.com/v1", method: "POST", message: "bad gateway")
        let desc = error.description
        XCTAssertTrue(desc.contains("HTTP"))
        XCTAssertTrue(desc.contains("POST"))
        XCTAssertTrue(desc.contains("https://api.test.com/v1"))
        XCTAssertTrue(desc.contains("502"))
        XCTAssertTrue(desc.contains("bad gateway"))
    }

    // MARK: - LocalizedError

    func testErrorDescription() {
        let error = RequestError(code: .parse, url: "/a", method: "GET", message: "invalid json")
        XCTAssertEqual(error.errorDescription, "invalid json")
    }
}
