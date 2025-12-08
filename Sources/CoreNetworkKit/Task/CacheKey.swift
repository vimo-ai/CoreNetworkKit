import Foundation
import CryptoKit

/// 缓存键
///
/// 用于标识唯一的请求，同时用于：
/// - 缓存查找
/// - 请求去重
///
/// 计算规则：
/// - 基于请求的 method、url、query 参数、body 内容
/// - 使用 SHA256 生成稳定的跨进程哈希
/// - query 参数排序后计算 hash，保证顺序无关
/// - body JSON 使用 sortedKeys 规范化后计算 hash，保证字段顺序无关
public struct CacheKey: Hashable, Sendable {
    /// 哈希值（SHA256 的前 16 字节 hex 表示）
    public let value: String

    private init(value: String) {
        self.value = value
    }

    /// 从请求参数生成缓存键
    /// - Parameters:
    ///   - method: HTTP 方法
    ///   - baseURL: 基础 URL
    ///   - path: 请求路径
    ///   - query: 查询参数
    ///   - body: 请求体数据（JSON）
    public static func from(
        method: String,
        baseURL: URL,
        path: String,
        query: [String: Any]?,
        body: Data?
    ) -> CacheKey {
        var components: [String] = []

        // 1. Method（大写规范化）
        components.append(method.uppercased())

        // 2. 完整 URL（规范化路径）
        let url = baseURL.appendingPathComponent(path).absoluteString
        components.append(url)

        // 3. Query 参数（排序 + URL 编码）
        if let query = query, !query.isEmpty {
            let sortedQuery = canonicalizeQueryParams(query)
            components.append(sortedQuery)
        }

        // 4. Body（JSON 规范化）
        if let body = body, !body.isEmpty {
            let canonicalBody = canonicalizeBody(body)
            components.append(canonicalBody)
        }

        // 组合所有部分并计算 SHA256
        let combined = components.joined(separator: "|")
        let hash = sha256Hash(combined)

        return CacheKey(value: hash)
    }

    /// 从 URLRequest 生成缓存键
    public static func from(request: URLRequest) -> CacheKey {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? ""
        var components = [method.uppercased(), url]

        if let body = request.httpBody, !body.isEmpty {
            let canonicalBody = canonicalizeBody(body)
            components.append(canonicalBody)
        }

        let combined = components.joined(separator: "|")
        let hash = sha256Hash(combined)

        return CacheKey(value: hash)
    }

    // MARK: - 私有方法

    /// 规范化查询参数
    /// - 排序键名
    /// - URL 编码值
    /// - 递归处理嵌套结构
    private static func canonicalizeQueryParams(_ params: [String: Any]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? key
                let encodedValue = canonicalizeValue(value)
                    .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
    }

    /// 规范化任意值为字符串
    private static func canonicalizeValue(_ value: Any) -> String {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let items = array.map { canonicalizeValue($0) }
            return "[\(items.joined(separator: ","))]"
        case let dict as [String: Any]:
            let items = dict
                .sorted { $0.key < $1.key }
                .map { "\($0.key):\(canonicalizeValue($0.value))" }
            return "{\(items.joined(separator: ","))}"
        default:
            return String(describing: value)
        }
    }

    /// 规范化 Body 数据
    /// - 如果是 JSON，按 sortedKeys 重新序列化
    /// - 否则直接使用原始字节的 hex
    private static func canonicalizeBody(_ data: Data) -> String {
        // 尝试解析为 JSON 并重新序列化（sorted keys）
        if let json = try? JSONSerialization.jsonObject(with: data),
           let canonical = try? JSONSerialization.data(
               withJSONObject: json,
               options: [.sortedKeys, .withoutEscapingSlashes]
           ) {
            return canonical.base64EncodedString()
        }

        // 非 JSON 数据，直接用 SHA256
        return sha256Hash(data)
    }

    /// 计算 SHA256 哈希（返回 hex 字符串前 32 字符）
    private static func sha256Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        return sha256Hash(data)
    }

    /// 计算 SHA256 哈希（返回 hex 字符串前 32 字符）
    private static func sha256Hash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        // 取前 16 字节（32 个 hex 字符），足够避免碰撞
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
