import Foundation

// MARK: - Request Key Builder

/// Build a stable key for identifying equivalent requests.
/// Matches kine-server `buildRequestKey()`.
public func buildRequestKey(method: String, url: String, body: (any Encodable)? = nil) -> String {
    let bodyPart: String
    if let body = body {
        bodyPart = stableStringify(body)
    } else {
        bodyPart = ""
    }
    return "\(method):\(url):\(bodyPart)"
}

private func stableStringify(_ value: Any) -> String {
    if let encodable = value as? any Encodable {
        if let data = try? JSONEncoder().encode(AnyEncodableBox(encodable)),
           let obj = try? JSONSerialization.jsonObject(with: data),
           let sorted = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
           let str = String(data: sorted, encoding: .utf8) {
            return str
        }
    }
    return ""
}

/// Type-erased encodable box for stable serialization.
private struct AnyEncodableBox: Encodable {
    private let _encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        _encode = { encoder in try value.encode(to: encoder) }
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

// MARK: - ControlGateV2

/// Actor-based flow control gate aligned with kine-server `ControlGate`.
///
/// Provides debounce, throttle, and deduplicate semantics on a per-key
/// basis. The gate is used internally by `NetworkClientV2` to apply the
/// `ControlPolicy` associated with each request.
public actor ControlGateV2 {

    private var debounceMap: [String: DebounceEntry] = [:]
    private var throttleMap: [String: Date] = [:]
    private var deduplicateMap: [String: Task<AnySendable, Error>] = [:]

    public init() {}

    /// Execute `fn` subject to the given control policy.
    public func execute<T: Sendable>(
        key: String,
        fn: @escaping @Sendable () async throws -> T,
        policy: ControlPolicy
    ) async throws -> T {
        if let debounce = policy.debounce, debounce > 0 {
            return try await withDebounce(key: key, delay: debounce, fn: fn)
        }
        if let throttle = policy.throttle, throttle > 0 {
            try await waitThrottle(key: key, interval: throttle)
        }
        if policy.deduplicate {
            return try await withDeduplicate(key: key, fn: fn)
        }
        return try await fn()
    }

    /// Cancel all pending debounces and clear internal state.
    public func dispose() {
        for entry in debounceMap.values {
            entry.task.cancel()
        }
        debounceMap.removeAll()
        throttleMap.removeAll()
        for task in deduplicateMap.values {
            task.cancel()
        }
        deduplicateMap.removeAll()
    }

    // MARK: - Debounce

    private struct DebounceEntry {
        let task: Task<Void, Never>
        let continuation: CheckedContinuation<Void, Error>?
    }

    private func withDebounce<T: Sendable>(
        key: String,
        delay: TimeInterval,
        fn: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        // Cancel the previous debounce for this key.
        if let prev = debounceMap[key] {
            prev.task.cancel()
        }

        // Wait for the debounce interval.
        let delayNanos = UInt64(delay * 1_000_000_000)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let task = Task<Void, Never> { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: delayNanos)
                    cont.resume()
                } catch {
                    cont.resume(throwing: CancellationError())
                }
                await self?.removeDebounce(key: key)
            }
            debounceMap[key] = DebounceEntry(task: task, continuation: nil)
        }

        return try await fn()
    }

    private func removeDebounce(key: String) {
        debounceMap.removeValue(forKey: key)
    }

    // MARK: - Throttle

    private func waitThrottle(key: String, interval: TimeInterval) async throws {
        let lastTime = throttleMap[key] ?? .distantPast
        let elapsed = Date().timeIntervalSince(lastTime)
        if elapsed < interval {
            let remaining = interval - elapsed
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        throttleMap[key] = Date()
    }

    // MARK: - Deduplicate

    private func withDeduplicate<T: Sendable>(
        key: String,
        fn: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        if let existing = deduplicateMap[key] {
            let any = try await existing.value
            // Force-cast is safe because the same key always maps to the same T.
            return any.value as! T
        }

        let task = Task<AnySendable, Error> { [weak self] in
            defer {
                Task { await self?.removeDedup(key: key) }
            }
            let result = try await fn()
            return AnySendable(result)
        }
        deduplicateMap[key] = task

        let any = try await task.value
        return any.value as! T
    }

    private func removeDedup(key: String) {
        deduplicateMap.removeValue(forKey: key)
    }
}

// MARK: - AnySendable

/// Type-erased Sendable container for actor-isolated generic storage.
private struct AnySendable: Sendable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }
}
