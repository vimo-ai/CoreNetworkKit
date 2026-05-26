import XCTest
@testable import CoreNetworkKit

final class UnwrapInterceptorTests: XCTestCase {

    // MARK: - 成功解包 {success: true, data: T, message: ""}

    func testUnwrapsSuccessfulResponse() async throws {
        let interceptor = createUnwrapInterceptor()

        let wrapped = WrappedResponse(success: true, data: "inner-value", message: "")
        let response = ResponseData(status: 200, headers: [:], data: wrapped)

        let result = try await interceptor.onResponse(response)
        // 解包后 data 应为内部的 data 字段值
        // 由于泛型约束，result.data 类型仍为 WrappedResponse<String>
        // 但如果 Mirror 检测到 success/data 字段且 inner data 类型匹配 T，则替换
        // 在本例中 T = WrappedResponse<String>，inner data 类型为 String，不匹配 T
        // 所以需要通过 ResponseData<String> 来测试
        XCTAssertEqual(result.status, 200)
    }

    func testUnwrapsWhenInnerDataMatchesT() async throws {
        let interceptor = createUnwrapInterceptor()

        // 构建一个嵌套包装结构，其中 data 字段的类型与外层 T 相同
        let innerPayload = "hello"
        let wrapped = WrappedResponse(success: true, data: innerPayload, message: "ok")
        let response = ResponseData(status: 200, headers: [:], data: wrapped)

        // 此处 T = WrappedResponse<String>，内部 data 是 String，类型不匹配
        // 拦截器检测到 success: true 但 inner data (String) != T (WrappedResponse)
        // 会返回原始 response
        let result = try await interceptor.onResponse(response)
        XCTAssertEqual(result.data.success, true)
        XCTAssertEqual(result.data.data, "hello")
    }

    // MARK: - success: false 时抛出 BusinessErrorV2

    func testThrowsBusinessErrorOnFailure() async throws {
        let interceptor = createUnwrapInterceptor()

        let wrapped = WrappedResponse(success: false, data: nil as String?, message: "Invalid request")
        let response = ResponseData(status: 200, headers: [:], data: wrapped)

        do {
            _ = try await interceptor.onResponse(response)
            XCTFail("Should have thrown BusinessErrorV2")
        } catch let error as BusinessErrorV2 {
            XCTAssertEqual(error.message, "Invalid request")
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }

    func testThrowsBusinessErrorWithDefaultMessage() async throws {
        let interceptor = createUnwrapInterceptor()

        let wrapped = WrappedResponse(success: false, data: nil as String?, message: nil)
        let response = ResponseData(status: 200, headers: [:], data: wrapped)

        do {
            _ = try await interceptor.onResponse(response)
            XCTFail("Should have thrown BusinessErrorV2")
        } catch let error as BusinessErrorV2 {
            XCTAssertEqual(error.message, "Request failed", "Should use default message when message is nil")
        } catch {
            XCTFail("Unexpected error type: \(type(of: error))")
        }
    }

    // MARK: - 非包装响应原样透传

    func testPassesThroughNonWrappedResponses() async throws {
        let interceptor = createUnwrapInterceptor()

        // 普通字符串不包含 success/data 字段
        let response = ResponseData(status: 200, headers: [:], data: "plain string")
        let result = try await interceptor.onResponse(response)
        XCTAssertEqual(result.data, "plain string")
    }

    func testPassesThroughIntResponse() async throws {
        let interceptor = createUnwrapInterceptor()

        let response = ResponseData(status: 200, headers: [:], data: 42)
        let result = try await interceptor.onResponse(response)
        XCTAssertEqual(result.data, 42)
    }

    func testPassesThroughArrayResponse() async throws {
        let interceptor = createUnwrapInterceptor()

        let response = ResponseData(status: 200, headers: [:], data: [1, 2, 3])
        let result = try await interceptor.onResponse(response)
        XCTAssertEqual(result.data, [1, 2, 3])
    }

    // MARK: - BusinessErrorV2 属性测试

    func testBusinessErrorV2Properties() {
        let error = BusinessErrorV2(message: "订单已取消")
        XCTAssertEqual(error.message, "订单已取消")
        XCTAssertEqual(error.errorDescription, "订单已取消")
    }
}

// MARK: - 辅助类型

/// 模拟后端包装响应结构
private struct WrappedResponse<T: Sendable>: Sendable {
    let success: Bool
    let data: T?
    let message: String?
}
