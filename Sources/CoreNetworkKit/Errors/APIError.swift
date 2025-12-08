import Foundation

public enum APIError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case decodingError(Error)
    case serverError(statusCode: Int, message: String?)
    case custom(code: Int, message: String)
    case noData(message: String)
    case decodingFailed(error: DecodingError, data: Data?)
    case unknownError
    case requestFailed(Error?)
    case unacceptableStatusCode(Int, Data?)
    case authenticationFailed(reason: AuthenticationFailureReason)
    case unknown(error: Error)

    public enum AuthenticationFailureReason {
        case tokenNotFound
    }

    public var underlyingError: Error? {
        switch self {
        case .networkError(let error), .decodingError(let error):
            return error
        default:
            return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的URL。"
        case .networkError(let error):
            return "网络错误: \(error.localizedDescription)"
        case .decodingError(let error):
            if let decodingError = error as? DecodingError {
                return "解码服务器响应失败:\n\(DecodingErrorFormatter.format(decodingError))"
            }
            return "解码服务器响应失败: \(error.localizedDescription)"
        case .serverError(let statusCode, let message):
            return "服务器错误，状态码 \(statusCode): \(message ?? "无消息")"
        case .custom(let code, let message):
            return "错误 \(code): \(message)"
        case .noData:
            return "服务器未返回数据。"
        case .decodingFailed(let error, let data):
            var description = "数据解码失败:\n\(DecodingErrorFormatter.format(error))"
            if let data = data, let rawString = String(data: data, encoding: .utf8) {
                description += "原始响应: \(rawString)"
            }
            return description
        case .unknownError:
            return "发生未知错误。"
        case .requestFailed(let error):
            return "请求失败: \(error?.localizedDescription ?? "无错误信息")"
        case .unacceptableStatusCode(let code, let data):
            var description = "收到不可接受的状态码: \(code)"
            if let data = data, let rawString = String(data: data, encoding: .utf8) {
                description += "\n原始响应: \(rawString)"
            }
            return description
        case .authenticationFailed(let reason):
            return reason.localizedDescription
        case .unknown(let error):
            return "发生未知错误: \(error.localizedDescription)"
        }
    }
}

extension APIError.AuthenticationFailureReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .tokenNotFound:
            return "认证失败，因为未找到所需的令牌。"
        }
    }
}