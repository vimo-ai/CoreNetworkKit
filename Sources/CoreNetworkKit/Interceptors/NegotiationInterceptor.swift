import Foundation

// MARK: - ServerCapabilities

public struct ServerCapabilities: Sendable {
    public var apiVersion: String?
    public var supportedEncodings: [String]?
    public var features: Set<String>?
    public var raw: [String: String]

    public init(
        apiVersion: String? = nil,
        supportedEncodings: [String]? = nil,
        features: Set<String>? = nil,
        raw: [String: String] = [:]
    ) {
        self.apiVersion = apiVersion
        self.supportedEncodings = supportedEncodings
        self.features = features
        self.raw = raw
    }
}

// MARK: - NegotiationConfig

public struct NegotiationConfig: Sendable {
    public var headerPrefix: String
    public var versionHeader: String
    public var encodingHeader: String
    public var featuresHeader: String
    public var clientVersionHeader: String
    public var clientVersion: String?
    public var onCapabilities: (@Sendable (String, ServerCapabilities) -> Void)?
    public var cacheTtlSeconds: TimeInterval

    public init(
        headerPrefix: String = "x-server-",
        versionHeader: String = "x-api-version",
        encodingHeader: String = "x-supported-encodings",
        featuresHeader: String = "x-server-features",
        clientVersionHeader: String = "x-client-version",
        clientVersion: String? = nil,
        onCapabilities: (@Sendable (String, ServerCapabilities) -> Void)? = nil,
        cacheTtlSeconds: TimeInterval = 300
    ) {
        self.headerPrefix = headerPrefix
        self.versionHeader = versionHeader
        self.encodingHeader = encodingHeader
        self.featuresHeader = featuresHeader
        self.clientVersionHeader = clientVersionHeader
        self.clientVersion = clientVersion
        self.onCapabilities = onCapabilities
        self.cacheTtlSeconds = cacheTtlSeconds
    }
}

// MARK: - NegotiationInterceptor

/// Sends `x-client-version` and caches server capabilities (with TTL).
/// Aligned with kine-server `createNegotiationInterceptor`.
public func createNegotiationInterceptor(config: NegotiationConfig = NegotiationConfig()) -> NegotiationInterceptorRef {
    NegotiationInterceptorRef(config: config)
}

/// Reference type so callers can query cached capabilities and clear the cache.
public final class NegotiationInterceptorRef: RequestInterceptor, @unchecked Sendable {

    private let config: NegotiationConfig
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var originQueue: [String] = []

    init(config: NegotiationConfig) {
        self.config = config
    }

    // MARK: - Public API

    /// Retrieve cached capabilities for a base URL origin.
    public func getCapabilities(baseURL: String) -> ServerCapabilities? {
        let origin = Self.extractOrigin(from: baseURL)
        return locked { getCachedCapabilities(origin: origin) }
    }

    /// Clear all cached capabilities.
    public func clearCache() {
        locked { cache.removeAll() }
    }

    // MARK: - RequestInterceptor

    public func onRequest(_ requestConfig: RequestConfig) async throws -> RequestConfig {
        var updated = requestConfig

        if let version = config.clientVersion {
            updated.headers[config.clientVersionHeader] = version
        }

        let origin = Self.extractOrigin(from: requestConfig.url)
        locked { originQueue.append(origin) }

        if let cached = locked({ getCachedCapabilities(origin: origin) }),
           let encodings = cached.supportedEncodings, !encodings.isEmpty {
            updated.headers["accept-encoding"] = encodings.joined(separator: ", ")
        }

        return updated
    }

    public func onResponse<T: Sendable>(_ response: ResponseData<T>) async throws -> ResponseData<T> {
        let responseHeaders = response.headers
        var raw: [String: String] = [:]

        for (key, value) in responseHeaders {
            if key.lowercased().hasPrefix(config.headerPrefix) {
                raw[key] = value
            }
        }

        let version = responseHeaders[config.versionHeader]
        let encodingsRaw = responseHeaders[config.encodingHeader]
        let featuresRaw = responseHeaders[config.featuresHeader]

        if let v = version { raw[config.versionHeader] = v }
        if let e = encodingsRaw { raw[config.encodingHeader] = e }
        if let f = featuresRaw { raw[config.featuresHeader] = f }

        guard !raw.isEmpty else { return response }

        var capabilities = ServerCapabilities(raw: raw)

        if let v = version {
            capabilities.apiVersion = v
        }
        if let e = encodingsRaw {
            capabilities.supportedEncodings = e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        if let f = featuresRaw {
            capabilities.features = Set(f.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }

        let origin: String? = locked {
            originQueue.isEmpty ? nil : originQueue.removeFirst()
        }

        if let origin {
            locked {
                cache[origin] = CacheEntry(
                    capabilities: capabilities,
                    expiresAt: Date().addingTimeInterval(config.cacheTtlSeconds)
                )
            }
            config.onCapabilities?(origin, capabilities)
        }

        return response
    }

    // MARK: - Private

    private struct CacheEntry {
        let capabilities: ServerCapabilities
        let expiresAt: Date
    }

    private func getCachedCapabilities(origin: String) -> ServerCapabilities? {
        guard let entry = cache[origin] else { return nil }
        if Date() > entry.expiresAt {
            cache.removeValue(forKey: origin)
            return nil
        }
        return entry.capabilities
    }

    private func locked<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    static func extractOrigin(from urlString: String) -> String {
        guard let url = URL(string: urlString),
              let scheme = url.scheme,
              let host = url.host else {
            return urlString
        }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }
}
