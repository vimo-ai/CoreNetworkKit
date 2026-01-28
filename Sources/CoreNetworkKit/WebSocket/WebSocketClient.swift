import Foundation
import SocketIO
import MLoggerKit

/// Socket.IO WebSocket 客户端
///
/// 封装 Socket.IO 客户端，提供类型安全的事件监听和消息发送。
///
/// 使用示例：
/// ```swift
/// let config = WebSocketConfiguration.withToken("xxx", url: serverURL)
/// let client = WebSocketClient(configuration: config)
///
/// client.on("message:new") { (message: ChatMessage) in
///     print("New message: \(message)")
/// }
///
/// client.connect()
/// client.emit("send", data: ["text": "Hello"])
/// ```
public final class WebSocketClient: ObservableObject {

    // MARK: - Published Properties

    @Published public private(set) var connectionState: WebSocketConnectionState = .disconnected
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var lastError: Error?

    // MARK: - Private Properties

    private var manager: SocketManager?
    private var socket: SocketIOClient?
    private let configuration: WebSocketConfiguration
    private let logger = LoggerFactory.network
    private let decoder = JSONDecoder()

    /// 带 token 的事件处理器
    private struct TokenizedHandler {
        let token: EventHandlerToken
        let handler: (Any) -> Void
    }

    /// 事件处理器存储（使用 TokenizedHandler）
    private var tokenizedHandlers: [String: [TokenizedHandler]] = [:]

    /// 旧 API 事件处理器存储（兼容）
    private var eventHandlers: [String: [(Any) -> Void]] = [:]

    /// 已加入的房间
    private var joinedRooms: Set<String> = []

    // MARK: - Initialization

    public init(configuration: WebSocketConfiguration) {
        self.configuration = configuration
        setupDecoder()
    }

    /// 便捷初始化：使用 URL 和 Token (query 参数方式)
    public convenience init(url: URL, token: String? = nil) {
        let config = WebSocketConfiguration(url: url, token: token, authMethod: .queryParam())
        self.init(configuration: config)
    }

    /// 便捷初始化：使用 URL 和 Bearer Token (Header 方式)
    public convenience init(url: URL, bearerToken: String) {
        let config = WebSocketConfiguration.withBearerToken(bearerToken, url: url)
        self.init(configuration: config)
    }

    private func setupDecoder() {
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Connection Management

    /// 建立连接
    public func connect() {
        guard socket == nil else {
            logger.warning("[WebSocket] Already connected or connecting", tag: "ws")
            return
        }

        setupSocket()
        connectionState = .connecting
        socket?.connect()
        logger.info("[WebSocket] Connecting to \(configuration.url)", tag: "ws")
    }

    /// 断开连接
    public func disconnect() {
        socket?.disconnect()
        cleanup()
        logger.info("[WebSocket] Disconnected", tag: "ws")
    }

    /// 使用新 Token 重连（保持原有认证方式和 mTLS 设置）
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
            selfSigned: configuration.selfSigned
        )

        setupSocket(with: newConfig)
        socket?.connect()
        logger.info("[WebSocket] Reconnecting with new token", tag: "ws")
    }

    // MARK: - Room Management

    /// 加入房间
    public func join(room: String, params: [String: Any] = [:]) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot join room: not connected", tag: "ws")
            return
        }

        guard !joinedRooms.contains(room) else {
            logger.debug("[WebSocket] Already in room: \(room)", tag: "ws")
            return
        }

        var payload = params
        payload["room"] = room

        socket?.emit("join", payload)
        joinedRooms.insert(room)
        logger.debug("[WebSocket] Joined room: \(room)", tag: "ws")
    }

    /// 离开房间
    public func leave(room: String) {
        guard isConnected else { return }

        socket?.emit("leave", ["room": room])
        joinedRooms.remove(room)
        logger.debug("[WebSocket] Left room: \(room)", tag: "ws")
    }

    // MARK: - Event Handling

    /// 监听事件（类型安全，返回 Token）
    /// - Parameters:
    ///   - event: 事件名称
    ///   - handler: 事件处理器，接收解码后的数据
    /// - Returns: EventHandlerToken 用于后续移除监听
    @discardableResult
    public func on<T: Decodable>(_ event: String, handler: @escaping (T) -> Void) -> EventHandlerToken {
        let token = EventHandlerToken(event: event)

        // 存储包装后的处理器
        let wrappedHandler: (Any) -> Void = { [weak self] data in
            guard let self = self else { return }
            if let decoded = self.decode(T.self, from: data) {
                handler(decoded)
            }
        }

        let tokenizedHandler = TokenizedHandler(token: token, handler: wrappedHandler)

        if tokenizedHandlers[event] == nil {
            tokenizedHandlers[event] = []
            // 首次注册该事件时，设置 Socket.IO 监听
            socket?.on(event) { [weak self] data, _ in
                self?.handleEvent(event, data: data)
            }
        }

        tokenizedHandlers[event]?.append(tokenizedHandler)

        return token
    }

    /// 监听事件（原始数据，返回 Token）
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
            socket?.on(event) { [weak self] data, _ in
                self?.handleEvent(event, data: data)
            }
        }

        tokenizedHandlers[event]?.append(tokenizedHandler)

        return token
    }

    /// 移除特定的事件监听（按 Token）
    public func off(token: EventHandlerToken) {
        tokenizedHandlers[token.event]?.removeAll { $0.token.id == token.id }

        // 如果该事件没有任何监听器了，清理 Socket.IO 监听
        if tokenizedHandlers[token.event]?.isEmpty == true && eventHandlers[token.event]?.isEmpty != false {
            tokenizedHandlers[token.event] = nil
            socket?.off(token.event)
        }
    }

    /// 取消监听事件（移除该事件的所有监听器）
    public func off(_ event: String) {
        tokenizedHandlers[event] = nil
        eventHandlers[event] = nil
        socket?.off(event)
    }

    // MARK: - Emit

    /// 发送事件（Encodable 数据）
    public func emit<T: Encodable>(_ event: String, data: T) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emit: not connected", tag: "ws")
            return
        }

        do {
            let jsonData = try JSONEncoder().encode(data)
            if let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                socket?.emit(event, dict)
                logger.debug("[WebSocket] Emit: \(event)", tag: "ws")
            }
        } catch {
            logger.error("[WebSocket] Encode error: \(error)", tag: "ws")
        }
    }

    /// 发送事件（字典数据）
    public func emit(_ event: String, data: [String: Any]) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emit: not connected", tag: "ws")
            return
        }

        socket?.emit(event, data)
        logger.debug("[WebSocket] Emit: \(event)", tag: "ws")
    }

    /// 发送事件（无数据）
    public func emit(_ event: String) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emit: not connected", tag: "ws")
            return
        }

        socket?.emit(event)
        logger.debug("[WebSocket] Emit: \(event)", tag: "ws")
    }

    // MARK: - Emit With Ack

    /// 发送事件并等待 Ack 响应（async/await 版本）
    /// - Parameters:
    ///   - event: 事件名称
    ///   - data: 要发送的数据（字典）
    ///   - timeout: 超时时间（秒），默认 10 秒
    /// - Returns: 服务端返回的响应数据
    /// - Throws: WebSocketError.notConnected, WebSocketError.timeout
    public func emitWithAck(_ event: String, data: [String: Any], timeout: TimeInterval = 10) async throws -> [String: Any] {
        guard isConnected else {
            throw WebSocketError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            socket?.emitWithAck(event, data).timingOut(after: timeout) { [weak self] responseData in
                // 检查是否超时（Socket.IO 返回 "NO ACK"）
                if let status = responseData.first as? String, status == "NO ACK" {
                    continuation.resume(throwing: WebSocketError.timeout)
                    return
                }

                // 解析响应
                if let response = responseData.first as? [String: Any] {
                    continuation.resume(returning: response)
                } else {
                    // 返回空字典表示无数据响应
                    continuation.resume(returning: [:])
                }

                self?.logger.debug("[WebSocket] EmitWithAck response: \(event)", tag: "ws")
            }
        }
    }

    /// 发送事件并等待 Ack 响应（泛型版本）
    /// - Parameters:
    ///   - event: 事件名称
    ///   - data: 要发送的数据（Encodable）
    ///   - timeout: 超时时间（秒），默认 10 秒
    /// - Returns: 服务端返回的响应数据（解码为指定类型）
    /// - Throws: WebSocketError.notConnected, WebSocketError.timeout, WebSocketError.decodingFailed
    public func emitWithAck<T: Encodable, R: Decodable>(_ event: String, data: T, timeout: TimeInterval = 10) async throws -> R {
        guard isConnected else {
            throw WebSocketError.notConnected
        }

        // 编码请求数据
        let jsonData = try JSONEncoder().encode(data)
        guard let dict = try JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw WebSocketError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            socket?.emitWithAck(event, dict).timingOut(after: timeout) { [weak self] responseData in
                guard let self = self else {
                    continuation.resume(throwing: WebSocketError.notConnected)
                    return
                }

                // 检查是否超时
                if let status = responseData.first as? String, status == "NO ACK" {
                    continuation.resume(throwing: WebSocketError.timeout)
                    return
                }

                // 解析并解码响应
                if let response = responseData.first {
                    if let decoded: R = self.decode(R.self, from: response) {
                        continuation.resume(returning: decoded)
                    } else {
                        continuation.resume(throwing: WebSocketError.decodingFailed)
                    }
                } else {
                    continuation.resume(throwing: WebSocketError.decodingFailed)
                }

                self.logger.debug("[WebSocket] EmitWithAck response: \(event)", tag: "ws")
            }
        }
    }

    /// 发送事件并等待 Ack 响应（回调版本，兼容旧代码）
    /// - Parameters:
    ///   - event: 事件名称
    ///   - data: 要发送的数据
    ///   - timeout: 超时时间（秒）
    ///   - completion: 完成回调
    public func emitWithAck(_ event: String, data: [String: Any], timeout: TimeInterval = 10, completion: @escaping ([Any]) -> Void) {
        guard isConnected else {
            logger.warning("[WebSocket] Cannot emitWithAck: not connected", tag: "ws")
            completion(["NO ACK"])
            return
        }

        socket?.emitWithAck(event, data).timingOut(after: timeout) { responseData in
            completion(responseData)
        }
    }

    // MARK: - Private Methods

    private func setupSocket(with config: WebSocketConfiguration? = nil) {
        let cfg = config ?? configuration

        var socketConfig: SocketIOClientConfiguration = [
            .log(cfg.enableLogging),
            .compress,
            .reconnects(cfg.reconnects),
            .reconnectAttempts(cfg.reconnectAttempts),
            .reconnectWait(Int(cfg.reconnectWait))
        ]

        // 构建连接参数
        var connectParams: [String: Any] = cfg.extraParams ?? [:]

        // 构建 Headers
        var headers: [String: String] = cfg.extraHeaders ?? [:]

        // 根据认证方式设置 Token
        if let token = cfg.token {
            switch cfg.authMethod {
            case .queryParam(let key):
                connectParams[key] = token
            case .bearerHeader:
                headers["Authorization"] = "Bearer \(token)"
            case .customHeader(let key):
                headers[key] = token
            case .none:
                break
            }
        }

        // 添加连接参数
        if !connectParams.isEmpty {
            socketConfig.insert(.connectParams(connectParams))
        }

        // 添加 Headers
        if !headers.isEmpty {
            socketConfig.insert(.extraHeaders(headers))
        }

        // mTLS 配置
        if let sessionDelegate = cfg.sessionDelegate {
            socketConfig.insert(.sessionDelegate(sessionDelegate))
        }

        if cfg.secure {
            socketConfig.insert(.secure(true))
        }

        if cfg.selfSigned {
            socketConfig.insert(.selfSigned(true))
        }

        manager = SocketManager(socketURL: cfg.url, config: socketConfig)
        socket = manager?.defaultSocket

        setupSocketEventHandlers()
    }

    private func setupSocketEventHandlers() {
        // 连接成功
        socket?.on(clientEvent: .connect) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.connectionState = .connected
                self?.isConnected = true
                self?.lastError = nil
            }
            self?.logger.info("[WebSocket] Connected", tag: "ws")

            // 重新注册已有的事件监听
            self?.reregisterEventHandlers()
        }

        // 断开连接
        socket?.on(clientEvent: .disconnect) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.connectionState = .disconnected
                self?.isConnected = false
            }
            self?.logger.info("[WebSocket] Disconnected", tag: "ws")
        }

        // 连接错误
        socket?.on(clientEvent: .error) { [weak self] data, _ in
            let error = WebSocketError.connectionError(data.first as? String ?? "Unknown error")
            DispatchQueue.main.async {
                self?.lastError = error
            }
            self?.logger.error("[WebSocket] Error: \(error)", tag: "ws")
        }

        // 重连中
        socket?.on(clientEvent: .reconnect) { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.connectionState = .reconnecting
            }
            self?.logger.info("[WebSocket] Reconnecting...", tag: "ws")
        }

        // 重连成功
        socket?.on(clientEvent: .reconnectAttempt) { [weak self] data, _ in
            let attempt = data.first as? Int ?? 0
            self?.logger.debug("[WebSocket] Reconnect attempt \(attempt)", tag: "ws")
        }
    }

    private func reregisterEventHandlers() {
        // 重新注册所有 tokenized 事件监听器
        for event in tokenizedHandlers.keys {
            socket?.on(event) { [weak self] data, _ in
                self?.handleEvent(event, data: data)
            }
        }

        // 重新注册旧 API 事件监听器
        for event in eventHandlers.keys {
            if tokenizedHandlers[event] == nil {
                socket?.on(event) { [weak self] data, _ in
                    self?.handleEvent(event, data: data)
                }
            }
        }
    }

    private func handleEvent(_ event: String, data: [Any]) {
        guard let payload = data.first else { return }

        // 调用 tokenized handlers
        if let handlers = tokenizedHandlers[event] {
            for handler in handlers {
                handler.handler(payload)
            }
        }

        // 调用旧 API handlers（兼容）
        if let handlers = eventHandlers[event] {
            for handler in handlers {
                handler(payload)
            }
        }
    }

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
            logger.warning("[WebSocket] Decode failed: \(error)", tag: "ws-decode")
            return nil
        }
    }

    private func cleanup() {
        socket = nil
        manager = nil
        joinedRooms.removeAll()
        connectionState = .disconnected
        isConnected = false
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

/// 事件监听 Token，用于移除特定的监听器
public struct EventHandlerToken: Hashable {
    public let id: UUID
    public let event: String

    public init(event: String) {
        self.id = UUID()
        self.event = event
    }
}
