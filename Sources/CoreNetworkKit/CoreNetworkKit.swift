// CoreNetworkKit - Main Export File
// This file re-exports all public APIs from the CoreNetworkKit package

// MARK: - Core Types
@_exported import Foundation

// MARK: - Core Components (v2)
//
// v2 Architecture (aligned with kine-server):
//   NetworkClientV2 — unified HTTP client with interceptor chain
//   InterceptorChain — composable request/response middleware
//   CircuitBreaker — CLOSED/OPEN/HALF_OPEN state machine
//   ControlGateV2 — debounce/throttle/deduplicate flow control
//   withRetry() — standalone retry function
//
// v2 Types:
//   RequestConfig — unified request descriptor
//   ResponseData<T> — unified response container
//   RequestError — unified error with ErrorCode
//   ErrorCode — NETWORK/TIMEOUT/ABORT/HTTP/PARSE/AUTH/CIRCUIT_OPEN/UNKNOWN
//   PerRequestConfig — per-call overrides
//
// Interceptors:
//   createTokenInterceptor() — bearer token injection
//   createAuthInterceptor() — 401/403 detection
//   createUnwrapInterceptor() — { success, data, message } envelope unwrap
//   createTracingInterceptor() — x-request-id propagation
//   createNegotiationInterceptor() — server capability detection
//
// Legacy (deprecated — will be removed in a future version):
//   APIClient → use NetworkClientV2
//   EnhancedAPIClient → use NetworkClientV2
//   APIError → use RequestError

// Protocols
// (Request protocol is exported directly from Protocols/Request.swift)
// (VimoRequest protocol is exported directly from Protocols/VimoRequest.swift)
// (NetworkEngine is exported directly from Protocols/NetworkEngine.swift)
// (AuthenticationStrategy is exported directly from Protocols/AuthenticationStrategy.swift)

// Rate Limiting
// (RateLimitStrategy is exported directly from RateLimit/RateLimitStrategy.swift)
// (FrequencyLimitStrategy is exported directly from RateLimit/FrequencyLimitStrategy.swift)

// Request Stack
// (RequestExecutor is exported directly from RequestStack/RequestExecutor.swift)
// (RequestStack is exported directly from RequestStack/RequestStack.swift)

// Factories
// (NetworkStackFactory is exported directly from Factories/NetworkStackFactory.swift)

// Engines
// (AlamofireEngine is exported directly from Engine/AlamofireEngine.swift)

// Strategies
// (NoAuthenticationStrategy is exported directly from Strategies/NoAuthenticationStrategy.swift)
// (BearerTokenAuthenticationStrategy is exported directly from Strategies/BearerTokenAuthenticationStrategy.swift)

// Utilities
// (WrappedResponse, BusinessError, UserFeedbackHandler are exported directly from Utilities/ResponseWrapper.swift)
// (VimoWrappedResponse, VimoBusinessError are exported directly from Utilities/VimoWrapper.swift)

// Stream (SSE)
// (StreamRequest protocol is exported directly from Protocols/StreamRequest.swift)
// (StreamClient is exported directly from Core/StreamClient.swift)

// WebSocket
// (WebSocketClient is exported directly from WebSocket/WebSocketClient.swift)
// (WebSocketConfiguration is exported directly from WebSocket/WebSocketEvent.swift)
// (WebSocketConnectionState is exported directly from WebSocket/WebSocketEvent.swift)

// Connect
// (ConnectTransport is exported directly from Connect/ConnectTransport.swift)
// (TransportNegotiator is exported directly from Connect/TransportNegotiator.swift)

// MARK: - Version Information
public struct CoreNetworkKitVersion {
    public static let version = "3.0.0"
    public static let buildNumber = "1"
}