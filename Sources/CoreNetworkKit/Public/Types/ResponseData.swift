import Foundation

/// Unified response container aligned with kine-server `ResponseData<T>`.
///
/// Wraps the decoded payload together with HTTP metadata so that
/// interceptors and callers can inspect status / headers without
/// losing the typed data.
public struct ResponseData<T: Sendable>: Sendable {

    /// HTTP status code.
    public let status: Int

    /// Response headers (lowercased keys).
    public let headers: [String: String]

    /// Decoded response payload.
    public let data: T

    /// Whether the status code is in the 2xx range.
    public var ok: Bool { (200 ..< 300).contains(status) }

    public init(status: Int, headers: [String: String], data: T) {
        self.status = status
        self.headers = headers
        self.data = data
    }
}
