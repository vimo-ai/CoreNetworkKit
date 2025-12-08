import Foundation

/// 为 `DecodingError` 提供更具可读性的错误描述，极大提升了 `Codable` 的调试体验。
///
/// 当解码失败时，此扩展将默认的、冗长的错误信息转换为清晰、准确的描述，
/// 指出是哪个键（`key`）、因为什么原因（`context`）在哪个路径（`path`）下解码失败。
public extension DecodingError {

    /// 一个计算属性，生成关于解码错误的详细、人类可读的描述。
    var detailedDescription: String {
        var description = "❌ [DecodingError] "

        switch self {
        case .typeMismatch(let type, let context):
            description += "Type mismatch for key '\(context.codingPath.lastKey ?? "N/A")'. Expected type '\(type)' but found a different type."
            description += "\n  - Path: \(context.codingPath.fullPath)"
            description += "\n  - Context: \(context.debugDescription)"

        case .valueNotFound(let type, let context):
            description += "Value not found for key '\(context.codingPath.lastKey ?? "N/A")'. Expected a value of type '\(type)' but found nil."
            description += "\n  - Path: \(context.codingPath.fullPath)"
            description += "\n  - Context: \(context.debugDescription)"

        case .keyNotFound(let key, let context):
            description += "Key not found: '\(key.stringValue)'."
            description += "\n  - Path: \(context.codingPath.fullPath)"
            description += "\n  - Context: \(context.debugDescription)"

        case .dataCorrupted(let context):
            description += "Data corrupted."
            description += "\n  - Path: \(context.codingPath.fullPath)"
            description += "\n  - Context: \(context.debugDescription)"

        @unknown default:
            return "An unknown decoding error occurred."
        }

        return description
    }

    /// 提供人类可读的解码错误描述
    var humanReadableDescription: String {
        switch self {
        case .typeMismatch(let type, let context):
            return "类型不匹配 '\(type)' 路径: \(context.codingPath.prettyPath). 原因: \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            return "值未找到 '\(type)' 路径: \(context.codingPath.prettyPath). 原因: \(context.debugDescription)"
        case .keyNotFound(let key, let context):
            return "键未找到: '\(key.stringValue)' 路径: \(context.codingPath.prettyPath). 原因: \(context.debugDescription)"
        case .dataCorrupted(let context):
            return "数据损坏 路径: \(context.codingPath.prettyPath). 原因: \(context.debugDescription)"
        @unknown default:
            return "发生未知解码错误. \(self.localizedDescription)"
        }
    }
}

// MARK: - CodingPath Helpers

internal extension Array where Element == CodingKey {
    /// 将 `CodingKey` 路径数组转换为点分隔的字符串路径，例如 "user.profile.name"。
    var fullPath: String {
        if isEmpty { return "root" }
        return self.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            }
            return key.stringValue
        }.joined(separator: ".")
    }

    /// 获取路径中的最后一个键名。
    var lastKey: String? {
        self.last?.stringValue
    }

    /// 将路径数组转换为箭头分隔的可读字符串
    var prettyPath: String {
        if isEmpty { return "根路径" }
        return self.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            }
            return key.stringValue
        }.joined(separator: " -> ")
    }
}
