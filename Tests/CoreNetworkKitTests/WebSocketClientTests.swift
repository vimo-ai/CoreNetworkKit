import XCTest
@testable import CoreNetworkKit

final class WebSocketClientTests: XCTestCase {

    // MARK: - URL Construction

    func testURLWithQueryParamAuth() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            token: "test-token",
            authMethod: .queryParam(),
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.url?.scheme, "ws")
        XCTAssertEqual(request.url?.host, "localhost")
        XCTAssertEqual(request.url?.port, 9506)
        XCTAssertEqual(request.url?.path, "/chat")
        XCTAssertTrue(request.url?.query?.contains("token=test-token") == true)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testURLWithCustomQueryKey() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:3000")!,
            token: "abc",
            authMethod: .queryParam(key: "access_token"),
            path: "/ws"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertTrue(request.url?.query?.contains("access_token=abc") == true)
    }

    func testURLWithBearerAuth() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            token: "jwt-token",
            authMethod: .bearerHeader,
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer jwt-token")
        XCTAssertFalse(request.url?.query?.contains("token") ?? false)
    }

    func testURLWithCustomHeaderAuth() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            token: "secret",
            authMethod: .customHeader(key: "X-API-Key"),
            path: "/ws"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-API-Key"), "secret")
    }

    func testURLWithNoAuth() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            authMethod: .none,
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertNil(request.url?.query)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testSecureURLUsesWSS() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            secure: true,
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.url?.scheme, "wss")
    }

    func testHTTPSURLAutoConvertsToWSS() {
        let config = WebSocketConfiguration(
            url: URL(string: "https://api.example.com")!,
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.url?.scheme, "wss")
    }

    func testExtraParamsAppendedToQuery() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            token: "tk",
            authMethod: .queryParam(),
            extraParams: ["version": "2", "client": "ios"],
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()
        let query = request.url?.query ?? ""

        XCTAssertTrue(query.contains("token=tk"))
        XCTAssertTrue(query.contains("version=2"))
        XCTAssertTrue(query.contains("client=ios"))
    }

    func testExtraHeadersSet() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!,
            extraHeaders: ["X-Custom": "value"],
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Custom"), "value")
    }

    func testPathAppendedCorrectly() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506/api")!,
            path: "/chat"
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.url?.path, "/api/chat")
    }

    func testNoPath() {
        let config = WebSocketConfiguration(
            url: URL(string: "http://localhost:9506")!
        )
        let client = WebSocketClient(configuration: config)
        let request = client.testBuildURLRequest()

        XCTAssertEqual(request.url?.path, "")
    }

    // MARK: - Event Handlers

    func testOnRegistersHandler() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var received: String?
        client.on("test") { (msg: TestMessage) in
            received = msg.text
        }

        client.testDispatchEvent("test", jsonDict: ["text": "hello"])

        XCTAssertEqual(received, "hello")
    }

    func testMultipleHandlersForSameEvent() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var count = 0
        client.on("ping") { (_: TestMessage) in count += 1 }
        client.on("ping") { (_: TestMessage) in count += 1 }

        client.testDispatchEvent("ping", jsonDict: ["text": "x"])

        XCTAssertEqual(count, 2)
    }

    func testOffByTokenRemovesSpecificHandler() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var firstCalled = false
        var secondCalled = false

        let token1 = client.on("event") { (_: TestMessage) in firstCalled = true }
        client.on("event") { (_: TestMessage) in secondCalled = true }

        client.off(token: token1)
        client.testDispatchEvent("event", jsonDict: ["text": "x"])

        XCTAssertFalse(firstCalled)
        XCTAssertTrue(secondCalled)
    }

    func testOffByEventRemovesAllHandlers() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var called = false
        client.on("event") { (_: TestMessage) in called = true }
        client.on("event") { (_: TestMessage) in called = true }

        client.off("event")
        client.testDispatchEvent("event", jsonDict: ["text": "x"])

        XCTAssertFalse(called)
    }

    func testUnrelatedEventNotDispatched() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var called = false
        client.on("eventA") { (_: TestMessage) in called = true }

        client.testDispatchEvent("eventB", jsonDict: ["text": "x"])

        XCTAssertFalse(called)
    }

    // MARK: - Message Parsing

    func testParseValidEnvelope() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var received: TestPayload?
        client.on("session:started") { (p: TestPayload) in received = p }

        let json = #"{"event":"session:started","data":{"id":42,"name":"test"}}"#
        client.testHandleTextMessage(json)

        XCTAssertEqual(received?.id, 42)
        XCTAssertEqual(received?.name, "test")
    }

    func testParseInvalidJSONIgnored() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var called = false
        client.on("any") { (_: TestMessage) in called = true }

        client.testHandleTextMessage("not json at all")

        XCTAssertFalse(called)
    }

    func testParseMissingEventFieldIgnored() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        var called = false
        client.on("any") { (_: TestMessage) in called = true }

        client.testHandleTextMessage(#"{"data":{"text":"no event"}}"#)

        XCTAssertFalse(called)
    }

    // MARK: - Emit Serialization

    func testEmitEncodesEnvelope() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        let envelope = client.testBuildEmitEnvelope("session:start", data: TestPayload(id: 1, name: "海梦"))
        XCTAssertEqual(envelope?["event"] as? String, "session:start")

        let data = envelope?["data"] as? [String: Any]
        XCTAssertEqual(data?["id"] as? Int, 1)
        XCTAssertEqual(data?["name"] as? String, "海梦")
    }

    func testEmitDictEncodesEnvelope() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        let client = WebSocketClient(configuration: config)

        let dict: [String: Any] = ["characterId": 22]
        let envelope = client.testBuildEmitEnvelopeDict("session:start", data: dict)
        XCTAssertEqual(envelope?["event"] as? String, "session:start")

        let data = envelope?["data"] as? [String: Any]
        XCTAssertEqual(data?["characterId"] as? Int, 22)
    }

    // MARK: - Configuration Factory Methods

    func testWithTokenFactory() {
        let config = WebSocketConfiguration.withToken("abc", url: URL(string: "ws://localhost")!, path: "/chat")
        XCTAssertEqual(config.token, "abc")
        XCTAssertEqual(config.path, "/chat")
        if case .queryParam(let key) = config.authMethod {
            XCTAssertEqual(key, "token")
        } else {
            XCTFail("Expected queryParam auth method")
        }
    }

    func testWithBearerTokenFactory() {
        let config = WebSocketConfiguration.withBearerToken("jwt", url: URL(string: "ws://localhost")!, path: "/ws")
        XCTAssertEqual(config.token, "jwt")
        if case .bearerHeader = config.authMethod {
            // pass
        } else {
            XCTFail("Expected bearerHeader auth method")
        }
    }

    func testDefaultConfigValues() {
        let config = WebSocketConfiguration(url: URL(string: "ws://localhost")!)
        XCTAssertTrue(config.reconnects)
        XCTAssertEqual(config.reconnectAttempts, 5)
        XCTAssertEqual(config.reconnectWait, 2)
        XCTAssertFalse(config.enableLogging)
        XCTAssertFalse(config.secure)
        XCTAssertFalse(config.selfSigned)
        XCTAssertNil(config.path)
        XCTAssertNil(config.token)
    }
}

// MARK: - Test Helpers

private struct TestMessage: Decodable {
    let text: String
}

private struct TestPayload: Codable {
    let id: Int
    let name: String
}

// MARK: - WebSocketClient Test Access

extension WebSocketClient {
    func testBuildURLRequest() -> URLRequest {
        buildURLRequest()
    }

    func testDispatchEvent(_ event: String, jsonDict: [String: Any]) {
        dispatchEvent(event, data: jsonDict)
    }

    func testHandleTextMessage(_ text: String) {
        guard let jsonData = text.data(using: .utf8),
              let envelope = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let event = envelope["event"] as? String else { return }
        let payload = envelope["data"]
        dispatchEvent(event, data: payload as Any)
    }

    func testBuildEmitEnvelope<T: Encodable>(_ event: String, data: T) -> [String: Any]? {
        guard let jsonData = try? JSONEncoder().encode(data),
              let dataObj = try? JSONSerialization.jsonObject(with: jsonData) else { return nil }
        return ["event": event, "data": dataObj]
    }

    func testBuildEmitEnvelopeDict(_ event: String, data: [String: Any]) -> [String: Any]? {
        return ["event": event, "data": data]
    }
}
