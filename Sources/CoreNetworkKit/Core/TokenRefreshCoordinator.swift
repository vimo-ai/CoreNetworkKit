import Foundation

/// Single-flight token refresh coordinator.
///
/// Ensures that only one token refresh operation is in progress at any
/// given time. Concurrent callers share the same refresh task and all
/// receive the result once it completes.
///
/// Previously defined inside `APIClient.swift`; extracted so it can be
/// reused by `TaskExecutor`, `ConnectTransport`, and other components.
internal actor TokenRefreshCoordinator {
    private var ongoingTask: Task<String, Error>?

    internal func refresh(using refresher: TokenRefresher) async throws {
        if let task = ongoingTask {
            _ = try await task.value
            return
        }

        let task = Task { () throws -> String in
            try await refresher.refreshToken()
        }
        ongoingTask = task
        defer { ongoingTask = nil }
        _ = try await task.value
    }
}
