import Foundation
import Connect
import MLoggerKit

// MARK: - Transport Failure Classification

/// Classifies whether an error is a transport-level failure (warranting fallback)
/// or a business-level error (which should be surfaced as-is).
///
/// Transport-level failures indicate infrastructure problems between the client
/// and the server — the kind of failures that a different transport (WebSocket)
/// might circumvent. Business errors (4xx/5xx with valid HTTP framing) indicate
/// that the server received the request and responded with an application-level
/// error, so switching transports would not help.
enum TransportFailureClassifier {

    /// Returns `true` if the error indicates a transport-level problem that
    /// should trigger fallback from ConnectRPC to WebSocket.
    ///
    /// Criteria:
    /// - Connection refused / reset
    /// - DNS resolution failure
    /// - TLS handshake failure
    /// - Connection-level timeout (not request-level)
    /// - Response with garbled content-type (middlebox interference)
    /// - Network unreachable / no route to host
    static func isTransportFailure(_ error: Error) -> Bool {
        // NetworkError cases that represent transport-level issues
        if let networkError = error as? NetworkError {
            switch networkError {
            case .noNetwork:
                return true
            case .timeout:
                // Timeout is ambiguous, but connection timeouts generally
                // indicate transport-level issues
                return true
            case .serverError, .decodingFailed, .authenticationFailed,
                 .retryExhausted, .invalidURL, .cancelled:
                return false
            case .unknown(let underlying):
                return isTransportLevelURLError(underlying)
            }
        }

        // Check for raw URLError (may come from the engine directly)
        if let urlError = error as? URLError {
            return isTransportLevelURLErrorCode(urlError.code)
        }

        // Unwrap NSError for POSIX / system-level transport failures
        let nsError = error as NSError

        // POSIX-level connection errors
        if nsError.domain == NSPOSIXErrorDomain {
            // ECONNREFUSED (61), ECONNRESET (54), ENETUNREACH (51),
            // EHOSTUNREACH (65), ETIMEDOUT (60)
            let transportCodes: Set<Int> = [54, 51, 60, 61, 65]
            return transportCodes.contains(nsError.code)
        }

        // NSURLErrorDomain errors
        if nsError.domain == NSURLErrorDomain {
            let code = URLError.Code(rawValue: nsError.code)
            return isTransportLevelURLErrorCode(code)
        }

        // Security framework errors (TLS handshake failures)
        // errSSL* codes live in the NSOSStatusErrorDomain
        if nsError.domain == NSOSStatusErrorDomain {
            // errSSLHandshakeFail = -9806, errSSLPeerHandshakeFail = -9824,
            // errSSLClosedAbort = -9816, errSSLProtocol = -9800
            let sslTransportCodes: Set<Int> = [-9800, -9806, -9816, -9824]
            return sslTransportCodes.contains(nsError.code)
        }

        return false
    }

    /// Check whether a response's content-type indicates middlebox interference.
    ///
    /// When a transparent proxy or captive portal intercepts HTTPS traffic,
    /// it often returns an HTML page with `text/html` content-type instead of
    /// the expected `application/proto`, `application/grpc`, or
    /// `application/connect+proto` content-type.
    ///
    /// - Parameters:
    ///   - response: The HTTP response to inspect.
    ///   - expectedContentTypes: Content types that are valid for the transport.
    /// - Returns: `true` if the content-type looks like middlebox interference.
    static func hasGarbledContentType(
        _ response: HTTPURLResponse?,
        expectedContentTypes: Set<String> = [
            "application/proto",
            "application/grpc",
            "application/grpc+proto",
            "application/connect+proto",
            "application/json",
            "application/grpc-web",
            "application/grpc-web+proto"
        ]
    ) -> Bool {
        guard let response else { return false }
        guard let contentType = response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased()
            .components(separatedBy: ";")
            .first?
            .trimmingCharacters(in: .whitespaces) else {
            return false
        }

        // If the content-type is text/html on a non-browser API call,
        // it is almost certainly a captive portal or proxy injection.
        if contentType == "text/html" {
            return true
        }

        // If we got a 200 but the content-type is not in the expected set,
        // treat it as garbled (middlebox rewrote the response).
        if (200..<300).contains(response.statusCode) &&
           !expectedContentTypes.contains(contentType) {
            return true
        }

        return false
    }

    // MARK: - Private Helpers

    private static func isTransportLevelURLError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return isTransportLevelURLErrorCode(urlError.code)
        }
        // Recurse into NSError underlying errors
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isTransportFailure(underlying)
        }
        return false
    }

    private static func isTransportLevelURLErrorCode(_ code: URLError.Code) -> Bool {
        switch code {
        // DNS
        case .cannotFindHost, .dnsLookupFailed:
            return true
        // Connection
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return true
        // TLS
        case .serverCertificateHasBadDate, .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
             .clientCertificateRejected, .clientCertificateRequired,
             .secureConnectionFailed:
            return true
        // Timeout (connection-level)
        case .timedOut:
            return true
        // HTTP/2 protocol errors
        case .httpTooManyRedirects, .resourceUnavailable:
            return true
        default:
            return false
        }
    }
}

// MARK: - Monitoring Network Engine

/// A `NetworkEngine` wrapper that intercepts errors before they reach
/// `ConnectTransport`, allowing the `TransportNegotiator` to classify raw
/// (unwrapped) errors.
///
/// This is necessary because `ConnectTransport.mapToConnectError()` discards
/// the original error type when creating `ConnectError`. By monitoring at the
/// engine level, we can classify errors accurately.
final class MonitoringNetworkEngine: NetworkEngine, @unchecked Sendable {

    private let wrapped: NetworkEngine

    /// Mutable weak reference to the negotiator. Set after construction
    /// to break the circular reference during `TransportNegotiator.init`.
    weak var negotiator: TransportNegotiator?

    init(wrapping engine: NetworkEngine) {
        self.wrapped = engine
    }

    func performRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await wrapped.performRequest(request)
            negotiator?.handleEngineResponse(response)
            return (data, response)
        } catch {
            negotiator?.handleEngineError(error)
            throw error
        }
    }

    func streamRequest(_ request: URLRequest) -> AsyncThrowingStream<Data, Error> {
        let upstream = wrapped.streamRequest(request)
        weak var negotiator = self.negotiator

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    negotiator?.handleEngineError(error)
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Transport Negotiator

/// Wraps a ConnectRPC transport with failure-based degradation to WebSocket.
///
/// The negotiator starts every session using ConnectRPC (`ConnectTransport`).
/// If a request fails with a **transport-level** error — network unreachable,
/// TLS handshake failure, DNS error, connection timeout, or garbled content-type
/// (indicating middlebox interference) — the negotiator marks ConnectRPC as
/// degraded and signals that the caller should switch to WebSocket for the
/// remainder of the session.
///
/// **Business errors** (HTTP 4xx/5xx with valid framing) do **not** trigger
/// fallback, because they indicate that the server received and processed the
/// request; switching transports would not help.
///
/// The negotiator monitors errors at the `NetworkEngine` level (before
/// `ConnectTransport` wraps them into `ConnectError`), ensuring accurate
/// classification of the original error types.
///
/// Thread safety is guaranteed via `NSLock`.
///
/// Usage:
/// ```swift
/// let negotiator = TransportNegotiator(
///     engine: alamofireEngine,
///     tokenStorage: myTokenStorage,
///     tokenRefresher: myTokenRefresher,
///     onFallback: { error in print("Switched to WebSocket: \(error)") }
/// )
///
/// // Use as drop-in HTTPClientInterface for ProtocolClient
/// let client = ProtocolClient(httpClient: negotiator, config: config)
///
/// // Query transport state
/// if negotiator.isUsingFallback {
///     // route through WebSocket instead
/// }
///
/// // Reset for a new session
/// negotiator.reset()
/// ```
public final class TransportNegotiator: HTTPClientInterface, @unchecked Sendable {

    // MARK: - Types

    /// The current transport state.
    public enum TransportState: Equatable {
        /// Using ConnectRPC as the primary transport.
        case connectRPC
        /// ConnectRPC failed; using WebSocket fallback.
        case webSocketFallback
    }

    /// Called when the negotiator switches from ConnectRPC to WebSocket fallback.
    /// The associated error is the transport failure that triggered the switch.
    public typealias FallbackHandler = @Sendable (Error) -> Void

    // MARK: - Properties

    private let connectTransport: ConnectTransport
    private let onFallback: FallbackHandler?
    private let logger = LoggerFactory.network

    private let lock = NSLock()
    private var _state: TransportState = .connectRPC

    /// The current transport state (thread-safe read).
    public var state: TransportState {
        lock.lock()
        defer { lock.unlock() }
        return _state
    }

    /// Whether the negotiator has fallen back to WebSocket.
    public var isUsingFallback: Bool {
        return state == .webSocketFallback
    }

    // MARK: - Initialization

    /// Create a transport negotiator that monitors a ConnectRPC transport for
    /// transport-level failures.
    ///
    /// The negotiator wraps the provided `engine` in a monitoring layer that
    /// intercepts errors before `ConnectTransport` maps them. This ensures
    /// accurate failure classification.
    ///
    /// - Parameters:
    ///   - engine: The underlying network engine (e.g. `AlamofireEngine`).
    ///   - chain: Optional interceptor chain shared with `NetworkClientV2`.
    ///            When provided, `ConnectTransport` delegates auth/token/tracing
    ///            to the chain instead of handling them internally.
    ///   - onFallback: Optional callback invoked when fallback is triggered.
    ///                 Called at most once per session (until `reset()` is called).
    public init(
        engine: NetworkEngine,
        chain: InterceptorChain? = nil,
        onFallback: FallbackHandler? = nil
    ) {
        self.onFallback = onFallback

        // Wrap the engine to intercept raw errors before ConnectTransport
        // maps them to ConnectError (which loses the original error type).
        let monitoringEngine = MonitoringNetworkEngine(wrapping: engine)

        self.connectTransport = ConnectTransport(
            engine: monitoringEngine,
            chain: chain
        )

        // Now that self is fully initialized, set the back-reference so the
        // monitoring engine can report errors and responses.
        monitoringEngine.negotiator = self
    }

    /// Legacy initializer preserved for backward compatibility.
    @available(*, deprecated, message: "Use init(engine:chain:onFallback:) instead")
    public convenience init(
        engine: NetworkEngine,
        tokenStorage: TokenStorage,
        tokenRefresher: TokenRefresher? = nil,
        authStrategy: AuthenticationStrategy = BearerTokenAuthenticationStrategy(),
        onFallback: FallbackHandler? = nil
    ) {
        let compatChain = InterceptorChain()
        compatChain.use(LegacyAuthBridgeForNegotiator(
            tokenStorage: tokenStorage,
            authStrategy: authStrategy
        ))
        self.init(engine: engine, chain: compatChain, onFallback: onFallback)
    }

    // MARK: - Session Management

    /// Reset the negotiator to use ConnectRPC again.
    ///
    /// Call this at the start of a new session to give ConnectRPC another chance.
    /// This is safe to call from any thread.
    public func reset() {
        lock.lock()
        let previousState = _state
        _state = .connectRPC
        lock.unlock()

        if previousState == .webSocketFallback {
            logger.info(
                "[TransportNegotiator] Reset to ConnectRPC for new session",
                tag: "transport"
            )
        }
    }

    // MARK: - HTTPClientInterface

    @discardableResult
    public func unary(
        request: HTTPRequest<Data?>,
        onMetrics: @escaping @Sendable (HTTPMetrics) -> Void,
        onResponse: @escaping @Sendable (HTTPResponse) -> Void
    ) -> Cancelable {
        if isUsingFallback {
            logger.debug(
                "[TransportNegotiator] Already in fallback mode, forwarding unary",
                tag: "transport"
            )
        }

        return connectTransport.unary(
            request: request,
            onMetrics: onMetrics,
            onResponse: onResponse
        )
    }

    public func stream(
        request: HTTPRequest<Data?>,
        responseCallbacks: ResponseCallbacks
    ) -> RequestCallbacks<Data> {
        if isUsingFallback {
            logger.debug(
                "[TransportNegotiator] Already in fallback mode, forwarding stream",
                tag: "transport"
            )
        }

        return connectTransport.stream(
            request: request,
            responseCallbacks: responseCallbacks
        )
    }

    // MARK: - Internal — Engine Monitoring Callbacks

    /// Called by the `MonitoringNetworkEngine` when a request throws an error.
    /// This receives the raw error before `ConnectTransport` wraps it.
    func handleEngineError(_ error: Error) {
        guard TransportFailureClassifier.isTransportFailure(error) else {
            return
        }
        triggerFallback(dueTo: error)
    }

    /// Called by the `MonitoringNetworkEngine` when a request succeeds.
    /// Checks for garbled content-type (middlebox interference).
    func handleEngineResponse(_ response: URLResponse) {
        let httpResponse = response as? HTTPURLResponse
        if TransportFailureClassifier.hasGarbledContentType(httpResponse) {
            let description = httpResponse.map {
                "Garbled content-type '\($0.value(forHTTPHeaderField: "Content-Type") ?? "nil")' " +
                "on status \($0.statusCode)"
            } ?? "Unknown response"
            triggerFallback(
                dueTo: NSError(
                    domain: "TransportNegotiator",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: description]
                )
            )
        }
    }

    // MARK: - Private — State Transitions

    /// Mark ConnectRPC as degraded and switch to WebSocket.
    private func triggerFallback(dueTo error: Error) {
        lock.lock()
        let alreadyDegraded = _state == .webSocketFallback
        _state = .webSocketFallback
        lock.unlock()

        guard !alreadyDegraded else { return }

        logger.warning(
            "[TransportNegotiator] Transport failure detected, switching to WebSocket fallback. Error: \(error)",
            tag: "transport"
        )

        onFallback?(error)
    }
}

// MARK: - Legacy Auth Bridge for Negotiator

/// Internal interceptor for the deprecated `TransportNegotiator` initializer
/// that accepts `tokenStorage` / `authStrategy` directly.
private struct LegacyAuthBridgeForNegotiator: RequestInterceptor, @unchecked Sendable {
    let tokenStorage: TokenStorage
    let authStrategy: AuthenticationStrategy

    func onRequest(_ config: RequestConfig) async throws -> RequestConfig {
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
