import Foundation

// MARK: - AuthInterceptorConfig

public struct AuthInterceptorConfig: Sendable {
    /// Callback invoked when an unauthorized error is detected.
    public let onUnauthorized: @Sendable (RequestError) -> Void

    /// HTTP status codes treated as auth failures. Defaults to [401, 403].
    public var statusCodes: [Int]

    public init(
        onUnauthorized: @escaping @Sendable (RequestError) -> Void,
        statusCodes: [Int] = [401, 403]
    ) {
        self.onUnauthorized = onUnauthorized
        self.statusCodes = statusCodes
    }
}

// MARK: - AuthInterceptor

/// Detects auth-related errors and notifies the caller.
/// Aligned with kine-server `createAuthInterceptor`.
///
/// This interceptor does **not** retry or refresh tokens. It simply
/// fires `onUnauthorized` so the application can react (e.g., log out,
/// show login UI).
public func createAuthInterceptor(config: AuthInterceptorConfig) -> RequestInterceptor {
    AuthInterceptorImpl(config: config)
}

private struct AuthInterceptorImpl: RequestInterceptor, Sendable {
    let config: AuthInterceptorConfig

    func onError(_ error: RequestError) async throws -> RequestError {
        if let status = error.status, config.statusCodes.contains(status) {
            config.onUnauthorized(error)
        }
        return error
    }
}
