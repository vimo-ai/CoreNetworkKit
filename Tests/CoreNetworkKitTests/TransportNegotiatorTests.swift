import XCTest
import Connect
@testable import CoreNetworkKit

final class TransportNegotiatorTests: XCTestCase {

    // MARK: - Initial State

    func testStartsWithConnectRPC() {
        let negotiator = makeNegotiator()

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    // MARK: - Business Errors Do NOT Trigger Fallback

    func testHTTP400DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 400)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testHTTP401DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 401)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testHTTP403DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 403)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testHTTP404DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 404)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testHTTP500DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 500)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testHTTP503DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 503)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testServerErrorNetworkErrorDoesNotTriggerFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.serverError(statusCode: 422, message: "Validation failed")
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testDecodingFailedDoesNotTriggerFallback() {
        let decodingError = NSError(domain: "Decoding", code: 1, userInfo: nil)
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.decodingFailed(decodingError)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testAuthenticationFailedDoesNotTriggerFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.authenticationFailed
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testCancelledDoesNotTriggerFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.cancelled
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    // MARK: - Transport Errors DO Trigger Fallback

    func testNoNetworkTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testTimeoutTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.timeout
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testDNSLookupFailureTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.dnsLookupFailed)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testCannotFindHostTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.cannotFindHost)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testCannotConnectToHostTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.cannotConnectToHost)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testSecureConnectionFailedTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.secureConnectionFailed)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testNetworkConnectionLostTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.networkConnectionLost)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testNotConnectedToInternetTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.notConnectedToInternet)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testTimedOutURLErrorTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.timedOut)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testTLSCertificateUntrustedTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: URLError(.serverCertificateUntrusted)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testConnectionRefusedPOSIXTriggersFallback() {
        // ECONNREFUSED = 61
        let engine = MockNetworkEngine.failingWith(
            error: NSError(domain: NSPOSIXErrorDomain, code: 61, userInfo: nil)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testConnectionResetPOSIXTriggersFallback() {
        // ECONNRESET = 54
        let engine = MockNetworkEngine.failingWith(
            error: NSError(domain: NSPOSIXErrorDomain, code: 54, userInfo: nil)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testSSLHandshakeFailureTriggersFallback() {
        // errSSLHandshakeFail = -9806
        let engine = MockNetworkEngine.failingWith(
            error: NSError(domain: NSOSStatusErrorDomain, code: -9806, userInfo: nil)
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    func testWrappedURLErrorInNetworkErrorTriggersFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.unknown(URLError(.cannotConnectToHost))
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    // MARK: - Once Fallen Back, Subsequent Requests Use WebSocket

    func testSubsequentRequestsRemainInFallback() {
        // First request: transport failure
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback, "Should be in fallback after transport error")

        // The state persists across calls
        XCTAssertEqual(negotiator.state, .webSocketFallback)
        XCTAssertTrue(negotiator.isUsingFallback)

        // Even after another request, state remains
        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback, "Should remain in fallback")
    }

    func testSuccessfulRequestAfterFallbackDoesNotResetState() {
        // Start with a transport failure
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback)

        // Even if the engine starts succeeding, the state stays degraded
        // (session-level fallback)
        engine.behavior = .success(
            Data(),
            HTTPURLResponse(
                url: URL(string: "https://api.example.com")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
        )

        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback, "Fallback persists for the session")
    }

    // MARK: - Reset

    func testResetGoesBackToConnectRPC() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback)

        negotiator.reset()

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testResetWhenAlreadyConnectRPCIsNoOp() {
        let negotiator = makeNegotiator()

        negotiator.reset()

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    func testResetThenTransportFailureTriggersNewFallback() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        let negotiator = makeNegotiator(engine: engine)

        // First fallback
        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback)

        // Reset
        negotiator.reset()
        XCTAssertFalse(negotiator.isUsingFallback)

        // Trigger fallback again
        performUnary(negotiator)
        XCTAssertTrue(negotiator.isUsingFallback)
    }

    // MARK: - Fallback Callback

    func testFallbackCallbackInvokedOnTransportFailure() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        var callbackInvoked = false
        var callbackError: Error?

        let negotiator = makeNegotiator(engine: engine) { error in
            callbackInvoked = true
            callbackError = error
        }

        performUnary(negotiator)

        XCTAssertTrue(callbackInvoked, "Fallback callback should be invoked")
        XCTAssertNotNil(callbackError)
    }

    func testFallbackCallbackNotInvokedOnBusinessError() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 404)
        var callbackInvoked = false

        let negotiator = makeNegotiator(engine: engine) { _ in
            callbackInvoked = true
        }

        performUnary(negotiator)

        XCTAssertFalse(callbackInvoked, "Fallback callback should not be invoked for business errors")
    }

    func testFallbackCallbackInvokedOnlyOnce() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        var callbackCount = 0

        let negotiator = makeNegotiator(engine: engine) { _ in
            callbackCount += 1
        }

        // Multiple failures
        performUnary(negotiator)
        performUnary(negotiator)
        performUnary(negotiator)

        XCTAssertEqual(callbackCount, 1, "Fallback callback should only fire once per session")
    }

    func testFallbackCallbackFiresAgainAfterReset() {
        let engine = MockNetworkEngine.failingWith(
            error: NetworkError.noNetwork
        )
        var callbackCount = 0

        let negotiator = makeNegotiator(engine: engine) { _ in
            callbackCount += 1
        }

        performUnary(negotiator)
        XCTAssertEqual(callbackCount, 1)

        negotiator.reset()

        performUnary(negotiator)
        XCTAssertEqual(callbackCount, 2, "Callback should fire again after reset")
    }

    // MARK: - Successful Requests Do NOT Trigger Fallback

    func testHTTP200DoesNotTriggerFallback() {
        let engine = MockNetworkEngine.successWith(data: Data(), statusCode: 200)
        let negotiator = makeNegotiator(engine: engine)

        performUnary(negotiator)

        XCTAssertEqual(negotiator.state, .connectRPC)
        XCTAssertFalse(negotiator.isUsingFallback)
    }

    // MARK: - TransportFailureClassifier — Content-Type Detection

    func testGarbledContentTypeDetected() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "text/html"]
        )

        XCTAssertTrue(
            TransportFailureClassifier.hasGarbledContentType(response),
            "text/html on an API response indicates middlebox interference"
        )
    }

    func testValidContentTypeNotDetectedAsGarbled() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )

        XCTAssertFalse(
            TransportFailureClassifier.hasGarbledContentType(response),
            "application/json is a valid API content-type"
        )
    }

    func testProtoContentTypeNotDetectedAsGarbled() {
        let response = HTTPURLResponse(
            url: URL(string: "https://api.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/proto"]
        )

        XCTAssertFalse(
            TransportFailureClassifier.hasGarbledContentType(response),
            "application/proto is a valid ConnectRPC content-type"
        )
    }

    func testNilResponseNotDetectedAsGarbled() {
        XCTAssertFalse(
            TransportFailureClassifier.hasGarbledContentType(nil),
            "nil response should not be flagged"
        )
    }

    // MARK: - TransportFailureClassifier — Direct Tests

    func testClassifierRecognizesNoNetwork() {
        XCTAssertTrue(TransportFailureClassifier.isTransportFailure(NetworkError.noNetwork))
    }

    func testClassifierRecognizesTimeout() {
        XCTAssertTrue(TransportFailureClassifier.isTransportFailure(NetworkError.timeout))
    }

    func testClassifierRejectsServerError() {
        XCTAssertFalse(
            TransportFailureClassifier.isTransportFailure(
                NetworkError.serverError(statusCode: 500, message: nil)
            )
        )
    }

    func testClassifierRejectsDecodingError() {
        let err = NSError(domain: "test", code: 1, userInfo: nil)
        XCTAssertFalse(
            TransportFailureClassifier.isTransportFailure(NetworkError.decodingFailed(err))
        )
    }

    func testClassifierRejectsCancelled() {
        XCTAssertFalse(TransportFailureClassifier.isTransportFailure(NetworkError.cancelled))
    }

    func testClassifierRejectsAuthenticationFailed() {
        XCTAssertFalse(TransportFailureClassifier.isTransportFailure(NetworkError.authenticationFailed))
    }

    func testClassifierRecognizesURLErrorDNS() {
        XCTAssertTrue(TransportFailureClassifier.isTransportFailure(URLError(.dnsLookupFailed)))
    }

    func testClassifierRecognizesURLErrorTLS() {
        XCTAssertTrue(TransportFailureClassifier.isTransportFailure(URLError(.secureConnectionFailed)))
    }

    func testClassifierRecognizesPOSIXConnectionRefused() {
        let err = NSError(domain: NSPOSIXErrorDomain, code: 61, userInfo: nil)
        XCTAssertTrue(TransportFailureClassifier.isTransportFailure(err))
    }

    func testClassifierRecognizesSSLHandshakeFail() {
        let err = NSError(domain: NSOSStatusErrorDomain, code: -9806, userInfo: nil)
        XCTAssertTrue(TransportFailureClassifier.isTransportFailure(err))
    }

    func testClassifierRejectsGenericNSError() {
        let err = NSError(domain: "com.example.app", code: 42, userInfo: nil)
        XCTAssertFalse(TransportFailureClassifier.isTransportFailure(err))
    }
}

// MARK: - Test Helpers

extension TransportNegotiatorTests {

    /// Create a negotiator with a mock engine for testing.
    ///
    /// The negotiator wraps the engine in a `MonitoringNetworkEngine` internally,
    /// so errors are intercepted at the raw level (before ConnectTransport wraps
    /// them into ConnectError).
    private func makeNegotiator(
        engine: MockNetworkEngine = MockNetworkEngine.successWith(data: Data(), statusCode: 200),
        onFallback: TransportNegotiator.FallbackHandler? = nil
    ) -> TransportNegotiator {
        return TransportNegotiator(
            engine: engine,
            tokenStorage: StubTokenStorage(),
            onFallback: onFallback
        )
    }

    /// Fire a unary request and wait for the response.
    private func performUnary(_ negotiator: TransportNegotiator) {
        let expectation = expectation(description: "unary")

        let request = HTTPRequest(
            url: URL(string: "https://api.example.com/test")!,
            headers: [:],
            message: nil,
            method: .post,
            trailers: nil,
            idempotencyLevel: .unknown
        )

        negotiator.unary(request: request, onMetrics: { _ in }) { _ in
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 5)
    }
}

// MARK: - Test Doubles

private final class StubTokenStorage: TokenStorage {
    func getToken() async -> String? {
        return "test-token"
    }
}
