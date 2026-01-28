import Foundation
import Security

/// WebSocket 连接状态
public enum WebSocketConnectionState {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

/// WebSocket 认证方式
public enum WebSocketAuthMethod {
    /// Token 作为 URL query 参数 (如 ?token=xxx)
    case queryParam(key: String = "token")
    /// Token 作为 HTTP Header (如 Authorization: Bearer xxx)
    case bearerHeader
    /// 自定义 Header
    case customHeader(key: String)
    /// 无认证
    case none
}

/// WebSocket 配置
public struct WebSocketConfiguration {
    /// 服务器 URL
    public let url: URL

    /// 认证 Token
    public let token: String?

    /// 认证方式
    public let authMethod: WebSocketAuthMethod

    /// 是否启用日志
    public let enableLogging: Bool

    /// 是否启用自动重连
    public let reconnects: Bool

    /// 最大重连次数
    public let reconnectAttempts: Int

    /// 重连等待时间（秒）
    public let reconnectWait: TimeInterval

    /// 额外的连接参数
    public let extraParams: [String: Any]?

    /// 额外的 HTTP Headers
    public let extraHeaders: [String: String]?

    /// mTLS 证书提供者（可选）
    public let certificateProvider: CertificateProvider?

    /// 自定义 URLSession Delegate（用于 mTLS）
    public let sessionDelegate: URLSessionDelegate?

    /// 是否启用安全连接（HTTPS）
    public let secure: Bool

    /// 是否允许自签名证书
    public let selfSigned: Bool

    public init(
        url: URL,
        token: String? = nil,
        authMethod: WebSocketAuthMethod = .queryParam(),
        enableLogging: Bool = false,
        reconnects: Bool = true,
        reconnectAttempts: Int = 5,
        reconnectWait: TimeInterval = 2,
        extraParams: [String: Any]? = nil,
        extraHeaders: [String: String]? = nil,
        certificateProvider: CertificateProvider? = nil,
        sessionDelegate: URLSessionDelegate? = nil,
        secure: Bool = false,
        selfSigned: Bool = false
    ) {
        self.url = url
        self.token = token
        self.authMethod = authMethod
        self.enableLogging = enableLogging
        self.reconnects = reconnects
        self.reconnectAttempts = reconnectAttempts
        self.reconnectWait = reconnectWait
        self.extraParams = extraParams
        self.extraHeaders = extraHeaders
        self.certificateProvider = certificateProvider
        self.sessionDelegate = sessionDelegate
        self.secure = secure
        self.selfSigned = selfSigned
    }

    /// 使用 Token (query 参数方式) 创建配置
    public static func withToken(_ token: String, url: URL) -> WebSocketConfiguration {
        WebSocketConfiguration(url: url, token: token, authMethod: .queryParam())
    }

    /// 使用 JWT Bearer Token 创建配置
    public static func withBearerToken(_ token: String, url: URL) -> WebSocketConfiguration {
        WebSocketConfiguration(url: url, token: token, authMethod: .bearerHeader)
    }

    /// 使用 mTLS 创建配置
    public static func withMTLS(
        url: URL,
        token: String? = nil,
        certificateProvider: CertificateProvider,
        sessionDelegate: URLSessionDelegate
    ) -> WebSocketConfiguration {
        WebSocketConfiguration(
            url: url,
            token: token,
            authMethod: .queryParam(),
            certificateProvider: certificateProvider,
            sessionDelegate: sessionDelegate,
            secure: true,
            selfSigned: true
        )
    }
}

/// 通用 WebSocket 消息包装
public struct WebSocketMessage<T: Decodable>: Decodable {
    public let data: T?
    public let event: String?

    public init(data: T?, event: String? = nil) {
        self.data = data
        self.event = event
    }
}
