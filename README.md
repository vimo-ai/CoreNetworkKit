# CoreNetworkKit

A robust networking framework for Swift applications with advanced features like rate limiting, authentication, and request stacking.

## Features

- Modern async/await API
- Built-in authentication strategies
- Rate limiting and frequency control
- Request stacking and batch processing
- Comprehensive error handling
- Logging integration with MLoggerKit

## Installation

Add this package to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/vimo-ai/CoreNetworkKit.git", from: "1.0.0")
]
```

## Requirements

- iOS 15.0+ / macOS 12.0+ / tvOS 15.0+
- Swift 5.8+

## Usage

```swift
import CoreNetworkKit

// Basic usage example
let client = APIClient(baseURL: "https://api.example.com")
let response = try await client.execute(request)
```

## License

Private - VIMO Organization