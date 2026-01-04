import Foundation

/// mTLS 配置
///
/// 定义双向 TLS 认证的完整配置，包括：
/// - 证书提供者
/// - 域名限制
/// - 回退策略
///
/// ## 使用示例
///
/// ```swift
/// // 基本配置 - 所有域名都启用 mTLS
/// let config = MTLSConfiguration(certificateProvider: provider)
///
/// // 指定域名 - 只对特定域名启用
/// let config = MTLSConfiguration(
///     certificateProvider: provider,
///     pinnedDomains: ["api.example.com", "secure.example.com"]
/// )
///
/// // 允许回退 - 证书不可用时使用普通 TLS
/// let config = MTLSConfiguration(
///     certificateProvider: provider,
///     allowFallback: true
/// )
/// ```
public struct MTLSConfiguration: Sendable {

    /// 证书提供者
    public let certificateProvider: CertificateProvider

    /// 需要 mTLS 的域名列表
    ///
    /// - `nil`: 所有域名都启用 mTLS
    /// - `Set<String>`: 只对列表中的域名启用 mTLS
    public let pinnedDomains: Set<String>?

    /// 是否允许回退到普通 TLS
    ///
    /// 当证书不可用时：
    /// - `true`: 使用普通 TLS 继续请求
    /// - `false`: 取消请求并抛出错误
    public let allowFallback: Bool

    /// 服务端证书验证模式
    public let serverTrustMode: ServerTrustMode

    /// 创建 mTLS 配置
    ///
    /// - Parameters:
    ///   - certificateProvider: 证书提供者
    ///   - pinnedDomains: 需要 mTLS 的域名列表，nil 表示所有域名
    ///   - allowFallback: 证书不可用时是否回退到普通 TLS
    ///   - serverTrustMode: 服务端证书验证模式
    public init(
        certificateProvider: CertificateProvider,
        pinnedDomains: Set<String>? = nil,
        allowFallback: Bool = false,
        serverTrustMode: ServerTrustMode = .customEvaluation
    ) {
        self.certificateProvider = certificateProvider
        self.pinnedDomains = pinnedDomains
        self.allowFallback = allowFallback
        self.serverTrustMode = serverTrustMode
    }

    /// 检查指定域名是否需要 mTLS
    public func requiresMTLS(for host: String) -> Bool {
        guard let pinnedDomains = pinnedDomains else {
            return true  // 未指定域名列表，所有域名都需要
        }
        return pinnedDomains.contains(host)
    }
}

// MARK: - 服务端证书验证模式

public enum ServerTrustMode: Sendable {
    /// 使用系统默认验证
    case systemDefault

    /// 使用 CertificateProvider 的自定义验证
    case customEvaluation

    /// 禁用验证（仅用于开发环境，生产环境禁止使用）
    ///
    /// ⚠️ 警告：此模式会接受任何服务端证书，存在严重安全风险
    case disabled
}

// MARK: - 便捷构造器

public extension MTLSConfiguration {

    /// 创建开发环境配置
    ///
    /// - 允许回退
    /// - 使用自定义验证（支持自签名证书）
    static func development(
        certificateProvider: CertificateProvider,
        pinnedDomains: Set<String>? = nil
    ) -> MTLSConfiguration {
        MTLSConfiguration(
            certificateProvider: certificateProvider,
            pinnedDomains: pinnedDomains,
            allowFallback: true,
            serverTrustMode: .customEvaluation
        )
    }

    /// 创建生产环境配置
    ///
    /// - 不允许回退
    /// - 使用自定义验证
    static func production(
        certificateProvider: CertificateProvider,
        pinnedDomains: Set<String>
    ) -> MTLSConfiguration {
        MTLSConfiguration(
            certificateProvider: certificateProvider,
            pinnedDomains: pinnedDomains,
            allowFallback: false,
            serverTrustMode: .customEvaluation
        )
    }
}
