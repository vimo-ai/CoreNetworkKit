import Foundation

/// Unified request configuration aligned with kine-server `RequestConfig`.
///
/// Represents a single HTTP request before it is dispatched. Interceptors
/// receive and return `RequestConfig` values, allowing them to mutate
/// headers, URL, body, etc.
public struct RequestConfig: Sendable {

    /// Fully-qualified request URL (after base URL resolution).
    public var url: String

    /// HTTP method.
    public var method: HTTPMethod

    /// Request headers.
    public var headers: [String: String]

    /// Encodable request body. Wrapped in a sendable box internally.
    public var body: (any Encodable & Sendable)?

    /// URL query parameters (appended to the URL at execution time).
    public var params: [String: String]?

    /// Per-request timeout override.
    public var timeout: TimeInterval?

    public init(
        url: String,
        method: HTTPMethod,
        headers: [String: String] = [:],
        body: (any Encodable & Sendable)? = nil,
        params: [String: String]? = nil,
        timeout: TimeInterval? = nil
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.body = body
        self.params = params
        self.timeout = timeout
    }
}
