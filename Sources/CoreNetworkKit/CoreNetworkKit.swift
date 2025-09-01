// CoreNetworkKit - Main Export File
// This file re-exports all public APIs from the CoreNetworkKit package

// MARK: - Core Types
@_exported import Foundation

// MARK: - Core Components
// Re-export all public types from individual modules

// Core
// (APIClient is exported directly from Core/APIClient.swift)
// (EnhancedAPIClient is exported directly from Core/EnhancedAPIClient.swift)

// Protocols
// (Request protocol is exported directly from Protocols/Request.swift)
// (BeaconFlowRequest protocol is exported directly from Protocols/BeaconFlowRequest.swift)
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
// (URLSessionEngine is exported directly from Engine/URLSessionEngine.swift)

// Strategies
// (NoAuthenticationStrategy is exported directly from Strategies/NoAuthenticationStrategy.swift)
// (BearerTokenAuthenticationStrategy is exported directly from Strategies/BearerTokenAuthenticationStrategy.swift)

// Errors
// (APIError is exported directly from Errors/APIError.swift)

// Utilities
// (WrappedResponse, BusinessError, UserFeedbackHandler are exported directly from Utilities/ResponseWrapper.swift)
// (BeaconFlowWrappedResponse, BeaconFlowBusinessError are exported directly from Utilities/BeaconFlowWrapper.swift)

// MARK: - Version Information
public struct CoreNetworkKitVersion {
    public static let version = "1.0.0"
    public static let buildNumber = "1"
}