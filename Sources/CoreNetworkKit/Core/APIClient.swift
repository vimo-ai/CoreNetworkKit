import Foundation
import MLoggerKit

/// 一个通用的、负责发送网络请求的客户端。
public final class APIClient {
    
    // MARK: - 属性
    
    internal let engine: NetworkEngine
    internal let tokenStorage: any TokenStorage
    internal let userFeedbackHandler: UserFeedbackHandler?
    // 使用 MLoggerKit 网络日志器
    internal let logger = LoggerFactory.network
    internal let jsonDecoder: JSONDecoder
    
    // MARK: - 初始化
    
    /// 初始化一个新的API客户端。
    /// - Parameters:
    ///   - engine: 用于发送请求的网络引擎。
    ///   - tokenStorage: 用户令牌的存储机制。
    ///   - userFeedbackHandler: 用户反馈处理器，用于BeaconFlow请求的Toast显示和日志记录。
    ///   - jsonDecoder: 一个可选的JSON解码器，如果需要自定义解码策略。
    public init(engine: NetworkEngine, tokenStorage: any TokenStorage, userFeedbackHandler: UserFeedbackHandler? = nil, jsonDecoder: JSONDecoder = JSONDecoder()) {
        self.engine = engine
        self.tokenStorage = tokenStorage
        self.userFeedbackHandler = userFeedbackHandler
        self.jsonDecoder = jsonDecoder
    }
    
    // MARK: - 公开方法
    
    /// 发送一个网络请求并返回解码后的响应。
    /// - Parameter request: 一个遵循 `Request` 协议的请求实例。
    /// - Returns: 解码后的响应模型。
    public func send<R: Request>(_ request: R) async throws -> R.Response {
        var responseData: Data?
        do {
            // 1. 根据 Request 协议的属性构建基础的 URLRequest。
            let urlRequest = try buildURLRequest(from: request)
            
            // 记录请求信息
            logger.debug("📤 \(urlRequest.httpMethod ?? "") \(urlRequest.url?.path ?? "")", tag: "request")

            // 2. 创建认证上下文
            let authContext = AuthenticationContext(tokenStorage: self.tokenStorage)

            // 3. 异步地将认证策略应用于请求。
            let authenticatedRequest = try await request.authentication.apply(to: urlRequest, context: authContext)
            
            // 4. 使用认证后的请求执行网络调用。
            let (data, response) = try await engine.performRequest(authenticatedRequest)
            responseData = data
            
            // 5. 验证HTTP响应状态码。
            try validate(response: response, data: data)

            // 6. 解码响应模型。这是解码的唯一点。
            // 业务码的检查（如 code == 0）应由调用方或更高层来处理，而不是在这个通用客户端中。
            let responseModel = try jsonDecoder.decode(R.Response.self, from: data)
            
            return responseModel

        } catch let error as DecodingError {
            logger.error("解码失败 \(request.path): \(error.localizedDescription)", tag: "decode-error")
            
            // 如果解码失败，记录原始数据。
            if let data = responseData, let rawString = String(data: data, encoding: .utf8) {
                logger.debug("解码失败时的原始数据:\n---BEGIN---\n\(rawString)\n---END---", tag: "raw-data")
            }
            
            throw APIError.decodingFailed(error: error, data: responseData)
        } catch {
            // 如果已经是APIError，则重新抛出，否则包装它。
            if let apiError = error as? APIError {
                throw apiError
            } else {
                logger.fault("‼️ 未处理的错误 \(request.path): \(error.localizedDescription)", tag: "unhandled-error")
                throw APIError.requestFailed(error)
            }
        }
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
}