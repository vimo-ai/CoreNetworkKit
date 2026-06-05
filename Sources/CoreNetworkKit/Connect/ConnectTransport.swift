import Foundation
import Connect
import MLoggerKit

// MARK: - ConnectRPC Transport Bridge

/// A pure transport bridge that routes connect-swift calls through
/// CoreNetworkKit's `NetworkEngine`.
///
/// **v2 change**: Token refresh and auth logic have been removed from this
/// class. Authentication is now handled by the interceptor chain
/// (`TokenInterceptor`, `AuthInterceptor`). `ConnectTransport` is
/// responsible only for bridging connect-swift's `HTTPClientInterface`
/// to the underlying engine.
///
/// For legacy callers that still need auth injection at the transport
/// level, an optional `InterceptorChain` can be provided. The chain's
/// `onRequest` hooks will be applied before each outgoing request.
///
/// Usage:
/// ```swift
/// let engine = AlamofireEngine(mTLS: mtlsConfig)
/// let transport = ConnectTransport(engine: engine)
///
/// let client = ProtocolClient(
///     httpClient: transport,
///     config: ProtocolClientConfig(host: "https://api.example.com")
/// )
/// ```
public final class ConnectTransport: HTTPClientInterface, @unchecked Sendable {

    // MARK: - Dependencies

    private let engine: NetworkEngine
    private let chain: InterceptorChain?
    private let logger = LoggerFactory.network

    // MARK: - Initialization

    /// Create a ConnectRPC transport backed by CoreNetworkKit's networking stack.
    ///
    /// - Parameters:
    ///   - engine: The underlying network engine (e.g. `AlamofireEngine`).
    ///   - chain: Optional interceptor chain for header injection / auth.
    ///            Pass the same chain used by `NetworkClientV2` to share
    ///            token, tracing, and negotiation interceptors.
    public init(engine: NetworkEngine, chain: InterceptorChain? = nil) {
        self.engine = engine
        self.chain = chain
    }

    /// Legacy initializer preserved for backward compatibility.
    /// Auth is now handled by the interceptor chain; these parameters are
    /// used to construct a minimal chain internally.
    @available(*, deprecated, message: "Use init(engine:chain:) and register interceptors on the chain instead")
    public convenience init(
        engine: NetworkEngine,
        tokenStorage: TokenStorage,
        tokenRefresher: TokenRefresher? = nil,
        authStrategy: AuthenticationStrategy = BearerTokenAuthenticationStrategy()
    ) {
        let compatChain = InterceptorChain()
        compatChain.use(createTokenInterceptor(config: TokenInterceptorConfig(
            getToken: { () -> String? in
                // Synchronous bridge — TokenStorage.getToken() is async,
                // but the interceptor chain will call onRequest asynchronously.
                // We store a captured reference and let the async flow work.
                nil // Token injection happens in onRequest via the async path below.
            }
        )))
        // For full legacy compat we create a dedicated interceptor that
        // applies the auth strategy asynchronously.
        compatChain.use(LegacyAuthBridgeInterceptor(
            tokenStorage: tokenStorage,
            authStrategy: authStrategy
        ))
        self.init(engine: engine, chain: compatChain)
    }

    // MARK: - HTTPClientInterface

    @discardableResult
    public func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        let task = Task { [weak self] in
            guard let self else { return }

            do {
                let urlRequest = try await self.buildURLRequest(from: request)
                let (data, response) = try await self.engine.performRequest(urlRequest)

                let httpURLResponse = response as? HTTPURLResponse
                let statusCode = httpURLResponse?.statusCode ?? 0
                let responseHeaders = self.extractHeaders(from: httpURLResponse)
                let code = self.mapHTTPStatusToCode(statusCode)

                onMetrics(HTTPMetrics(taskMetrics: nil))

                onResponse(HTTPResponse(
                    code: code,
                    headers: responseHeaders,
                    message: data,
                    trailers: [:],
                    error: nil,
                    tracingInfo: HTTPResponse.TracingInfo(httpStatus: statusCode)
                ))
            } catch {
                onMetrics(HTTPMetrics(taskMetrics: nil))
                onResponse(HTTPResponse(
                    code: .unknown,
                    headers: [:],
                    message: nil,
                    trailers: [:],
                    error: self.mapToConnectError(error),
                    tracingInfo: nil
                ))
            }
        }

        return Cancelable {
            task.cancel()
        }
    }

    public func stream(
        request: HTTPRequest<Data?>,
        responseCallbacks: ResponseCallbacks
    ) -> RequestCallbacks<Data> {
        // connect-swift sends the request body via sendData(), then calls
        // sendClose() to signal "no more client data". We accumulate the
        // body parts and start the actual HTTP request on sendClose().
        let state = StreamState()

        return RequestCallbacks<Data>(
            cancel: { state.cancel() },
            sendData: { data in state.appendBody(data) },
            sendClose: { [weak self] in
                guard let self else { return }
                state.start(
                    transport: self,
                    request: request,
                    responseCallbacks: responseCallbacks
                )
            }
        )
    }

    fileprivate func executeStream(
        request: HTTPRequest<Data?>,
        body: Data,
        responseCallbacks: ResponseCallbacks
    ) async {
        do {
            let rebuilt = HTTPRequest(
                url: request.url,
                headers: request.headers,
                message: body,
                method: request.method,
                trailers: request.trailers,
                idempotencyLevel: request.idempotencyLevel
            )
            let urlRequest = try await self.buildURLRequest(from: rebuilt)
            let dataStream = self.engine.streamRequest(urlRequest)

            responseCallbacks.receiveResponseHeaders([:])

            for try await chunk in dataStream {
                try Task.checkCancellation()
                responseCallbacks.receiveResponseData(chunk)
            }

            responseCallbacks.receiveResponseMetrics(HTTPMetrics(taskMetrics: nil))
            responseCallbacks.receiveClose(.ok, [:], nil)
        } catch {
            if error is CancellationError {
                responseCallbacks.receiveClose(.canceled, [:], nil)
            } else {
                responseCallbacks.receiveClose(
                    .unknown,
                    [:],
                    self.mapToConnectError(error)
                )
            }
        }
    }

    // MARK: - Private Helpers

    private func buildURLRequest(from request: HTTPRequest<Data?>) async throws -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue

        for (name, values) in request.headers {
            for value in values {
                urlRequest.addValue(value, forHTTPHeaderField: name)
            }
        }

        if let body = request.message {
            urlRequest.httpBody = body
        }

        // Apply interceptor chain if present (handles token, tracing, etc.)
        if let chain {
            var config = RequestConfig(
                url: request.url.absoluteString,
                method: HTTPMethod(rawValue: request.method.rawValue) ?? .get,
                headers: urlRequest.allHTTPHeaderFields ?? [:]
            )
            config = try await chain.applyRequest(config)

            // Merge chain-modified headers back into the URLRequest.
            for (key, value) in config.headers {
                urlRequest.setValue(value, forHTTPHeaderField: key)
            }
        }

        return urlRequest
    }

    private func extractHeaders(from response: HTTPURLResponse?) -> Headers {
        guard let response else { return [:] }
        var headers: Headers = [:]
        for (key, value) in response.allHeaderFields {
            let name = "\(key)".lowercased()
            headers[name] = ["\(value)"]
        }
        return headers
    }

    private func mapHTTPStatusToCode(_ statusCode: Int) -> Code {
        switch statusCode {
        case 200..<300:
            return .ok
        case 400:
            return .invalidArgument
        case 401:
            return .unauthenticated
        case 403:
            return .permissionDenied
        case 404:
            return .notFound
        case 408:
            return .deadlineExceeded
        case 409:
            return .aborted
        case 429:
            return .resourceExhausted
        case 499:
            return .canceled
        case 500:
            return .internalError
        case 501:
            return .unimplemented
        case 503:
            return .unavailable
        default:
            if (400..<500).contains(statusCode) {
                return .failedPrecondition
            }
            return .unknown
        }
    }

    private func mapToConnectError(_ error: Error) -> ConnectError {
        if let connectError = error as? ConnectError {
            return connectError
        }

        if let requestError = error as? RequestError {
            switch requestError.code {
            case .abort:
                return ConnectError(code: .canceled, message: requestError.message)
            case .timeout:
                return ConnectError(code: .deadlineExceeded, message: requestError.message)
            case .network:
                return ConnectError(code: .unavailable, message: requestError.message)
            case .auth:
                return ConnectError(code: .unauthenticated, message: requestError.message)
            case .http:
                let code = mapHTTPStatusToCode(requestError.status ?? 0)
                return ConnectError(code: code, message: requestError.message)
            case .parse:
                return ConnectError(code: .internalError, message: requestError.message)
            case .circuitOpen:
                return ConnectError(code: .unavailable, message: requestError.message)
            case .unknown:
                return ConnectError(code: .unknown, message: requestError.message)
            }
        }

        return ConnectError(code: .unknown, message: error.localizedDescription)
    }
}

// MARK: - Legacy Auth Bridge Interceptor

/// Internal interceptor that applies the legacy `AuthenticationStrategy`
/// asynchronously during `onRequest`. Used only by the deprecated
/// `ConnectTransport.init(engine:tokenStorage:tokenRefresher:authStrategy:)`.
private struct LegacyAuthBridgeInterceptor: RequestInterceptor, @unchecked Sendable {
    let tokenStorage: TokenStorage
    let authStrategy: AuthenticationStrategy

    func onRequest(_ config: RequestConfig) async throws -> RequestConfig {
        // Build a temporary URLRequest to apply the strategy, then
        // extract the added headers back into the RequestConfig.
        guard let url = URL(string: config.url) else { return config }
        var urlRequest = URLRequest(url: url)
        for (key, value) in config.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let context = AuthenticationContext(tokenStorage: tokenStorage)
        let authed = try await authStrategy.apply(to: urlRequest, context: context)

        var updated = config
        if let allHeaders = authed.allHTTPHeaderFields {
            for (key, value) in allHeaders {
                updated.headers[key] = value
            }
        }
        return updated
    }
}

// MARK: - Stream State

/// Thread-safe state for deferred stream execution.
/// connect-swift calls sendData() then sendClose() — we buffer the body
/// and start the HTTP request only on sendClose().
private final class StreamState: @unchecked Sendable {
    private var bodyParts: [Data] = []
    private var task: Task<Void, Never>?
    private let lock = NSLock()

    func appendBody(_ data: Data) {
        lock.lock()
        bodyParts.append(data)
        lock.unlock()
    }

    func start(
        transport: ConnectTransport,
        request: HTTPRequest<Data?>,
        responseCallbacks: ResponseCallbacks
    ) {
        lock.lock()
        let body = bodyParts.reduce(Data()) { $0 + $1 }
        task = Task {
            await transport.executeStream(
                request: request,
                body: body,
                responseCallbacks: responseCallbacks
            )
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        task?.cancel()
        lock.unlock()
    }
}
