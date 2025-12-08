import XCTest
@testable import CoreNetworkKit

final class NetworkErrorTests: XCTestCase {

    // MARK: - 状态码分类测试

    func testIsUnauthorized() {
        let error401 = NetworkError.serverError(statusCode: 401, message: nil)
        XCTAssertTrue(error401.isUnauthorized)

        let error403 = NetworkError.serverError(statusCode: 403, message: nil)
        XCTAssertFalse(error403.isUnauthorized)

        let timeout = NetworkError.timeout
        XCTAssertFalse(timeout.isUnauthorized)
    }

    func testIsClientError() {
        let error400 = NetworkError.serverError(statusCode: 400, message: nil)
        XCTAssertTrue(error400.isClientError)

        let error404 = NetworkError.serverError(statusCode: 404, message: nil)
        XCTAssertTrue(error404.isClientError)

        let error499 = NetworkError.serverError(statusCode: 499, message: nil)
        XCTAssertTrue(error499.isClientError)

        let error500 = NetworkError.serverError(statusCode: 500, message: nil)
        XCTAssertFalse(error500.isClientError)

        let error200 = NetworkError.serverError(statusCode: 200, message: nil)
        XCTAssertFalse(error200.isClientError)
    }

    func testIsServerError() {
        let error500 = NetworkError.serverError(statusCode: 500, message: nil)
        XCTAssertTrue(error500.isServerError)

        let error502 = NetworkError.serverError(statusCode: 502, message: nil)
        XCTAssertTrue(error502.isServerError)

        let error599 = NetworkError.serverError(statusCode: 599, message: nil)
        XCTAssertTrue(error599.isServerError)

        let error400 = NetworkError.serverError(statusCode: 400, message: nil)
        XCTAssertFalse(error400.isServerError)

        let error600 = NetworkError.serverError(statusCode: 600, message: nil)
        XCTAssertFalse(error600.isServerError)
    }

    // MARK: - LocalizedError 测试

    func testCancelledErrorDescription() {
        let error = NetworkError.cancelled
        XCTAssertEqual(error.errorDescription, "请求已取消")
    }

    func testTimeoutErrorDescription() {
        let error = NetworkError.timeout
        XCTAssertEqual(error.errorDescription, "请求超时")
    }

    func testNoNetworkErrorDescription() {
        let error = NetworkError.noNetwork
        XCTAssertEqual(error.errorDescription, "无网络连接")
    }

    func testServerErrorDescriptionWithMessage() {
        let error = NetworkError.serverError(statusCode: 500, message: "Internal Server Error")
        XCTAssertEqual(error.errorDescription, "服务器错误 (500): Internal Server Error")
    }

    func testServerErrorDescriptionWithoutMessage() {
        let error = NetworkError.serverError(statusCode: 500, message: nil)
        XCTAssertEqual(error.errorDescription, "服务器错误 (500)")
    }

    func testDecodingFailedErrorDescription() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "测试错误" }
        }
        let error = NetworkError.decodingFailed(TestError())
        XCTAssertTrue(error.errorDescription?.contains("响应解码失败") ?? false)
    }

    func testAuthenticationFailedErrorDescription() {
        let error = NetworkError.authenticationFailed
        XCTAssertEqual(error.errorDescription, "认证失败")
    }

    func testRetryExhaustedErrorDescription() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "最后一次错误" }
        }
        let error = NetworkError.retryExhausted(lastError: TestError())
        XCTAssertTrue(error.errorDescription?.contains("重试次数已用尽") ?? false)
    }

    func testInvalidURLErrorDescription() {
        let error = NetworkError.invalidURL
        XCTAssertEqual(error.errorDescription, "无效的 URL")
    }

    func testUnknownErrorDescription() {
        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "未知" }
        }
        let error = NetworkError.unknown(TestError())
        XCTAssertTrue(error.errorDescription?.contains("未知错误") ?? false)
    }

    // MARK: - 错误类型测试

    func testAllErrorCasesConformToError() {
        let errors: [NetworkError] = [
            .cancelled,
            .timeout,
            .noNetwork,
            .serverError(statusCode: 500, message: nil),
            .decodingFailed(NSError(domain: "test", code: 0)),
            .authenticationFailed,
            .retryExhausted(lastError: NSError(domain: "test", code: 0)),
            .invalidURL,
            .unknown(NSError(domain: "test", code: 0))
        ]

        for error in errors {
            // 所有错误应该可以作为 Error 使用
            let _: Error = error
            // 所有错误应该有描述
            XCTAssertNotNil(error.errorDescription)
        }
    }
}
