import Foundation

/// mTLS 证书相关错误
public enum CertificateError: Error, LocalizedError {
    /// 证书文件未找到
    case fileNotFound(String)

    /// P12 密码错误
    case invalidPassword

    /// 证书格式无效
    case invalidFormat(String)

    /// PKCS12 导入失败
    case importFailed(OSStatus)

    /// 未找到身份凭证
    case identityNotFound

    /// 证书链不完整
    case certificateChainIncomplete

    /// 服务端证书验证失败
    case serverTrustFailed(host: String, reason: String)

    /// 服务端要求客户端证书但未提供
    case clientCertificateRequired

    /// 证书已过期
    case certificateExpired(expirationDate: Date)

    /// 证书尚未生效
    case certificateNotYetValid(validFrom: Date)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let filename):
            return "证书文件未找到: \(filename)"
        case .invalidPassword:
            return "P12 证书密码错误"
        case .invalidFormat(let detail):
            return "证书格式无效: \(detail)"
        case .importFailed(let status):
            return "证书导入失败，错误码: \(status)"
        case .identityNotFound:
            return "证书中未找到身份凭证"
        case .certificateChainIncomplete:
            return "证书链不完整"
        case .serverTrustFailed(let host, let reason):
            return "服务端证书验证失败 [\(host)]: \(reason)"
        case .clientCertificateRequired:
            return "服务端要求客户端证书"
        case .certificateExpired(let date):
            return "证书已过期: \(date)"
        case .certificateNotYetValid(let date):
            return "证书尚未生效，生效时间: \(date)"
        }
    }
}
