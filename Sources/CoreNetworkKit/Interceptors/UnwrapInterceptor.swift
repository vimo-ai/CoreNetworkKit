import Foundation

// MARK: - Wrapped Response Shape

/// The standard envelope returned by the Vimo backend.
private struct WrappedEnvelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let message: String?
}

// MARK: - BusinessError (v2)

/// Thrown when the server returns `{ success: false }` inside a 2xx response.
/// Aligned with kine-server `BusinessError`.
public struct BusinessErrorV2: Error, LocalizedError, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: - UnwrapInterceptor

/// Unwraps the `{ success, data, message }` response envelope.
/// Aligned with kine-server `createUnwrapInterceptor`.
///
/// If the response body matches the wrapped shape and `success` is
/// `true`, the interceptor replaces `ResponseData.data` with the inner
/// `data` field. If `success` is `false`, it throws a `BusinessErrorV2`.
///
/// Responses that do not match the wrapped shape are passed through
/// unchanged.
public func createUnwrapInterceptor() -> RequestInterceptor {
    UnwrapInterceptorImpl()
}

private struct UnwrapInterceptorImpl: RequestInterceptor, Sendable {

    func onResponse<T: Sendable>(_ response: ResponseData<T>) async throws -> ResponseData<T> {
        // Only attempt unwrap when T is Decodable (which it always is in
        // our pipeline). We rely on the raw data being still decodable;
        // however, since ResponseData.data is already decoded, we check
        // if it matches the wrapped shape at runtime.
        guard let anyData = response.data as? any Decodable else {
            return response
        }
        return try attemptUnwrap(response: response, decoded: anyData)
    }

    private func attemptUnwrap<T: Sendable>(
        response: ResponseData<T>,
        decoded: any Decodable
    ) throws -> ResponseData<T> {
        // Use Mirror to check for the wrapped shape without re-decoding.
        let mirror = Mirror(reflecting: decoded)
        guard let successChild = mirror.children.first(where: { $0.label == "success" }),
              let success = successChild.value as? Bool,
              let dataChild = mirror.children.first(where: { $0.label == "data" }) else {
            return response
        }

        if !success {
            let message: String
            if let msgChild = mirror.children.first(where: { $0.label == "message" }),
               let msg = msgChild.value as? String {
                message = msg
            } else {
                message = "Request failed"
            }
            throw BusinessErrorV2(message: message)
        }

        // If the inner data is the same type as T, replace it.
        if let innerData = dataChild.value as? T {
            return ResponseData(
                status: response.status,
                headers: response.headers,
                data: innerData
            )
        }

        return response
    }
}
