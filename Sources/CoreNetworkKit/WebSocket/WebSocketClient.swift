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

    /// 事件处理器存储
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

    /// 使用新 Token 重连（保持原有认证方式）
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
            extraHeaders: configuration.extraHeaders
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

    /// 监听事件（类型安全）
    /// - Parameters:
    ///   - event: 事件名称
    ///   - handler: 事件处理器，接收解码后的数据
    public func on<T: Decodable>(_ event: String, handler: @escaping (T) -> Void) {
        // 存储包装后的处理器
        let wrappedHandler: (Any) -> Void = { [weak self] data in
            guard let self = self else { return }
            if let decoded = self.decode(T.self, from: data) {
                handler(decoded)
            }
        }

        if eventHandlers[event] == nil {
            eventHandlers[event] = []
            // 首次注册该事件时，设置 Socket.IO 监听
            socket?.on(event) { [weak self] data, _ in
                self?.handleEvent(event, data: data)
            }
        }

        eventHandlers[event]?.append(wrappedHandler)
    }

    /// 监听事件（原始数据）
    public func onRaw(_ event: String, handler: @escaping ([Any]) -> Void) {
        socket?.on(event) { data, _ in
            handler(data)
        }
    }

    /// 取消监听事件
    public func off(_ event: String) {
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
        // 重新注册所有事件监听器
        for event in eventHandlers.keys {
            socket?.on(event) { [weak self] data, _ in
                self?.handleEvent(event, data: data)
            }
        }
    }

    private func handleEvent(_ event: String, data: [Any]) {
        guard let handlers = eventHandlers[event], !handlers.isEmpty else { return }
        guard let payload = data.first else { return }

        for handler in handlers {
            handler(payload)
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
        }
    }
}
