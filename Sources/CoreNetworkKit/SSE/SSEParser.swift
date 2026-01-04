import Foundation

/// SSE 解析器
///
/// 将原始数据流解析为 SSE 事件流
///
/// SSE 格式示例：
/// ```
/// event: message
/// data: {"key": "value"}
/// id: 123
///
/// data: another message
///
/// ```
public final class SSEParser: @unchecked Sendable {
    private var buffer = ""
    private let lock = NSLock()

    public init() {}

    /// 解析数据块，返回完整的事件列表
    /// - Parameter chunk: 新接收的数据块
    /// - Returns: 解析出的完整事件（可能为空）
    public func parse(_ chunk: Data) -> [SSEEvent] {
        guard let text = String(data: chunk, encoding: .utf8) else {
            return []
        }

        lock.lock()
        defer { lock.unlock() }

        buffer.append(text)

        var events: [SSEEvent] = []

        // SSE 事件以双换行分隔
        while let range = buffer.range(of: "\n\n") {
            let eventText = String(buffer[..<range.lowerBound])
            buffer.removeSubrange(..<range.upperBound)

            if let event = parseEvent(eventText) {
                events.append(event)
            }
        }

        return events
    }

    /// 重置解析器状态
    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        buffer = ""
    }

    // MARK: - Private

    private func parseEvent(_ text: String) -> SSEEvent? {
        var event = "message"
        var dataLines: [String] = []
        var id: String?
        var retry: Int?

        let lines = text.components(separatedBy: "\n")

        for line in lines {
            // 忽略注释（以 : 开头）
            if line.hasPrefix(":") {
                continue
            }

            // 空行跳过
            if line.isEmpty {
                continue
            }

            // 解析字段
            if let colonIndex = line.firstIndex(of: ":") {
                let field = String(line[..<colonIndex])
                var value = String(line[line.index(after: colonIndex)...])

                // 去掉值开头的空格（如果有）
                if value.hasPrefix(" ") {
                    value.removeFirst()
                }

                switch field {
                case "event":
                    event = value
                case "data":
                    dataLines.append(value)
                case "id":
                    id = value
                case "retry":
                    retry = Int(value)
                default:
                    // 忽略未知字段
                    break
                }
            } else {
                // 没有冒号的行，整行作为字段名，值为空
                // 例如 "data" 等同于 "data:"
                switch line {
                case "data":
                    dataLines.append("")
                default:
                    break
                }
            }
        }

        // 如果没有 data，返回 nil
        guard !dataLines.isEmpty else {
            return nil
        }

        // 多行 data 用换行连接
        let data = dataLines.joined(separator: "\n")

        return SSEEvent(event: event, data: data, id: id, retry: retry)
    }
}
