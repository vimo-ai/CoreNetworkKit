import Foundation

// MARK: - RequestInterceptor Protocol

/// Composable middleware for request/response transformation.
///
/// Interceptors form a pipeline: each one can modify the request on the
/// way out, transform the response on the way back, or remap errors.
/// Default implementations are provided so concrete interceptors only
/// need to override the hooks they care about.
public protocol RequestInterceptor: Sendable {
    func onRequest(_ config: RequestConfig) async throws -> RequestConfig
    func onResponse<T: Sendable>(_ response: ResponseData<T>) async throws -> ResponseData<T>
    func onError(_ error: RequestError) async throws -> RequestError
}

// MARK: - Default Implementations

public extension RequestInterceptor {
    func onRequest(_ config: RequestConfig) async throws -> RequestConfig { config }
    func onResponse<T: Sendable>(_ response: ResponseData<T>) async throws -> ResponseData<T> { response }
    func onError(_ error: RequestError) async throws -> RequestError { error }
}

// MARK: - InterceptorChain

/// Thread-safe interceptor chain aligned with kine-server `InterceptorChain`.
///
/// Interceptors are applied in registration order for requests and
/// responses, and in registration order for errors (matching the TS
/// implementation).
///
/// `use(_:)` returns an unsubscribe closure. Calling it removes the
/// interceptor from the chain.
public final class InterceptorChain: @unchecked Sendable {

    private let lock = NSLock()
    private var interceptors: [RequestInterceptor] = []

    public init() {}

    /// Register an interceptor.
    /// - Returns: A closure that removes the interceptor when called.
    @discardableResult
    public func use(_ interceptor: RequestInterceptor) -> () -> Void {
        lock.lock()
        interceptors.append(interceptor)
        lock.unlock()

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if let idx = self.interceptors.firstIndex(where: { $0 as AnyObject === interceptor as AnyObject }) {
                self.interceptors.remove(at: idx)
            }
            self.lock.unlock()
        }
    }

    /// Run all `onRequest` hooks sequentially.
    public func applyRequest(_ config: RequestConfig) async throws -> RequestConfig {
        let snapshot = locked { interceptors }
        var current = config
        for interceptor in snapshot {
            current = try await interceptor.onRequest(current)
        }
        return current
    }

    /// Run all `onResponse` hooks sequentially.
    public func applyResponse<T: Sendable>(_ response: ResponseData<T>) async throws -> ResponseData<T> {
        let snapshot = locked { interceptors }
        var current = response
        for interceptor in snapshot {
            current = try await interceptor.onResponse(current)
        }
        return current
    }

    /// Run all `onError` hooks sequentially.
    public func applyError(_ error: RequestError) async throws -> RequestError {
        let snapshot = locked { interceptors }
        var current = error
        for interceptor in snapshot {
            current = try await interceptor.onError(current)
        }
        return current
    }

    // MARK: - Private

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
