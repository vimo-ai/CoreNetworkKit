import Foundation
import MLoggerKit

/// 一个通用的、负责发送网络请求的客户端。
public final class APIClient {
    
    // MARK: - 属性
    
    internal let engine: NetworkEngine
    internal let tokenStorage: any TokenStorage
    internal let userFeedbackHandler: UserFeedbackHandler?
    internal let tokenRefresher: TokenRefresher?
    // 使用 MLoggerKit 网络日志器
    internal let logger = LoggerFactory.network
    internal let jsonDecoder: JSONDecoder
    internal let refreshCoordinator = TokenRefreshCoordinator()
    
    // MARK: - 初始化
    
    /// 初始化一个新的API客户端。
    /// - Parameters:
    ///   - engine: 用于发送请求的网络引擎。
    ///   - tokenStorage: 用户令牌的存储机制。
    ///   - userFeedbackHandler: 用户反馈处理器，用于BeaconFlow请求的Toast显示和日志记录。
    ///   - jsonDecoder: 一个可选的JSON解码器，如果需要自定义解码策略。
    public init(engine: NetworkEngine, tokenStorage: any TokenStorage, userFeedbackHandler: UserFeedbackHandler? = nil, jsonDecoder: JSONDecoder = JSONDecoder(), tokenRefresher: TokenRefresher? = nil) {
        self.engine = engine
        self.tokenStorage = tokenStorage
        self.userFeedbackHandler = userFeedbackHandler
        self.jsonDecoder = jsonDecoder
        self.tokenRefresher = tokenRefresher
    }
    
    // MARK: - 公开方法
    
    /// 发送一个网络请求并返回解码后的响应。
    /// - Parameter request: 一个遵循 `Request` 协议的请求实例。
    /// - Returns: 解码后的响应模型。
    public func send<R: Request>(_ request: R) async throws -> R.Response {
        return try await send(request, allowRetryAfterRefresh: true)
    }
    
    // MARK: - 私有方法
    
    internal func buildURLRequest<R: Request>(from request: R) throws -> URLRequest {
        let fullURL = request.baseURL.appendingPathComponent(request.path)
        var components = URLComponents(url: fullURL, resolvingAgainstBaseURL: false)
        
        // 1. 将查询参数编码到URL中。
        if let queryParams = request.query, !queryParams.isEmpty {
            components?.queryItems = queryParams.map { URLQueryItem(name: $0.key, value: "\($0.value)") }
        }
        
        guard let url = components?.url else {
            logger.error("URL构建失败: \(request.baseURL)/\(request.path)", tag: "url-build-error")
            throw APIError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method.rawValue
        
        // 2. 添加请求头。移除了硬编码的头，现在完全由 Request 协议提供。
        request.headers?.forEach { key, value in
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }


        
        // 3. 智能编码强类型请求体
        if request.method == .post || request.method == .put || request.method == .patch || request.method == .delete {
            try encodeRequestBody(request, into: &urlRequest)
        }
        
        return urlRequest
    }
    
    /// 编码强类型请求体
    /// - Parameters:
    ///   - request: 请求对象
    ///   - urlRequest: 要设置body的URLRequest
    internal func encodeRequestBody<R: Request>(_ request: R, into urlRequest: inout URLRequest) throws {
        let contentType = request.headers?["Content-Type"] ?? "application/json"
        
        // 设置默认Content-Type为JSON
        if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
            urlRequest.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        
        // 检查是否有实际的body数据
        if let bodyData = request.body {
            // 检查是否为EmptyBody类型
            if bodyData is EmptyBody {
                // EmptyBody类型，发送空JSON对象
                urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [:], options: [])
            } else {
                // 有实际数据，使用JSONEncoder编码强类型对象
                let jsonEncoder = JSONEncoder()
                // BeaconFlow系统统一使用camelCase，保持原始字段名
                jsonEncoder.keyEncodingStrategy = .useDefaultKeys
                urlRequest.httpBody = try jsonEncoder.encode(bodyData)
            }
        } else {
            // body为nil，发送空JSON对象
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: [:], options: [])
        }
    }

    internal func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.unknownError
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            let serverMessage = String(data: data, encoding: .utf8)
            
            // 特殊处理400验证错误
            if httpResponse.statusCode == 400 {
                logger.error("🚨 验证失败 (400)", tag: "validation-error")
                // 这里可以添加更多调试信息
            }
            
            throw APIError.serverError(statusCode: httpResponse.statusCode, message: serverMessage)
        }
    }

    // MARK: - 私有方法

    private func send<R: Request>(_ request: R, allowRetryAfterRefresh: Bool) async throws -> R.Response {
        var responseData: Data?
        do {
            let urlRequest = try buildURLRequest(from: request)
            logger.debug("📤 \(urlRequest.httpMethod ?? "") \(urlRequest.url?.path ?? "")", tag: "request")

            let authContext = AuthenticationContext(tokenStorage: self.tokenStorage)
            let authenticatedRequest = try await request.authentication.apply(to: urlRequest, context: authContext)
            
            let (data, response) = try await engine.performRequest(authenticatedRequest)
            responseData = data
            try validate(response: response, data: data)

            let responseModel = try jsonDecoder.decode(R.Response.self, from: data)
            return responseModel

        } catch let error as DecodingError {
            logger.error("解码失败 \(request.path):\n\(DecodingErrorFormatter.format(error))", tag: "decode-error")

            if let data = responseData, let rawString = String(data: data, encoding: .utf8) {
                logger.debug("解码失败时的原始数据:\n---BEGIN---\n\(rawString)\n---END---", tag: "raw-data")
            }

            throw APIError.decodingFailed(error: error, data: responseData)
        } catch let apiError as APIError {
            // 调试日志：检查为什么没有触发刷新
            print("[APIClient] 捕获到 APIError: \(apiError)")
            print("[APIClient] allowRetryAfterRefresh = \(allowRetryAfterRefresh)")
            print("[APIClient] shouldAttemptRefresh = \(shouldAttemptRefresh(for: apiError))")
            print("[APIClient] tokenRefresher is nil? \(tokenRefresher == nil)")
            
            if allowRetryAfterRefresh,
               shouldAttemptRefresh(for: apiError),
               let tokenRefresher = tokenRefresher {
                do {
                    print("[APIClient] 401 detected, attempting token refresh...")
                    try await refreshCoordinator.refresh(using: tokenRefresher)
                    print("[APIClient] refresh succeeded, retrying request once")
                    return try await send(request, allowRetryAfterRefresh: false)
                } catch {
                    print("[APIClient] refresh failed: \(error)")
                    // Token 刷新失败，通知 App 用户需要重新登录
                    userFeedbackHandler?.handleAuthenticationFailure()
                    throw apiError
                }
            }
            // 401 错误但没有配置 tokenRefresher，直接通知认证失败
            if shouldAttemptRefresh(for: apiError) {
                userFeedbackHandler?.handleAuthenticationFailure()
            }
            throw apiError
        } catch {
            if let apiError = error as? APIError {
                throw apiError
            } else {
                logger.fault("‼️ 未处理的错误 \(request.path): \(error.localizedDescription)", tag: "unhandled-error")
                throw APIError.requestFailed(error)
            }
        }
    }

    private func shouldAttemptRefresh(for error: APIError) -> Bool {
        switch error {
        case .serverError(statusCode: 401, _):
            return true
        case .authenticationFailed:
            return true
        default:
            return false
        }
    }
}

// MARK: - Token Refresh Coordinator

internal actor TokenRefreshCoordinator {
    private var ongoingTask: Task<String, Error>?

    internal func refresh(using refresher: TokenRefresher) async throws {
        if let task = ongoingTask {
            _ = try await task.value
            return
        }

        let task = Task { () throws -> String in
            try await refresher.refreshToken()
        }
        ongoingTask = task
        defer { ongoingTask = nil }
        _ = try await task.value
    }
}
