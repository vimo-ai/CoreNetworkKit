import Foundation
import Alamofire

/// 基于 Alamofire 的网络引擎实现
///
/// 特性：
/// - 成熟稳定的底层实现
/// - 自动处理 SSL/TLS
/// - 请求/响应验证
/// - 支持取消传播（协作式取消）
public final class AlamofireEngine: NetworkEngine {
    private let session: Session

    /// 创建 Alamofire 引擎
    /// - Parameter configuration: URLSession 配置，默认使用 .default
    public init(configuration: URLSessionConfiguration = .default) {
        self.session = Session(configuration: configuration)
    }

    /// 发送网络请求，支持取消传播
    /// - Parameter request: URLRequest 对象
    /// - Returns: 响应数据和元信息
    /// - Throws: NetworkError
    public func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // 在请求开始前检查取消状态
        try Task.checkCancellation()

        // 创建 Alamofire DataRequest
        let dataRequest = session.request(request)

        // 使用 withTaskCancellationHandler 支持取消传播
        return try await withTaskCancellationHandler {
            // 正常执行请求
            let response = await dataRequest
                .validate() // 验证响应状态码
                .serializingData()
                .response

            // 请求完成后再次检查取消状态（协作式取消）
            try Task.checkCancellation()

            // 检查响应
            if let error = response.error {
                throw mapAlamofireError(error, response: response.response, data: response.data)
            }

            guard let data = response.data, let urlResponse = response.response else {
                throw NetworkError.unknown(NSError(
                    domain: "AlamofireEngine",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "无效的响应数据"]
                ))
            }

            return (data, urlResponse)
        } onCancel: {
            // Task 被取消时，同步取消 Alamofire 请求
            dataRequest.cancel()
        }
    }

    /// 将 Alamofire 错误映射到 NetworkError
    private func mapAlamofireError(_ error: AFError, response: HTTPURLResponse?, data: Data?) -> NetworkError {
        switch error {
        // 显式处理取消
        case .explicitlyCancelled:
            return .cancelled

        // Session 失效
        case .sessionInvalidated:
            return .cancelled

        case .sessionTaskFailed(let urlError as URLError):
            // URLError 映射
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .timedOut:
                return .timeout
            case .notConnectedToInternet, .networkConnectionLost:
                return .noNetwork
            default:
                return .unknown(urlError)
            }

        case .responseValidationFailed(let reason):
            // 响应验证失败
            if case .unacceptableStatusCode(let code) = reason {
                // 尝试从响应 body 中提取错误信息
                let message = extractErrorMessage(from: response, data: data)
                return .serverError(statusCode: code, message: message)
            }
            return .unknown(error)

        case .responseSerializationFailed(let reason):
            // 序列化失败 - 透传底层错误
            let underlyingError = extractUnderlyingError(from: reason) ?? error
            return .decodingFailed(underlyingError)

        case .requestRetryFailed(let retryError, _):
            // 重试失败，递归处理原始错误
            if let afError = retryError.asAFError {
                return mapAlamofireError(afError, response: response, data: data)
            }
            return .unknown(retryError)

        default:
            return .unknown(error)
        }
    }

    /// 从序列化失败原因中提取底层错误
    private func extractUnderlyingError(from reason: AFError.ResponseSerializationFailureReason) -> Error? {
        switch reason {
        case .decodingFailed(let error):
            return error
        case .customSerializationFailed(let error):
            return error
        case .invalidEmptyResponse:
            return nil
        default:
            return nil
        }
    }

    /// 从响应中提取错误消息
    private func extractErrorMessage(from response: HTTPURLResponse?, data: Data?) -> String? {
        // 优先从响应 body 中提取 JSON 错误信息
        if let data = data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 常见的错误字段名
            return json["message"] as? String
                ?? json["error"] as? String
                ?? json["errorMessage"] as? String
                ?? json["msg"] as? String
        }

        // 其次从响应头中获取
        return response?.allHeaderFields["X-Error-Message"] as? String
    }

    // MARK: - Streaming (SSE)

    /// 执行流式请求（用于 SSE）
    /// - Parameter request: URLRequest 对象
    /// - Returns: 异步数据流，逐块返回数据
    public func streamRequest(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        return AsyncThrowingStream { continuation in
            // 创建流式请求
            let streamRequest = session.streamRequest(request)

            // 设置取消处理
            continuation.onTermination = { @Sendable _ in
                streamRequest.cancel()
            }

            // 启动流式接收
            streamRequest
                .validate()
                .responseStream { stream in
                    switch stream.event {
                    case .stream(let result):
                        // Alamofire DataStreamRequest.Stream.Event 的 Result 类型是 Result<Data, Never>
                        // Never 表示永远不会失败，错误通过 complete 事件传递
                        switch result {
                        case .success(let data):
                            continuation.yield(data)
                        }

                    case .complete(let completion):
                        if let error = completion.error {
                            continuation.finish(throwing: self.mapAlamofireError(error, response: completion.response, data: nil))
                        } else {
                            continuation.finish()
                        }
                    }
                }
        }
    }
}
