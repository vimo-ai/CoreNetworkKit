import Foundation
import MLoggerKit


// MARK: - APIClient BeaconFlow Extension

extension APIClient {
    
    /// BeaconFlow专用API日志器
    private var apiLogger: MLogger { LoggerFactory.api }
    
    /// 发送BeaconFlow请求并自动解包响应
    /// 
    /// BeaconFlow系统的请求会自动：
    /// 1. 解包WrappedResponse<T>格式的响应
    /// 2. 检查业务状态(success字段)
    /// 3. 处理业务失败时的用户反馈
    /// 4. 返回解包后的纯净数据
    /// 5. 在遇到401错误时自动刷新token并重试
    ///
    /// - Parameter request: BeaconFlow请求实例
    /// - Returns: 解包后的响应数据
    /// - Throws: APIError或BusinessError
    public func send<R: BeaconFlowRequest>(_ request: R) async throws -> R.Response {
        return try await send(request, allowRetryAfterRefresh: true)
    }
    
    /// 内部发送方法，支持token刷新后重试
    private func send<R: BeaconFlowRequest>(_ request: R, allowRetryAfterRefresh: Bool) async throws -> R.Response {
        var responseData: Data?
        do {

            // 1. 构建URLRequest
            let urlRequest = try buildURLRequest(from: request)
            
            apiLogger.debug("📤 [BeaconFlow] \(urlRequest.httpMethod ?? "") \(urlRequest.url?.path ?? "")", tag: "beacon-request")

            // 2. 应用认证
            let authContext = AuthenticationContext(tokenStorage: self.tokenStorage)
            let authenticatedRequest = try await request.authentication.apply(to: urlRequest, context: authContext)

            
            // 3. 执行网络请求
            let (data, response) = try await engine.performRequest(authenticatedRequest)
            responseData = data

            
            // 4. 验证HTTP状态码
            try validate(response: response, data: data)

            // 5. 解码为包装响应
            let wrappedResponse = try jsonDecoder.decode(BeaconFlowWrappedResponse<R.Response>.self, from: data)
            
            // 6. 检查业务状态
            if !wrappedResponse.success {
                apiLogger.warning("🚨 [BeaconFlow] 业务失败: \(wrappedResponse.message)", tag: "business-error")
                
                // 触发用户反馈 - 显示错误消息
                if let feedbackHandler = self.userFeedbackHandler {
                    feedbackHandler.showError(message: wrappedResponse.message)
                } else {
                    apiLogger.debug("💬 业务错误消息: \(wrappedResponse.message)", tag: "no-feedback-handler")
                }
                
                throw BeaconFlowBusinessError(message: wrappedResponse.message, timestamp: wrappedResponse.timestamp)
            }
            
            // 7. 记录成功日志
            if !wrappedResponse.message.isEmpty {
                apiLogger.info("✅ [BeaconFlow] \(wrappedResponse.message)", tag: "success")
            }
            
            // 8. 返回解包后的数据
            if let data = wrappedResponse.data {
                return data
            } else {
                // 对于操作类API（EmptyResponse），创建空实例
                if R.Response.self == EmptyResponse.self {
                    return EmptyResponse() as! R.Response
                } else {
                    // 其他类型要求data字段必须存在
                    apiLogger.error("❌ [BeaconFlow] 响应缺少data字段，但期望类型不是EmptyResponse", tag: "missing-data")
                    throw APIError.decodingFailed(error: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing required data field")), data: responseData)
                }
            }

        } catch let error as DecodingError {
            apiLogger.error("❌ [BeaconFlow] 解码失败 \(request.path):\n\(DecodingErrorFormatter.format(error))", tag: "decode-error")

            // 记录原始数据用于调试
            if let data = responseData, let rawString = String(data: data, encoding: .utf8) {
                apiLogger.debug("🔍 [BeaconFlow] 解码失败时的原始数据:\n---BEGIN---\n\(rawString)\n---END---", tag: "raw-response")
            }

            throw APIError.decodingFailed(error: error, data: responseData)
        } catch let error as BeaconFlowBusinessError {
            // 业务错误直接重新抛出
            throw error
        } catch let apiError as APIError {
            // 尝试 token refresh（仅限401错误且允许重试）
            print("[APIClient+BeaconFlow] 捕获到 APIError: \(apiError)")
            print("[APIClient+BeaconFlow] allowRetryAfterRefresh = \(allowRetryAfterRefresh)")
            print("[APIClient+BeaconFlow] shouldAttemptRefresh = \(shouldAttemptRefresh(for: apiError))")
            print("[APIClient+BeaconFlow] tokenRefresher is nil? \(tokenRefresher == nil)")
            
            if allowRetryAfterRefresh,
               shouldAttemptRefresh(for: apiError),
               let tokenRefresher = tokenRefresher {
                do {
                    print("[APIClient+BeaconFlow] 401 detected, attempting token refresh...")
                    try await refreshCoordinator.refresh(using: tokenRefresher)
                    print("[APIClient+BeaconFlow] refresh succeeded, retrying request once")
                    return try await send(request, allowRetryAfterRefresh: false)
                } catch {
                    print("[APIClient+BeaconFlow] refresh failed: \(error)")
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
            // 其他错误包装为APIError
            if let apiError = error as? APIError {
                throw apiError
            } else {
                apiLogger.fault("‼️ [BeaconFlow] 未处理的错误 \(request.path): \(error.localizedDescription)", tag: "unhandled-error")
                throw APIError.requestFailed(error)
            }
        }
    }
    
    /// 判断是否应该尝试刷新token
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

