import Foundation

/// 网络错误统一类型
///
/// 封装所有可能的网络请求错误，提供统一的错误处理接口
public enum NetworkError: Error {
    /// 请求被取消
    case cancelled

    /// 请求超时
    case timeout

    /// 无网络连接
    case noNetwork

    /// 服务器错误
    /// - Parameters:
    ///   - statusCode: HTTP 状态码
    ///   - message: 错误消息
    case serverError(statusCode: Int, message: String?)

    /// 响应解码失败
    /// - Parameter error: 底层解码错误
    case decodingFailed(Error)

    /// 认证失败
    case authenticationFailed

    /// 重试次数耗尽
    /// - Parameter lastError: 最后一次请求的错误
    case retryExhausted(lastError: Error)

    /// URL 构建失败
    case invalidURL

    /// 未知错误
    /// - Parameter error: 底层错误
    case unknown(Error)
}

extension NetworkError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            return "请求已取消"
        case .timeout:
            return "请求超时"
        case .noNetwork:
            return "无网络连接"
        case .serverError(let statusCode, let message):
            if let message = message {
                return "服务器错误 (\(statusCode)): \(message)"
            }
            return "服务器错误 (\(statusCode))"
        case .decodingFailed(let error):
            return "响应解码失败: \(error.localizedDescription)"
        case .authenticationFailed:
            return "认证失败"
        case .retryExhausted(let lastError):
            return "重试次数已用尽: \(lastError.localizedDescription)"
        case .invalidURL:
            return "无效的 URL"
        case .unknown(let error):
            return "未知错误: \(error.localizedDescription)"
        }
    }
}

extension NetworkError {
    /// 判断是否为认证失败（401）
    var isUnauthorized: Bool {
        if case .serverError(let statusCode, _) = self, statusCode == 401 {
            return true
        }
        return false
    }

    /// 判断是否为客户端错误（4xx）
    var isClientError: Bool {
        if case .serverError(let statusCode, _) = self, (400..<500).contains(statusCode) {
            return true
        }
        return false
    }

    /// 判断是否为服务器错误（5xx）
    var isServerError: Bool {
        if case .serverError(let statusCode, _) = self, (500..<600).contains(statusCode) {
            return true
        }
        return false
    }
}
