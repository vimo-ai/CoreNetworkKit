import Foundation
import Alamofire

/// mTLS Session Delegate
///
/// 处理 URLSession 的证书挑战，包括：
/// - 服务端证书验证 (NSURLAuthenticationMethodServerTrust)
/// - 客户端证书提供 (NSURLAuthenticationMethodClientCertificate)
///
/// 继承自 Alamofire 的 SessionDelegate，保留其所有功能
public final class MTLSSessionDelegate: SessionDelegate, @unchecked Sendable {

    private let mTLSConfig: MTLSConfiguration

    /// 创建 mTLS Session Delegate
    ///
    /// - Parameter configuration: mTLS 配置
    public init(configuration: MTLSConfiguration) {
        self.mTLSConfig = configuration
        super.init()
    }

    // MARK: - URLSessionTaskDelegate

    /// Task 级别的证书挑战处理
    ///
    /// Alamofire 的 SessionDelegate 只处理 Task 级别的挑战
    public override func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        let authMethod = challenge.protectionSpace.authenticationMethod

        // 检查是否需要对该域名启用 mTLS
        guard mTLSConfig.requiresMTLS(for: host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        switch authMethod {
        case NSURLAuthenticationMethodServerTrust:
            handleServerTrust(challenge, completionHandler: completionHandler)

        case NSURLAuthenticationMethodClientCertificate:
            handleClientCertificate(challenge, completionHandler: completionHandler)

        default:
            // 其他认证方式使用默认处理
            completionHandler(.performDefaultHandling, nil)
        }
    }

    // MARK: - Server Trust Handling

    private func handleServerTrust(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host

        guard let serverTrust = challenge.protectionSpace.serverTrust else {
            print("❌ [mTLS] 无法获取服务端信任对象: \(host)")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        switch mTLSConfig.serverTrustMode {
        case .systemDefault:
            // 使用系统默认验证
            completionHandler(.performDefaultHandling, nil)

        case .customEvaluation:
            // 使用 CertificateProvider 自定义验证
            if mTLSConfig.certificateProvider.evaluateServerTrust(serverTrust, for: host) {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
            } else {
                print("❌ [mTLS] 服务端证书验证失败: \(host)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        case .disabled:
            // 禁用验证（仅开发环境）
            #if DEBUG
            print("⚠️ [mTLS] 服务端证书验证已禁用（开发模式）: \(host)")
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
            #else
            // 生产环境不允许禁用
            print("❌ [mTLS] 生产环境不允许禁用证书验证")
            completionHandler(.cancelAuthenticationChallenge, nil)
            #endif
        }
    }

    // MARK: - Client Certificate Handling

    private func handleClientCertificate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host

        // 检查证书是否可用
        guard mTLSConfig.certificateProvider.isAvailable else {
            if mTLSConfig.allowFallback {
                print("⚠️ [mTLS] 客户端证书不可用，回退到普通模式: \(host)")
                completionHandler(.performDefaultHandling, nil)
            } else {
                print("❌ [mTLS] 客户端证书不可用且不允许回退: \(host)")
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
            return
        }

        // 获取客户端凭证
        do {
            let credential = try mTLSConfig.certificateProvider.clientCredential()
            completionHandler(.useCredential, credential)
        } catch {
            print("❌ [mTLS] 获取客户端证书失败: \(error.localizedDescription)")

            if mTLSConfig.allowFallback {
                completionHandler(.performDefaultHandling, nil)
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }
}
