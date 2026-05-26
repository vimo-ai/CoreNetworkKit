import Foundation

// MARK: - CircuitState

/// State machine for the circuit breaker, aligned with kine-server.
public enum CircuitState: String, Sendable {
    case closed = "CLOSED"
    case open = "OPEN"
    case halfOpen = "HALF_OPEN"
}

// MARK: - CircuitBreakerConfig

public struct CircuitBreakerConfig: Sendable {
    /// Number of consecutive failures before the circuit opens.
    public let failureThreshold: Int

    /// Time (seconds) the circuit stays open before transitioning to half-open.
    public let resetTimeout: TimeInterval

    /// Maximum concurrent requests allowed in half-open state.
    public let halfOpenMax: Int

    /// Optional predicate to decide whether an error should count as a failure.
    public let shouldTrip: (@Sendable (RequestError) -> Bool)?

    /// Optional callback invoked on state transitions.
    public let onStateChange: (@Sendable (CircuitState, CircuitState) -> Void)?

    public init(
        failureThreshold: Int,
        resetTimeout: TimeInterval,
        halfOpenMax: Int = 1,
        shouldTrip: (@Sendable (RequestError) -> Bool)? = nil,
        onStateChange: (@Sendable (CircuitState, CircuitState) -> Void)? = nil
    ) {
        self.failureThreshold = failureThreshold
        self.resetTimeout = resetTimeout
        self.halfOpenMax = halfOpenMax
        self.shouldTrip = shouldTrip
        self.onStateChange = onStateChange
    }
}

// MARK: - CircuitOpenError

public struct CircuitOpenError: Error, LocalizedError, Sendable {
    public let state: CircuitState
    public let message: String

    public init(message: String = "Circuit breaker is open") {
        self.state = .open
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: - CircuitBreaker

/// Actor-based circuit breaker aligned with kine-server `CircuitBreaker`.
///
/// The breaker starts in `.closed` state. After `failureThreshold`
/// consecutive qualifying failures it transitions to `.open`, blocking
/// all requests. After `resetTimeout` seconds it moves to `.halfOpen`
/// and allows up to `halfOpenMax` probe requests. A successful probe
/// resets the breaker to `.closed`; a failed probe re-opens the circuit.
public actor CircuitBreaker {

    private var _state: CircuitState = .closed
    private var failures: Int = 0
    private var halfOpenActive: Int = 0
    private var resetTask: Task<Void, Never>?
    private let config: CircuitBreakerConfig

    public init(config: CircuitBreakerConfig) {
        self.config = config
    }

    /// The current circuit state.
    public var state: CircuitState { _state }

    /// Execute `fn` through the circuit breaker.
    ///
    /// - Throws: `CircuitOpenError` if the breaker is open (or half-open at capacity),
    ///           or the underlying error from `fn`.
    public func execute<T: Sendable>(_ fn: @Sendable () async throws -> T) async throws -> T {
        if _state == .open {
            throw CircuitOpenError()
        }

        if _state == .halfOpen && halfOpenActive >= config.halfOpenMax {
            throw CircuitOpenError(message: "Circuit breaker is half-open and at capacity")
        }

        if _state == .halfOpen {
            halfOpenActive += 1
        }

        do {
            let result = try await fn()
            onSuccess()
            return result
        } catch {
            onFailure(error)
            throw error
        }
    }

    /// Manually reset the breaker to closed.
    public func reset() {
        cancelResetTimer()
        failures = 0
        halfOpenActive = 0
        transition(to: .closed)
    }

    // MARK: - Private

    private func onSuccess() {
        if _state == .halfOpen {
            halfOpenActive = 0
            failures = 0
            transition(to: .closed)
        }
        if _state == .closed {
            failures = 0
        }
    }

    private func onFailure(_ error: Error) {
        let shouldTrip = config.shouldTrip ?? Self.defaultShouldTrip
        guard let requestError = error as? RequestError, shouldTrip(requestError) else {
            if _state == .halfOpen {
                halfOpenActive -= 1
            }
            return
        }

        if _state == .halfOpen {
            halfOpenActive = 0
            scheduleReset()
            transition(to: .open)
            return
        }

        failures += 1
        if failures >= config.failureThreshold {
            scheduleReset()
            transition(to: .open)
        }
    }

    private func transition(to newState: CircuitState) {
        guard _state != newState else { return }
        let from = _state
        _state = newState
        config.onStateChange?(from, newState)
    }

    private func scheduleReset() {
        cancelResetTimer()
        resetTask = Task { [weak self, timeout = config.resetTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.transitionToHalfOpen()
        }
    }

    private func transitionToHalfOpen() {
        halfOpenActive = 0
        transition(to: .halfOpen)
    }

    private func cancelResetTimer() {
        resetTask?.cancel()
        resetTask = nil
    }

    private static let defaultShouldTrip: @Sendable (RequestError) -> Bool = { error in
        error.isNetwork || error.isTimeout || error.isServerError
    }
}
