import Foundation

/// Unified request error type aligned with kine-server `RequestError`.
///
/// Replaces the legacy `APIError` enum with a class-based error that
/// carries structured metadata (code, status, url, method) so that
/// interceptors and callers can inspect failures uniformly.
public final class RequestError: Error, @unchecked Sendable {

    /// The classified error code.
    public let code: ErrorCode

    /// HTTP status code, if the server responded.
    public let status: Int?

    /// The request URL that produced this error.
    public let url: String

    /// The HTTP method of the failing request.
    public let method: String

    /// Human-readable error description.
    public let message: String

    /// The underlying error that caused this failure, if any.
    public let cause: Error?

    public init(
        code: ErrorCode,
        status: Int? = nil,
        url: String,
        method: String,
        message: String,
        cause: Error? = nil
    ) {
        self.code = code
        self.status = status
        self.url = url
        self.method = method
        self.message = message
        self.cause = cause
    }

    // MARK: - Convenience Predicates

    public var isTimeout: Bool { code == .timeout }
    public var isAbort: Bool { code == .abort }
    public var isNetwork: Bool { code == .network }
    public var isAuth: Bool { code == .auth }
    public var isCircuitOpen: Bool { code == .circuitOpen }

    /// Whether the server returned a 5xx status.
    public var isServerError: Bool {
        guard let s = status else { return false }
        return s >= 500
    }
}

// MARK: - CustomStringConvertible

extension RequestError: CustomStringConvertible {
    public var description: String {
        var parts = ["RequestError[\(code.rawValue)] \(method) \(url)"]
        if let s = status { parts.append("status=\(s)") }
        parts.append(message)
        return parts.joined(separator: " ")
    }
}

// MARK: - LocalizedError

extension RequestError: LocalizedError {
    public var errorDescription: String? { message }
}
