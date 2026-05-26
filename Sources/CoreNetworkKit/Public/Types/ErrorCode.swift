import Foundation

/// Unified error code enum aligned with kine-server ErrorCode.
///
/// Classifies request failures into discrete categories so callers
/// can branch on the *kind* of failure without inspecting HTTP status
/// codes or underlying `Error` types directly.
public enum ErrorCode: String, Sendable {
    case network = "NETWORK"
    case timeout = "TIMEOUT"
    case abort = "ABORT"
    case http = "HTTP"
    case parse = "PARSE"
    case auth = "AUTH"
    case circuitOpen = "CIRCUIT_OPEN"
    case unknown = "UNKNOWN"
}
