import Foundation

// MARK: - TokenInterceptorConfig

public struct TokenInterceptorConfig: Sendable {
    /// Closure that returns the current token, or nil if none is available.
    public let getToken: @Sendable () -> String?

    /// The header name to set. Defaults to "Authorization".
    public var headerName: String

    /// The auth scheme prefix. Defaults to "Bearer".
    /// Set to empty string to send the raw token without a scheme.
    public var scheme: String

    public init(
        getToken: @escaping @Sendable () -> String?,
        headerName: String = "Authorization",
        scheme: String = "Bearer"
    ) {
        self.getToken = getToken
        self.headerName = headerName
        self.scheme = scheme
    }
}

// MARK: - TokenInterceptor

/// Injects a bearer (or custom scheme) token into every outgoing request.
/// Aligned with kine-server `createTokenInterceptor`.
public func createTokenInterceptor(config: TokenInterceptorConfig) -> RequestInterceptor {
    TokenInterceptorImpl(config: config)
}

private struct TokenInterceptorImpl: RequestInterceptor, Sendable {
    let config: TokenInterceptorConfig

    func onRequest(_ requestConfig: RequestConfig) async throws -> RequestConfig {
        guard let token = config.getToken() else { return requestConfig }
        var updated = requestConfig
        let value = config.scheme.isEmpty ? token : "\(config.scheme) \(token)"
        updated.headers[config.headerName] = value
        return updated
    }
}
