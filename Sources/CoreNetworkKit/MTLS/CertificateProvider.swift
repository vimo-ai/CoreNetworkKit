import Foundation
import Security

/// 证书提供者协议
///
/// 抽象证书的加载和管理，支持多种来源：
/// - Bundle 内置证书
/// - Keychain 存储
/// - 远程下发
///
/// ## 使用示例
///
/// ```swift
/// // 从 Bundle 加载
/// let provider = try BundleCertificateProvider(
///     p12Name: "client",
///     p12Password: "secret",
///     caName: "ca"
/// )
///
/// // 创建 mTLS 配置
/// let config = MTLSConfiguration(certificateProvider: provider)
/// ```
public protocol CertificateProvider: Sendable {

    /// 证书是否可用
    ///
    /// 在创建网络请求前检查此属性，决定是否启用 mTLS
    var isAvailable: Bool { get }

    /// 获取客户端身份凭证
    ///
    /// 当服务端发起 `NSURLAuthenticationMethodClientCertificate` 挑战时调用
    ///
    /// - Returns: 包含客户端身份（私钥 + 证书）的 URLCredential
    /// - Throws: `CertificateError` 如果证书不可用
    func clientCredential() throws -> URLCredential

    /// 验证服务端信任
    ///
    /// 当服务端发起 `NSURLAuthenticationMethodServerTrust` 挑战时调用
    /// 用于处理自签名证书或证书锁定场景
    ///
    /// - Parameters:
    ///   - trust: 服务端提供的信任对象
    ///   - host: 服务端主机名
    /// - Returns: 是否信任该服务端
    func evaluateServerTrust(_ trust: SecTrust, for host: String) -> Bool
}

// MARK: - 默认实现

public extension CertificateProvider {

    /// 默认使用系统信任评估
    func evaluateServerTrust(_ trust: SecTrust, for host: String) -> Bool {
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}

// MARK: - 空实现（用于测试）

/// 空证书提供者，用于测试或不需要客户端证书的场景
public struct NoCertificateProvider: CertificateProvider {

    public init() {}

    public var isAvailable: Bool { false }

    public func clientCredential() throws -> URLCredential {
        throw CertificateError.clientCertificateRequired
    }

    public func evaluateServerTrust(_ trust: SecTrust, for host: String) -> Bool {
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
