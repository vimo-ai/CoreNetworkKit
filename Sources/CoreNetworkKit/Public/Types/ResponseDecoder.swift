import Foundation

public protocol ResponseDecoder: Sendable {
    func decode<T: Decodable>(_ type: T.Type, from data: Data, using decoder: JSONDecoder) throws -> T
}

public struct DirectDecoder: ResponseDecoder, Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data, using decoder: JSONDecoder) throws -> T {
        try decoder.decode(type, from: data)
    }
}

public struct EnvelopeDecoder: ResponseDecoder, Sendable {
    public init() {}

    public func decode<T: Decodable>(_ type: T.Type, from data: Data, using decoder: JSONDecoder) throws -> T {
        let envelope = try decoder.decode(Envelope<T>.self, from: data)
        guard envelope.success else {
            throw BusinessErrorV2(
                message: envelope.message ?? "Request failed",
                timestamp: envelope.timestamp ?? ""
            )
        }
        guard let innerData = envelope.data else {
            if let empty = EmptyResponse() as? T {
                return empty
            }
            throw BusinessErrorV2(
                message: envelope.message ?? "No data in response",
                timestamp: envelope.timestamp ?? ""
            )
        }
        return innerData
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let message: String?
    let timestamp: String?
}
