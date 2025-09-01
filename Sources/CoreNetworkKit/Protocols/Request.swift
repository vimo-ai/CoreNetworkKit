import Foundation

/// 定义一个网络请求所需的所有基本元素。
///
/// 任何具体的API请求都需要实现这个协议，从而能够被 `APIClient` 处理。
/// 这种设计将请求的定义与其执行过程完全解耦，并提供完全类型安全的请求体定义。
public protocol Request {
    /// 响应数据的预期类型，必须遵守 `Decodable` 协议。
    /// `APIClient` 将尝试把网络响应解码为此类型。
    associatedtype Response: Decodable
    
    /// 请求体数据类型，必须遵守 `Encodable` 协议。
    /// 默认为 `EmptyBody`，适用于GET请求等无需请求体的场景。
    /// 对于需要请求体的请求，可以指定具体的强类型数据结构。
    associatedtype Body: Encodable = EmptyBody
    
    /// API 的基础 URL。
    /// 例如: "https://api.bilibili.com"
    var baseURL: URL { get }
    
    /// 请求的路径部分。
    /// 例如: "/x/web-interface/view"
    var path: String { get }
    
    /// HTTP 请求方法 (GET, POST, etc.)。
    var method: HTTPMethod { get }
    
    /// 请求头。
    /// 默认是空的，可以根据需要提供。
    var headers: [String: String]? { get }
    
    /// URL 查询参数。
    /// 无论请求方法如何，这些参数都会被添加到 URL 的查询字符串中。
    /// 仍使用字典格式，因为查询参数通常是简单的键值对。
    var query: [String: Any]? { get }
    
    /// 强类型的请求体数据。
    /// 对于支持请求体的方法（如 POST、PUT），返回强类型的Encodable对象。
    /// APIClient会自动使用JSONEncoder将其序列化为JSON格式。
    /// - GET请求：使用默认的EmptyBody类型，返回nil
    /// - POST/PUT/PATCH请求：返回具体的数据对象，如AgreementCreateData
    var body: Body? { get }
    
    // MARK: - 可选的自定义配置
    
    /// 请求的超时时间（秒）。
    /// 如果为 `nil`，将使用 `URLSession` 的默认超时。
    var timeoutInterval: TimeInterval? { get }
    
    /// The authentication strategy required for this request.
    /// This is a synchronous property that returns a strategy instance.
    /// The strategy's `apply` method can then be called asynchronously.
    var authentication: AuthenticationStrategy { get }
}

// MARK: - 空请求体类型

/// 空请求体类型，用于GET等无需请求体的请求。
/// 实现Encodable协议，但序列化时会被忽略。
public struct EmptyBody: Encodable {
    public init() {}
}

// MARK: - 默认实现

public extension Request {
    
    /// 默认请求头为空。
    var headers: [String: String]? {
        nil
    }

    /// 默认查询参数为空。
    var query: [String: Any]? {
        nil
    }
    
    /// 默认请求体为空。
    /// 对于Body类型为EmptyBody的请求，返回nil。
    /// 有具体Body类型的请求需要重写此属性。
    var body: Body? {
        nil
    }

    /// 默认不设置超时时间，使用会话的默认值。
    var timeoutInterval: TimeInterval? {
        nil
    }

    /// 默认情况下，请求使用无认证策略。
    var authentication: AuthenticationStrategy {
        NoAuthenticationStrategy()
    }
}


/// HTTP 请求方法枚举
public enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
    case patch = "PATCH"
}