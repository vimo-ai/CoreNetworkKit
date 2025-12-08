import Foundation
@testable import CoreNetworkKit

/// 测试用 Mock 网络引擎
final class MockNetworkEngine: NetworkEngine {

    indirect enum MockBehavior {
        case success(Data, HTTPURLResponse)
        case failure(Error)
        case delay(TimeInterval, then: MockBehavior)
        case cancelled
    }

    var behavior: MockBehavior = .success(Data(), HTTPURLResponse())
    var requestHistory: [URLRequest] = []
    var requestCount: Int { requestHistory.count }

    func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requestHistory.append(request)

        switch behavior {
        case .success(let data, let response):
            return (data, response)

        case .failure(let error):
            throw error

        case .delay(let seconds, let then):
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            behavior = then
            return try await performRequest(request)

        case .cancelled:
            throw CancellationError()
        }
    }

    // MARK: - 便捷工厂方法

    static func successWith(data: Data, statusCode: Int = 200, url: URL? = nil) -> MockNetworkEngine {
        let engine = MockNetworkEngine()
        let response = HTTPURLResponse(
            url: url ?? URL(string: "https://api.example.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        engine.behavior = .success(data, response)
        return engine
    }

    static func successWithJSON(_ json: Any, statusCode: Int = 200) -> MockNetworkEngine {
        let data = try! JSONSerialization.data(withJSONObject: json)
        return successWith(data: data, statusCode: statusCode)
    }

    static func failingWith(error: Error) -> MockNetworkEngine {
        let engine = MockNetworkEngine()
        engine.behavior = .failure(error)
        return engine
    }

    static func delayed(seconds: TimeInterval, then behavior: MockBehavior) -> MockNetworkEngine {
        let engine = MockNetworkEngine()
        engine.behavior = .delay(seconds, then: behavior)
        return engine
    }
}
