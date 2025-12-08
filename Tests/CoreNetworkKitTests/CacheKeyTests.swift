import XCTest
@testable import CoreNetworkKit

final class CacheKeyTests: XCTestCase {

    // MARK: - 稳定性测试

    /// 相同参数多次构造应产生相同的 key
    func testSameParamsProduceSameKey() {
        let baseURL = URL(string: "https://api.example.com")!
        let query: [String: Any] = ["page": 1, "limit": 10]
        let body = try! JSONEncoder().encode(["name": "test"])

        let key1 = CacheKey.from(
            method: "POST",
            baseURL: baseURL,
            path: "/users",
            query: query,
            body: body
        )

        let key2 = CacheKey.from(
            method: "POST",
            baseURL: baseURL,
            path: "/users",
            query: query,
            body: body
        )

        XCTAssertEqual(key1, key2, "相同参数应产生相同的 CacheKey")
        XCTAssertEqual(key1.value, key2.value, "相同参数应产生相同的 hash 值")
    }

    /// 不同参数应产生不同的 key
    func testDifferentParamsProduceDifferentKey() {
        let baseURL = URL(string: "https://api.example.com")!

        let key1 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/users",
            query: ["page": 1],
            body: nil
        )

        let key2 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/users",
            query: ["page": 2],
            body: nil
        )

        XCTAssertNotEqual(key1, key2, "不同参数应产生不同的 CacheKey")
    }

    // MARK: - 顺序无关性测试

    /// Query 参数顺序不同应产生相同的 key
    func testQueryParamOrderDoesNotAffectKey() {
        let baseURL = URL(string: "https://api.example.com")!

        let key1 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/search",
            query: ["a": 1, "b": 2, "c": 3],
            body: nil
        )

        let key2 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/search",
            query: ["c": 3, "a": 1, "b": 2],
            body: nil
        )

        XCTAssertEqual(key1, key2, "Query 参数顺序不应影响 CacheKey")
    }

    /// JSON body 字段顺序不同应产生相同的 key
    func testJsonBodyFieldOrderDoesNotAffectKey() {
        let baseURL = URL(string: "https://api.example.com")!

        // 构造字段顺序不同的 JSON
        let json1 = """
        {"name": "test", "age": 30, "city": "NYC"}
        """.data(using: .utf8)!

        let json2 = """
        {"city": "NYC", "age": 30, "name": "test"}
        """.data(using: .utf8)!

        let key1 = CacheKey.from(
            method: "POST",
            baseURL: baseURL,
            path: "/users",
            query: nil,
            body: json1
        )

        let key2 = CacheKey.from(
            method: "POST",
            baseURL: baseURL,
            path: "/users",
            query: nil,
            body: json2
        )

        XCTAssertEqual(key1, key2, "JSON 字段顺序不应影响 CacheKey")
    }

    // MARK: - 边界测试

    /// Method 大小写不敏感
    func testMethodCaseInsensitive() {
        let baseURL = URL(string: "https://api.example.com")!

        let key1 = CacheKey.from(method: "get", baseURL: baseURL, path: "/test", query: nil, body: nil)
        let key2 = CacheKey.from(method: "GET", baseURL: baseURL, path: "/test", query: nil, body: nil)
        let key3 = CacheKey.from(method: "Get", baseURL: baseURL, path: "/test", query: nil, body: nil)

        XCTAssertEqual(key1, key2)
        XCTAssertEqual(key2, key3)
    }

    /// 空 body 和 nil body 应产生相同的 key
    func testNilAndEmptyBodyProduceSameKey() {
        let baseURL = URL(string: "https://api.example.com")!

        let key1 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/test",
            query: nil,
            body: nil
        )

        let key2 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/test",
            query: nil,
            body: Data()
        )

        XCTAssertEqual(key1, key2, "nil body 和空 body 应产生相同的 key")
    }

    /// 嵌套 query 参数测试
    func testNestedQueryParams() {
        let baseURL = URL(string: "https://api.example.com")!

        let key1 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/search",
            query: ["filter": ["status": "active", "type": "user"]],
            body: nil
        )

        let key2 = CacheKey.from(
            method: "GET",
            baseURL: baseURL,
            path: "/search",
            query: ["filter": ["type": "user", "status": "active"]],
            body: nil
        )

        XCTAssertEqual(key1, key2, "嵌套 query 参数顺序不应影响 CacheKey")
    }

    // MARK: - URLRequest 构造测试

    func testFromURLRequest() {
        var request = URLRequest(url: URL(string: "https://api.example.com/users")!)
        request.httpMethod = "POST"
        request.httpBody = """
        {"name": "test"}
        """.data(using: .utf8)

        let key1 = CacheKey.from(request: request)
        let key2 = CacheKey.from(request: request)

        XCTAssertEqual(key1, key2)
        XCTAssertFalse(key1.value.isEmpty)
    }

    // MARK: - Hash 长度测试

    func testHashLength() {
        let baseURL = URL(string: "https://api.example.com")!
        let key = CacheKey.from(method: "GET", baseURL: baseURL, path: "/test", query: nil, body: nil)

        // SHA256 前 16 字节 = 32 个 hex 字符
        XCTAssertEqual(key.value.count, 32, "Hash 应为 32 个字符")
    }
}
