import Foundation
import MLoggerKit

// MARK: - NetworkClientConfig

/// Configuration for `NetworkClientV2`, aligned with kine-server `WebClientConfig`.
public struct NetworkClientConfig: Sendable {
    /// Base URL prepended to relative paths.
    public let baseURL: String

    /// Default request timeout (seconds).
    public var timeout: TimeInterval?

    /// Default headers applied to every request.
    public var headers: [String: String]

    /// Default retry policy.
    public var retry: RetryPolicy

    /// Default control policy (debounce / throttle / dedup).
    public var control: ControlPolicy

    /// JSON decoder used for response parsing.
    public var jsonDecoder: JSONDecoder

    /// JSON encoder used for request body serialization.
    public var jsonEncoder: JSONEncoder

    /// Response decoder that handles raw Data → T conversion.
    /// Use `DirectDecoder()` (default) for raw JSON, or
    /// `EnvelopeDecoder()` for `{success, data, message, timestamp}` unwrap.
    public var responseDecoder: ResponseDecoder

    public init(
        baseURL: String,
        timeout: TimeInterval? = nil,
        headers: [String: String] = [:],
        retry: RetryPolicy = .none,
        control: ControlPolicy = ControlPolicy(),
        jsonDecoder: JSONDecoder = JSONDecoder(),
        jsonEncoder: JSONEncoder = JSONEncoder(),
        responseDecoder: ResponseDecoder = DirectDecoder()
    ) {
        self.baseURL = baseURL
        self.timeout = timeout
        self.headers = headers
        self.retry = retry
        self.control = control
        self.jsonDecoder = jsonDecoder
        self.jsonEncoder = jsonEncoder
        self.responseDecoder = responseDecoder
    }
}

// MARK: - PerRequestConfig

/// Per-request overrides, aligned with kine-server `PerRequestConfig`.
public struct PerRequestConfig: Sendable {
    public var headers: [String: String]?
    public var timeout: TimeInterval?
    public var retry: RetryPolicy?
    public var control: ControlPolicy?
    public var priority: ControlPolicy.Priority?

    public init(
        headers: [String: String]? = nil,
        timeout: TimeInterval? = nil,
        retry: RetryPolicy? = nil,
        control: ControlPolicy? = nil,
        priority: ControlPolicy.Priority? = nil
    ) {
        self.headers = headers
        self.timeout = timeout
        self.retry = retry
        self.control = control
        self.priority = priority
    }
}

// MARK: - NetworkClientV2

/// Modern network client aligned with kine-server `WebClient`.
///
/// Provides a composable interceptor chain, flow control (debounce,
/// throttle, dedup), retry, and convenience HTTP verb methods.
///
/// The internal execution pipeline is:
/// 1. Merge per-request config with client config
/// 2. Apply interceptor chain (`onRequest`)
/// 3. Apply `ControlGateV2` (debounce / throttle / dedup)
/// 4. Apply `withRetry`
/// 5. Execute via `NetworkEngine`
/// 6. Apply interceptor chain (`onResponse` or `onError`)
public final class NetworkClientV2: @unchecked Sendable {

    private let chain = InterceptorChain()
    private let gate = ControlGateV2()
    private let config: NetworkClientConfig
    private let engine: NetworkEngine
    private let logger = LoggerFactory.network

    public init(config: NetworkClientConfig, engine: NetworkEngine) {
        self.config = config
        self.engine = engine
    }

    // MARK: - Interceptor Registration

    /// Register an interceptor. Returns an unsubscribe closure.
    @discardableResult
    public func use(_ interceptor: RequestInterceptor) -> () -> Void {
        chain.use(interceptor)
    }

    // MARK: - HTTP Verb Convenience Methods

    public func get<T: Decodable & Sendable>(
        _ url: String,
        params: [String: String]? = nil,
        config perRequest: PerRequestConfig? = nil
    ) async throws -> ResponseData<T> {
        try await execute(url: url, method: .get, body: nil as EmptyBody?, params: params, perRequest: perRequest)
    }

    public func post<T: Decodable & Sendable>(
        _ url: String,
        body: (any Encodable & Sendable)? = nil,
        config perRequest: PerRequestConfig? = nil
    ) async throws -> ResponseData<T> {
        try await execute(url: url, method: .post, body: body, params: nil, perRequest: perRequest)
    }

    public func put<T: Decodable & Sendable>(
        _ url: String,
        body: (any Encodable & Sendable)? = nil,
        config perRequest: PerRequestConfig? = nil
    ) async throws -> ResponseData<T> {
        try await execute(url: url, method: .put, body: body, params: nil, perRequest: perRequest)
    }

    public func delete<T: Decodable & Sendable>(
        _ url: String,
        body: (any Encodable & Sendable)? = nil,
        config perRequest: PerRequestConfig? = nil
    ) async throws -> ResponseData<T> {
        try await execute(url: url, method: .delete, body: body, params: nil, perRequest: perRequest)
    }

    public func patch<T: Decodable & Sendable>(
        _ url: String,
        body: (any Encodable & Sendable)? = nil,
        config perRequest: PerRequestConfig? = nil
    ) async throws -> ResponseData<T> {
        try await execute(url: url, method: .patch, body: body, params: nil, perRequest: perRequest)
    }

    // MARK: - Lifecycle

    /// Dispose the client, cancelling all pending debounces.
    public func dispose() {
        Task { await gate.dispose() }
    }

    // MARK: - Internal Execute Pipeline

    private func execute<T: Decodable & Sendable>(
        url: String,
        method: HTTPMethod,
        body: (any Encodable & Sendable)?,
        params: [String: String]?,
        perRequest: PerRequestConfig?
    ) async throws -> ResponseData<T> {
        // 1. Merge configuration
        let fullURL = Self.buildURL(base: config.baseURL, path: url)
        var merged = RequestConfig(
            url: fullURL,
            method: method,
            headers: config.headers.merging(perRequest?.headers ?? [:]) { _, new in new },
            body: body,
            params: params,
            timeout: perRequest?.timeout ?? config.timeout
        )

        // 2. Apply interceptor chain (onRequest)
        merged = try await chain.applyRequest(merged)

        // Resolve retry and control policies
        let retryPolicy = perRequest?.retry ?? config.retry
        let controlPolicy = perRequest?.control ?? config.control

        // 3 & 4. ControlGate wraps withRetry wraps the actual request.
        let key = buildRequestKey(method: merged.method.rawValue, url: merged.url, body: merged.body)

        let doRequest: @Sendable () async throws -> ResponseData<T> = { [engine, config, logger] in
            let urlRequest = try Self.buildURLRequest(from: merged, encoder: config.jsonEncoder)
            logger.debug("[\(method.rawValue)] \(merged.url)", tag: "v2-request")

            let (data, response) = try await engine.performRequest(urlRequest)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw RequestError(
                    code: .unknown,
                    url: merged.url,
                    method: merged.method.rawValue,
                    message: "Non-HTTP response received"
                )
            }

            let statusCode = httpResponse.statusCode
            let responseHeaders = Self.extractHeaders(from: httpResponse)

            guard (200 ..< 300).contains(statusCode) else {
                let serverMessage = String(data: data, encoding: .utf8) ?? "No response body"
                let code: ErrorCode = statusCode == 401 || statusCode == 403 ? .auth : .http
                throw RequestError(
                    code: code,
                    status: statusCode,
                    url: merged.url,
                    method: merged.method.rawValue,
                    message: "HTTP \(statusCode): \(serverMessage)"
                )
            }

            let decoded: T
            do {
                decoded = try config.responseDecoder.decode(T.self, from: data, using: config.jsonDecoder)
            } catch let error as BusinessErrorV2 {
                throw error
            } catch {
                throw RequestError(
                    code: .parse,
                    status: statusCode,
                    url: merged.url,
                    method: merged.method.rawValue,
                    message: "Failed to decode response: \(error.localizedDescription)",
                    cause: error
                )
            }

            return ResponseData(status: statusCode, headers: responseHeaders, data: decoded)
        }

        let doWithRetry: @Sendable () async throws -> ResponseData<T> = {
            try await withRetry(doRequest, policy: retryPolicy)
        }

        // 5. Execute through ControlGate
        do {
            let response: ResponseData<T> = try await gate.execute(
                key: key,
                fn: doWithRetry,
                policy: controlPolicy
            )
            // 6. Apply interceptor chain (onResponse)
            return try await chain.applyResponse(response)
        } catch let error as RequestError {
            // 6. Apply interceptor chain (onError)
            throw try await chain.applyError(error)
        } catch let error as CancellationError {
            let requestError = RequestError(
                code: .abort,
                url: merged.url,
                method: merged.method.rawValue,
                message: "Request cancelled",
                cause: error
            )
            throw try await chain.applyError(requestError)
        } catch {
            // Wrap unexpected errors
            let requestError = RequestError(
                code: .network,
                url: merged.url,
                method: merged.method.rawValue,
                message: error.localizedDescription,
                cause: error
            )
            throw try await chain.applyError(requestError)
        }
    }

    // MARK: - URL Building

    static func buildURL(base: String, path: String) -> String {
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return path
        }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = path.hasPrefix("/") ? path : "/\(path)"
        return trimmedBase + trimmedPath
    }

    // MARK: - URLRequest Building

    static func buildURLRequest(from config: RequestConfig, encoder: JSONEncoder) throws -> URLRequest {
        var urlString = config.url

        // Append query params
        if let params = config.params, !params.isEmpty {
            let queryString = params
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
                .joined(separator: "&")
            let separator = urlString.contains("?") ? "&" : "?"
            urlString += separator + queryString
        }

        guard let url = URL(string: urlString) else {
            throw RequestError(
                code: .unknown,
                url: urlString,
                method: config.method.rawValue,
                message: "Invalid URL: \(urlString)"
            )
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = config.method.rawValue

        for (key, value) in config.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        if let timeout = config.timeout {
            urlRequest.timeoutInterval = timeout
        }

        if let body = config.body {
            if urlRequest.value(forHTTPHeaderField: "Content-Type") == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            urlRequest.httpBody = try encoder.encode(AnyEncodableWrapper(body))
        }

        return urlRequest
    }

    // MARK: - Header Extraction

    static func extractHeaders(from response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers["\(key)".lowercased()] = "\(value)"
        }
        return headers
    }
}

// MARK: - AnyEncodableWrapper

private struct AnyEncodableWrapper: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        _encode = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}
