import Foundation
import Security

/// 从 Bundle 加载证书的提供者
///
/// 支持从应用 Bundle 中加载：
/// - P12/PKCS12 格式的客户端证书（包含私钥）
/// - DER/PEM 格式的 CA 证书（用于验证自签名服务端）
///
/// ## 使用示例
///
/// ```swift
/// // 基本用法
/// let provider = try BundleCertificateProvider(
///     p12Name: "client-cert",
///     p12Password: "secret"
/// )
///
/// // 包含 CA 证书（自签名服务端场景）
/// let provider = try BundleCertificateProvider(
///     p12Name: "client-cert",
///     p12Password: KeychainManager.getPassword(),
///     caName: "ca-cert"
/// )
/// ```
public final class BundleCertificateProvider: CertificateProvider, @unchecked Sendable {

    // MARK: - Properties

    private let identity: SecIdentity
    private let certificate: SecCertificate
    private let anchors: [SecCertificate]

    // MARK: - Initialization

    /// 从 Bundle 加载证书
    ///
    /// - Parameters:
    ///   - p12Name: P12 文件名（不含扩展名）
    ///   - p12Password: P12 密码
    ///   - caName: CA 证书文件名（可选，用于自签名服务端验证）
    ///   - bundle: 证书所在的 Bundle，默认为 main bundle
    /// - Throws: `CertificateError` 如果加载失败
    public init(
        p12Name: String,
        p12Password: String,
        caName: String? = nil,
        bundle: Bundle = .main
    ) throws {
        // 加载 P12 客户端证书
        guard let p12URL = bundle.url(forResource: p12Name, withExtension: "p12") else {
            throw CertificateError.fileNotFound("\(p12Name).p12")
        }

        let p12Data: Data
        do {
            p12Data = try Data(contentsOf: p12URL)
        } catch {
            throw CertificateError.fileNotFound("\(p12Name).p12 - \(error.localizedDescription)")
        }

        let (identity, cert) = try Self.importP12(data: p12Data, password: p12Password)
        self.identity = identity
        self.certificate = cert

        // 加载 CA 证书（可选）
        if let caName = caName {
            self.anchors = try Self.loadCACertificates(name: caName, bundle: bundle)
        } else {
            self.anchors = []
        }
    }

    /// 直接使用 SecIdentity 初始化（用于 Keychain 场景）
    ///
    /// - Parameters:
    ///   - identity: 客户端身份
    ///   - anchors: CA 锚点证书列表
    public init(identity: SecIdentity, anchors: [SecCertificate] = []) throws {
        self.identity = identity

        var certificate: SecCertificate?
        let status = SecIdentityCopyCertificate(identity, &certificate)

        guard status == errSecSuccess, let cert = certificate else {
            throw CertificateError.identityNotFound
        }

        self.certificate = cert
        self.anchors = anchors
    }

    // MARK: - CertificateProvider

    public var isAvailable: Bool { true }

    public func clientCredential() throws -> URLCredential {
        URLCredential(
            identity: identity,
            certificates: [certificate] as [Any],
            persistence: .forSession
        )
    }

    public func evaluateServerTrust(_ trust: SecTrust, for host: String) -> Bool {
        // 如果有自定义 CA，使用它作为锚点
        if !anchors.isEmpty {
            SecTrustSetAnchorCertificates(trust, anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }

        var error: CFError?
        let isValid = SecTrustEvaluateWithError(trust, &error)

        if !isValid, let error = error {
            print("⚠️ [BundleCertificateProvider] 服务端证书验证失败 [\(host)]: \(error.localizedDescription)")
        }

        return isValid
    }

    // MARK: - Certificate Info

    /// 获取客户端证书的主题名称
    public var subjectName: String? {
        if let summary = SecCertificateCopySubjectSummary(certificate) as String? {
            return summary
        }
        return nil
    }

    /// 获取证书过期时间（需要解析证书数据）
    /// 注意：此功能仅在 macOS 上可用，iOS 上返回 nil
    public var expirationDate: Date? {
        #if os(macOS)
        // 获取证书的属性（macOS only API）
        guard let values = SecCertificateCopyValues(certificate, nil, nil) as? [String: Any],
              let notAfterDict = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any],
              let notAfterValue = notAfterDict[kSecPropertyKeyValue as String] else {
            return nil
        }

        if let date = notAfterValue as? Date {
            return date
        } else if let number = notAfterValue as? NSNumber {
            return Date(timeIntervalSinceReferenceDate: number.doubleValue)
        }

        return nil
        #else
        // iOS 不支持 SecCertificateCopyValues API
        // 如需获取证书过期时间，需要手动解析 ASN.1 数据
        return nil
        #endif
    }

    // MARK: - Private Methods

    /// 导入 P12 证书
    private static func importP12(data: Data, password: String) throws -> (SecIdentity, SecCertificate) {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]

        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)

        // 处理错误状态
        guard status == errSecSuccess else {
            if status == errSecAuthFailed {
                throw CertificateError.invalidPassword
            }
            throw CertificateError.importFailed(status)
        }

        // 提取身份
        guard let itemsArray = items as? [[String: Any]],
              let firstItem = itemsArray.first else {
            throw CertificateError.identityNotFound
        }

        // SecIdentity 是 CFType，需要特殊处理
        guard let identityRef = firstItem[kSecImportItemIdentity as String] else {
            throw CertificateError.identityNotFound
        }

        // 验证类型并转换
        let identity = identityRef as! SecIdentity

        // 从身份中提取证书
        var certificate: SecCertificate?
        let copyStatus = SecIdentityCopyCertificate(identity, &certificate)

        guard copyStatus == errSecSuccess, let cert = certificate else {
            throw CertificateError.identityNotFound
        }

        return (identity, cert)
    }

    /// 加载 CA 证书
    private static func loadCACertificates(name: String, bundle: Bundle) throws -> [SecCertificate] {
        // 尝试多种扩展名
        let extensions = ["crt", "cer", "pem", "der"]

        for ext in extensions {
            if let url = bundle.url(forResource: name, withExtension: ext),
               let data = try? Data(contentsOf: url),
               let cert = parseCertificate(data: data) {
                return [cert]
            }
        }

        throw CertificateError.fileNotFound("\(name).[crt|cer|pem|der]")
    }

    /// 解析证书数据（支持 DER 和 PEM 格式）
    private static func parseCertificate(data: Data) -> SecCertificate? {
        // 尝试 DER 格式（二进制）
        if let cert = SecCertificateCreateWithData(nil, data as CFData) {
            return cert
        }

        // 尝试 PEM 格式（Base64 编码）
        if let pemString = String(data: data, encoding: .utf8) {
            let base64 = pemString
                .replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                .components(separatedBy: .whitespacesAndNewlines)
                .joined()

            if let derData = Data(base64Encoded: base64),
               let cert = SecCertificateCreateWithData(nil, derData as CFData) {
                return cert
            }
        }

        return nil
    }
}

// MARK: - 多证书支持

public extension BundleCertificateProvider {

    /// 加载多个 CA 证书
    ///
    /// - Parameters:
    ///   - p12Name: P12 文件名
    ///   - p12Password: P12 密码
    ///   - caNames: CA 证书文件名列表
    ///   - bundle: Bundle
    static func withMultipleCAs(
        p12Name: String,
        p12Password: String,
        caNames: [String],
        bundle: Bundle = .main
    ) throws -> BundleCertificateProvider {
        // 加载 P12
        guard let p12URL = bundle.url(forResource: p12Name, withExtension: "p12") else {
            throw CertificateError.fileNotFound("\(p12Name).p12")
        }

        let p12Data = try Data(contentsOf: p12URL)
        let (identity, _) = try importP12(data: p12Data, password: p12Password)

        // 加载所有 CA 证书
        var anchors: [SecCertificate] = []
        for caName in caNames {
            let certs = try loadCACertificates(name: caName, bundle: bundle)
            anchors.append(contentsOf: certs)
        }

        return try BundleCertificateProvider(identity: identity, anchors: anchors)
    }
}
