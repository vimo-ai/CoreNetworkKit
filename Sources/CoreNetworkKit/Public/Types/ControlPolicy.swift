import Foundation

/// Request control policy aligned with kine-server `ControlPolicy`.
///
/// Provides debounce, throttle, and deduplicate capabilities:
/// - debounce: wait until no new requests arrive within the interval
/// - throttle: limit execution frequency
/// - deduplicate: reuse in-flight requests with the same key
///
/// Priority has been moved to `PerRequestConfig` (v2 architecture).
/// The `Priority` enum is kept here for backward compatibility and
/// is still used by `PerRequestConfig`.
public struct ControlPolicy: Sendable {
    /// Debounce interval (seconds). Nil means no debounce.
    public var debounce: TimeInterval?

    /// Throttle interval (seconds). Nil means no throttle.
    public var throttle: TimeInterval?

    /// Whether to deduplicate identical in-flight requests.
    public var deduplicate: Bool

    /// Legacy priority field. Prefer `PerRequestConfig.priority` in v2.
    @available(*, deprecated, message: "Use PerRequestConfig.priority instead")
    public var priority: Priority {
        get { _priority }
        set { _priority = newValue }
    }

    private var _priority: Priority

    public init(
        debounce: TimeInterval? = nil,
        throttle: TimeInterval? = nil,
        deduplicate: Bool = false,
        priority: Priority = .normal
    ) {
        self.debounce = debounce
        self.throttle = throttle
        self.deduplicate = deduplicate
        self._priority = priority
    }

    /// Request priority levels.
    public enum Priority: Int, Comparable, Sendable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3

        public static func < (lhs: Priority, rhs: Priority) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }
}
