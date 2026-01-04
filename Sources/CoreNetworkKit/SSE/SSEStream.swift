import Foundation

/// SSE 事件流
///
/// 封装原始数据流，自动解析为 SSE 事件
///
/// 使用示例：
/// ```swift
/// let stream = client.stream(ChatRequest(message: "Hello"))
/// for try await event in stream {
///     print(event.data)
/// }
/// ```
public struct SSEStream: AsyncSequence {
    public typealias Element = SSEEvent

    private let dataStream: AsyncThrowingStream<Data, Error>

    public init(dataStream: AsyncThrowingStream<Data, Error>) {
        self.dataStream = dataStream
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(dataStream: dataStream)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var dataIterator: AsyncThrowingStream<Data, Error>.AsyncIterator
        private let parser = SSEParser()
        private var pendingEvents: [SSEEvent] = []

        init(dataStream: AsyncThrowingStream<Data, Error>) {
            self.dataIterator = dataStream.makeAsyncIterator()
        }

        public mutating func next() async throws -> SSEEvent? {
            // 先返回缓存的事件
            if !pendingEvents.isEmpty {
                return pendingEvents.removeFirst()
            }

            // 从数据流获取更多数据
            while let chunk = try await dataIterator.next() {
                let events = parser.parse(chunk)
                if !events.isEmpty {
                    pendingEvents = Array(events.dropFirst())
                    return events.first
                }
            }

            return nil
        }
    }
}

// MARK: - Typed SSE Stream

/// 带类型的 SSE 事件流
///
/// 自动将 SSE data 解码为指定类型
///
/// 使用示例：
/// ```swift
/// let stream: TypedSSEStream<ChatResponse> = client.stream(ChatRequest(message: "Hello"))
/// for try await response in stream {
///     print(response.text)
/// }
/// ```
public struct TypedSSEStream<T: Decodable>: AsyncSequence {
    public typealias Element = T

    private let sseStream: SSEStream
    private let decoder: JSONDecoder

    public init(dataStream: AsyncThrowingStream<Data, Error>, decoder: JSONDecoder = JSONDecoder()) {
        self.sseStream = SSEStream(dataStream: dataStream)
        self.decoder = decoder
    }

    public func makeAsyncIterator() -> AsyncIterator {
        return AsyncIterator(sseIterator: sseStream.makeAsyncIterator(), decoder: decoder)
    }

    public struct AsyncIterator: AsyncIteratorProtocol {
        private var sseIterator: SSEStream.AsyncIterator
        private let decoder: JSONDecoder

        init(sseIterator: SSEStream.AsyncIterator, decoder: JSONDecoder) {
            self.sseIterator = sseIterator
            self.decoder = decoder
        }

        public mutating func next() async throws -> T? {
            while let event = try await sseIterator.next() {
                // 跳过空数据
                guard !event.data.isEmpty else { continue }

                // 跳过 [DONE] 标记（OpenAI 风格）
                if event.data == "[DONE]" {
                    return nil
                }

                // 解码数据
                return try event.decode(T.self, decoder: decoder)
            }
            return nil
        }
    }
}
