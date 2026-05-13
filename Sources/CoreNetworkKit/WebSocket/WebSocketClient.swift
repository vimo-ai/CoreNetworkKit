import Foundation
import MLoggerKit

/// Native WebSocket client using URLSessionWebSocketTask.
///
/// Uses JSON envelope wire format: `{"event":"name","data":{...}}`
///
/// Usage:
/// ```swift
/// let config = WebSocketConfiguration.withToken("xxx", url: serverURL, path: "/chat")
/// let client = WebSocketClient(configuration: config)
///
/// client.on("session:started") { (payload: SessionStartedPayload) in
///     print("Started: \(payload)")
/// }
///
/// client.connect()
/// client.emit("session:start", data: ["characterId": 42])
/// ```
public final class WebSocketClient: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var connectionState: WebSocketConnectionState = .disconnected
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var lastError: Error?

    // MARK: - Private Properties

    private let configuration: WebSocketConfiguration
    private let logger = LoggerFactory.network
    private let decoder = JSONDecoder()

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var sessionDelegateProxy: SessionDelegateProxy?
    private var reconnectAttempt = 0
    private var isIntentionalDisconnect = false

    private struct TokenizedHandler {
        let token: EventHandlerToken
        let handler: (Any) -> Void
    }

    private var tokenizedHandlers: [String: [TokenizedHandler]] = [:]

    // MARK: - Initialization

    public init(configuration: WebSocketConfiguration) {
        self.configuration = configuration
        setupDecoder()
    }

    public convenience init(url: URL, token: String? = nil, path: String? = nil) {
        let config = WebSocketConfiguration(url: url, token: token, authMethod: .queryParam(), path: path)
        self.init(configuration: config)
    }

    public convenience init(url: URL, bearerToken: String, path: String? = nil) {
        let config = WebSocketConfiguration.withBearerToken(bearerToken, url: url, path: path)
        self.init(configuration: config)
    }

    private func setupDecoder() {
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Connection Management

    public func connect() {
        guard task == nil else {
            logger.warning("[WebSocket] Already connected or connecting", tag: "ws")
            return
        }

        isIntentionalDisconnect = false
        let request = buildURLRequest()

        let delegateProxy = SessionDelegateProxy(client: self)
        self.sessionDelegateProxy = delegateProxy
        let urlSession = URLSession(configuration: .default, delegate: delegateProxy, delegateQueue: nil)
        self.session = urlSession

        let wsTask = urlSession.webSocketTask(with: request)
        self.task = wsTask

        DispatchQueue.main.async { self.connectionState = .connecting }
        wsTask.resume()
        receiveLoop()

        logger.info("[WebSocket] Connecting to \(request.url?.absoluteString ?? "?")", tag: "ws")
    }

    public func disconnect() {
        isIntentionalDisconnect = true
        task?.cancel(with: .normalClosure, reason: nil)
        cleanup()
        logger.info("[WebSocket] Disconnected", tag: "ws")
    }

    public func reconnect(withToken token: String) {
        disconnect()

        let newConfig = WebSocketConfiguration(
            url: configuration.url,
            token: token,
            authMethod: configuration.authMethod,
            enableLogging: configuration.enableLogging,
            reconnects: configuration.reconnects,
            reconnectAttempts: configuration.reconnectAttempts,
            reconnectWait: configuration.reconnectWait,
            extraParams: configuration.extraParams,
            extraHeaders: configuration.extraHeaders,
            certificateProvider: configuration.certificateProvider,
            sessionDelegate: configuration.sessionDelegate,
            secure: configuration.secure,
            selfSigned: configuration.selfSigned,
            path: configuration.path
        )

        let newClient = WebSocketClient(configuration: newConfig)
        newClient.tokenizedHandlers = self.tokenizedHandlers
        newClient.connect()

        logger.info("[WebSocket] Reconnecting with new token", tag: "ws")
    }

    // MARK: - Event Handling

    @discardableResult
    public func on<T: Decodable>(_ event: String, handler: @escaping (T) -> Void) -> EventHandlerToken {
        let token = EventHandlerToken(event: event)

        let wrappedHandler: (Any) -> Void = { [weak self] data in
            guard let self = self else { return }
            if let decoded = self.decode(T.self, from: data) {
                handler(decoded)
            }
        }

        let tokenizedHandler = TokenizedHandler(token: token, handler: wrappedHandler)
        if tokenizedHandlers[event] == nil {
            tokenizedHandlers[event] = []
        }
        tokenizedHandlers[event]?.append(tokenizedHandler)

        return token
    }

    @discardableResult
    public func onRaw(_ event: String, handler: @escaping ([Any]) -> Void) -> EventHandlerToken {
        let token = EventHandlerToken(event: event)

        let wrappedHandler: (Any) -> Void = { data in
            if let arrayData = data as? [Any] {
                handler(arrayData)
            } else {
                handler([data])
            }
        }

        let tokenizedHandler = TokenizedHandler(token: token, handler: wrappedHandler)
        if tokenizedHandlers[event] == nil {
            tokenizedHandlers[event] = []
        }
        tokenizedHandlers[event]?.append(tokenizedHandler)

        return token
    }

    public func off(token: EventHandlerToken) {
        tokenizedHandlers[token.event]?.removeAll { $0.token.id == token.id }
        if tokenizedHandlers[token.event]?.isEmpty == true {
            tokenizedHandlers[token.event] = nil
        }
    }

    public func off(_ event: String) {
        tokenizedHandlers[event] = nil
    }

    // MARK: - Emit

    public func emit<T: Encodable>(_ event: String, data: T) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emit: not connected", tag: "ws")
            return
        }

        do {
            let jsonData = try JSONEncoder().encode(data)
            let dataObj = try JSONSerialization.jsonObject(with: jsonData)
            let envelope: [String: Any] = ["event": event, "data": dataObj]
            let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
            let text = String(data: envelopeData, encoding: .utf8)!

            task?.send(.string(text)) { [weak self] error in
                if let error { self?.logger.error("[WebSocket] Send error: \(error)", tag: "ws") }
            }
            logger.debug("[WebSocket] Emit: \(event)", tag: "ws")
        } catch {
            logger.error("[WebSocket] Encode error: \(error)", tag: "ws")
        }
    }

    public func emit(_ event: String, data: [String: Any]) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emit: not connected", tag: "ws")
            return
        }

        do {
            let envelope: [String: Any] = ["event": event, "data": data]
            let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
            let text = String(data: envelopeData, encoding: .utf8)!

            task?.send(.string(text)) { [weak self] error in
                if let error { self?.logger.error("[WebSocket] Send error: \(error)", tag: "ws") }
            }
            logger.debug("[WebSocket] Emit: \(event)", tag: "ws")
        } catch {
            logger.error("[WebSocket] Encode error: \(error)", tag: "ws")
        }
    }

    public func emit(_ event: String) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emit: not connected", tag: "ws")
            return
        }

        do {
            let envelope: [String: Any] = ["event": event, "data": [:] as [String: Any]]
            let envelopeData = try JSONSerialization.data(withJSONObject: envelope)
            let text = String(data: envelopeData, encoding: .utf8)!

            task?.send(.string(text)) { [weak self] error in
                if let error { self?.logger.error("[WebSocket] Send error: \(error)", tag: "ws") }
            }
            logger.debug("[WebSocket] Emit: \(event)", tag: "ws")
        } catch {
            logger.error("[WebSocket] Encode error: \(error)", tag: "ws")
        }
    }

    // MARK: - Internal — URL Construction

    func buildURLRequest() -> URLRequest {
        var components = URLComponents()
        let baseURL = configuration.url

        components.scheme = configuration.secure ? "wss" : (baseURL.scheme == "https" ? "wss" : "ws")
        components.host = baseURL.host
        components.port = baseURL.port

        var basePath = baseURL.path
        if let path = configuration.path {
            basePath = basePath.hasSuffix("/")
                ? basePath + String(path.drop(while: { $0 == "/" }))
                : basePath + path
        }
        components.path = basePath

        var queryItems: [URLQueryItem] = []

        if let token = configuration.token {
            switch configuration.authMethod {
            case .queryParam(let key):
                queryItems.append(URLQueryItem(name: key, value: token))
            case .bearerHeader, .customHeader, .none:
                break
            }
        }

        if let extraParams = configuration.extraParams {
            for (key, value) in extraParams {
                queryItems.append(URLQueryItem(name: key, value: "\(value)"))
            }
        }

        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        var request = URLRequest(url: components.url!)

        if let token = configuration.token {
            switch configuration.authMethod {
            case .bearerHeader:
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            case .customHeader(let key):
                request.setValue(token, forHTTPHeaderField: key)
            case .queryParam, .none:
                break
            }
        }

        if let extraHeaders = configuration.extraHeaders {
            for (key, value) in extraHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        return request
    }

    // MARK: - Private — Receive Loop

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveLoop()
            case .failure(let error):
                if !self.isIntentionalDisconnect {
                    self.handleDisconnect(error: error)
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let jsonData = text.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  let event = envelope["event"] as? String else { return }

            let payload = envelope["data"]
            dispatchEvent(event, data: payload as Any)

        case .data(let data):
            guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = envelope["event"] as? String else { return }

            let payload = envelope["data"]
            dispatchEvent(event, data: payload as Any)

        @unknown default:
            break
        }
    }

    func dispatchEvent(_ event: String, data: Any) {
        guard let handlers = tokenizedHandlers[event] else { return }
        for handler in handlers {
            handler.handler(data)
        }
    }

    // MARK: - Private — Connection Lifecycle

    fileprivate func handleConnected() {
        reconnectAttempt = 0
        DispatchQueue.main.async {
            self.connectionState = .connected
            self.isConnected = true
            self.lastError = nil
        }
        logger.info("[WebSocket] Connected", tag: "ws")
    }

    private func handleDisconnect(error: Error?) {
        DispatchQueue.main.async {
            self.isConnected = false
            if let error {
                self.lastError = error
            }
        }
        logger.info("[WebSocket] Disconnected: \(error?.localizedDescription ?? "clean")", tag: "ws")

        task = nil
        session?.invalidateAndCancel()
        session = nil

        if !isIntentionalDisconnect && configuration.reconnects {
            attemptReconnect()
        } else {
            DispatchQueue.main.async { self.connectionState = .disconnected }
        }
    }

    fileprivate func handleError(_ error: Error) {
        DispatchQueue.main.async { self.lastError = error }
        logger.error("[WebSocket] Error: \(error)", tag: "ws")
    }

    private func attemptReconnect() {
        guard reconnectAttempt < configuration.reconnectAttempts else {
            DispatchQueue.main.async { self.connectionState = .disconnected }
            logger.warning("[WebSocket] Max reconnect attempts reached", tag: "ws")
            return
        }

        DispatchQueue.main.async { self.connectionState = .reconnecting }
        reconnectAttempt += 1
        let delay = configuration.reconnectWait * pow(1.5, Double(reconnectAttempt - 1))
        logger.debug("[WebSocket] Reconnect attempt \(reconnectAttempt) in \(delay)s", tag: "ws")

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self, !self.isIntentionalDisconnect else { return }
            self.connect()
        }
    }

    private func cleanup() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionDelegateProxy = nil
        DispatchQueue.main.async {
            self.connectionState = .disconnected
            self.isConnected = false
        }
    }

    // MARK: - Private — Decode

    private func decode<T: Decodable>(_ type: T.Type, from data: Any) -> T? {
        do {
            let jsonData: Data
            if let dict = data as? [String: Any] {
                jsonData = try JSONSerialization.data(withJSONObject: dict)
            } else if let array = data as? [Any] {
                jsonData = try JSONSerialization.data(withJSONObject: array)
            } else if let string = data as? String, let strData = string.data(using: .utf8) {
                jsonData = strData
            } else {
                return nil
            }
            return try decoder.decode(T.self, from: jsonData)
        } catch {
            logger.warning("[WebSocket] Decode failed for \(type): \(error)", tag: "ws-decode")
            return nil
        }
    }
}

// MARK: - URLSession Delegate

private final class SessionDelegateProxy: NSObject, URLSessionWebSocketDelegate {
    private weak var client: WebSocketClient?

    init(client: WebSocketClient) {
        self.client = client
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        client?.handleConnected()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        // Handled by receive loop failure
    }
}

// MARK: - WebSocket Errors

public enum WebSocketError: Error, LocalizedError {
    case connectionError(String)
    case notConnected
    case encodingFailed
    case decodingFailed
    case timeout
    case authenticationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .connectionError(let message):
            return "Connection error: \(message)"
        case .notConnected:
            return "Not connected"
        case .encodingFailed:
            return "Failed to encode data"
        case .decodingFailed:
            return "Failed to decode data"
        case .timeout:
            return "Request timed out"
        case .authenticationFailed(let message):
            return "Authentication failed: \(message)"
        }
    }
}

// MARK: - Event Handler Token

public struct EventHandlerToken: Hashable {
    public let id: UUID
    public let event: String

    public init(event: String) {
        self.id = UUID()
        self.event = event
    }
}
