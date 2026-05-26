import Foundation

// MARK: - TraceContext

public struct TraceContext: Sendable {
    public let requestId: String
    public let parentRequestId: String?
    public let method: String
    public let url: String

    public init(requestId: String, parentRequestId: String?, method: String, url: String) {
        self.requestId = requestId
        self.parentRequestId = parentRequestId
        self.method = method
        self.url = url
    }
}

// MARK: - TracingConfig

public struct TracingConfig: Sendable {
    /// Header name for the request ID. Defaults to "x-request-id".
    public var headerName: String

    /// Header name for the parent request ID. Defaults to "x-parent-request-id".
    public var parentHeaderName: String

    /// ID generator. Defaults to UUID.
    public var generateId: @Sendable () -> String

    /// Optional callback invoked for every traced request.
    public var onTrace: (@Sendable (TraceContext) -> Void)?

    public init(
        headerName: String = "x-request-id",
        parentHeaderName: String = "x-parent-request-id",
        generateId: @escaping @Sendable () -> String = { UUID().uuidString },
        onTrace: (@Sendable (TraceContext) -> Void)? = nil
    ) {
        self.headerName = headerName
        self.parentHeaderName = parentHeaderName
        self.generateId = generateId
        self.onTrace = onTrace
    }
}

// MARK: - TracingInterceptor

/// Injects `x-request-id` (and optionally `x-parent-request-id`) into
/// every outgoing request. Aligned with kine-server `createTracingInterceptor`.
public func createTracingInterceptor(config: TracingConfig = TracingConfig()) -> RequestInterceptor {
    TracingInterceptorImpl(config: config)
}

private struct TracingInterceptorImpl: RequestInterceptor, Sendable {
    let config: TracingConfig

    func onRequest(_ requestConfig: RequestConfig) async throws -> RequestConfig {
        var updated = requestConfig
        let existingId = updated.headers[config.headerName]

        let requestId: String
        var parentRequestId: String?

        if let existing = existingId {
            parentRequestId = existing
            requestId = config.generateId()
            updated.headers[config.parentHeaderName] = parentRequestId
        } else {
            requestId = config.generateId()
        }

        updated.headers[config.headerName] = requestId

        config.onTrace?(TraceContext(
            requestId: requestId,
            parentRequestId: parentRequestId,
            method: requestConfig.method.rawValue,
            url: requestConfig.url
        ))

        return updated
    }
}
