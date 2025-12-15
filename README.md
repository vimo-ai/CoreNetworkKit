# CoreNetworkKit

A robust networking framework for Swift applications with advanced features like REST API, SSE streaming, WebSocket, authentication, and rate limiting.

## Features

- Modern async/await API
- **REST API** - Type-safe request/response with automatic token refresh
- **SSE Streaming** - Server-Sent Events for AI streaming scenarios
- **WebSocket** - Socket.IO based real-time communication
- Built-in authentication strategies (Bearer Token, Query Param, Custom Header)
- Rate limiting and frequency control
- Request stacking and batch processing
- Comprehensive error handling
- Logging integration with MLoggerKit

## Installation

Add this package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vimo-ai/CoreNetworkKit.git", from: "2.0.0")
]
```

## Requirements

- iOS 15.0+ / macOS 12.0+ / tvOS 15.0+
- Swift 5.8+

## Usage

### REST API

```swift
import CoreNetworkKit

// Define a request
struct GetUserRequest: Request {
    typealias Response = User

    var baseURL: URL { URL(string: "https://api.example.com")! }
    var path: String { "/users/me" }
    var method: HTTPMethod { .get }
    var authentication: AuthenticationStrategy { BearerTokenAuthenticationStrategy() }
}

// Send request
let client = APIClient(engine: URLSessionEngine(), tokenStorage: myTokenStorage)
let user = try await client.send(GetUserRequest())
```

### SSE Streaming (AI)

```swift
import CoreNetworkKit

// Define a stream request
struct AICompletionRequest: StreamRequest {
    typealias Response = EmptyBody
    typealias Chunk = AICompletionChunk

    let messages: [Message]

    var baseURL: URL { URL(string: "https://api.openai.com")! }
    var path: String { "/v1/chat/completions" }
    var method: HTTPMethod { .post }
    var body: RequestBody? { RequestBody(messages: messages, stream: true) }
    var authentication: AuthenticationStrategy { BearerTokenAuthenticationStrategy() }

    // Optional: customize SSE format (defaults to OpenAI format)
    // var streamDataPrefix: String { "data:" }
    // var streamDoneMarker: String { "[DONE]" }
}

// Stream response
let streamClient = StreamClient(tokenStorage: myTokenStorage)

for try await chunk in streamClient.stream(AICompletionRequest(messages: [...])) {
    print(chunk.delta.content ?? "")
}

// Or use callback style
streamClient.stream(
    AICompletionRequest(messages: [...]),
    onChunk: { chunk in print(chunk) },
    onComplete: { print("Done") },
    onError: { error in print(error) }
)
```

### WebSocket (Socket.IO)

```swift
import CoreNetworkKit

// Method 1: Token as query parameter (default)
let client = WebSocketClient(url: serverURL, token: "your-token")

// Method 2: JWT Bearer Token in header
let client = WebSocketClient(url: serverURL, bearerToken: "jwt-token")

// Method 3: Full configuration
let config = WebSocketConfiguration(
    url: serverURL,
    token: "jwt-token",
    authMethod: .bearerHeader,  // .queryParam(), .customHeader(key:), .none
    reconnects: true,
    reconnectAttempts: 5,
    extraParams: ["clientType": "ios"],
    extraHeaders: ["X-Client-Version": "1.0"]
)
let client = WebSocketClient(configuration: config)

// Connect
client.connect()

// Listen to events (type-safe)
client.on("message:new") { (message: ChatMessage) in
    print("New message: \(message.text)")
}

// Emit events
client.emit("send", data: ["text": "Hello"])
client.emit("typing", data: TypingEvent(userId: "123"))

// Room management
client.join(room: "session-123", params: ["projectPath": "/path"])
client.leave(room: "session-123")

// Reconnect with new token
client.reconnect(withToken: "new-token")

// Observe connection state (SwiftUI)
struct MyView: View {
    @ObservedObject var wsClient: WebSocketClient

    var body: some View {
        Text(wsClient.isConnected ? "Connected" : "Disconnected")
    }
}
```

## Authentication

### REST & SSE

Use `AuthenticationStrategy` protocol:

```swift
// Built-in strategies
var authentication: AuthenticationStrategy {
    BearerTokenAuthenticationStrategy()  // Authorization: Bearer <token>
    NoAuthenticationStrategy()           // No auth
}
```

### WebSocket

Use `WebSocketAuthMethod` enum:

```swift
let config = WebSocketConfiguration(
    url: serverURL,
    token: "your-token",
    authMethod: .queryParam(key: "token")  // ?token=xxx (default)
    // authMethod: .bearerHeader           // Authorization: Bearer xxx
    // authMethod: .customHeader(key: "X-Auth-Token")
    // authMethod: .none
)
```

## Architecture

```
CoreNetworkKit/
├── Core/
│   ├── APIClient.swift          # REST client
│   └── StreamClient.swift       # SSE streaming client
├── WebSocket/
│   ├── WebSocketClient.swift    # Socket.IO wrapper
│   └── WebSocketEvent.swift     # Configuration & types
├── Protocols/
│   ├── Request.swift            # REST request protocol
│   ├── StreamRequest.swift      # SSE request protocol
│   └── AuthenticationStrategy.swift
├── Engine/
│   └── URLSessionEngine.swift
└── ...
```

## License

Private - VIMO Organization
