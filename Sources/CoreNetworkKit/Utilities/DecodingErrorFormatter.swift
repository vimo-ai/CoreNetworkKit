import Foundation

/// 解码错误详细格式化工具
public enum DecodingErrorFormatter {

    /// 格式化解码错误为可读的详细信息
    public static func format(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, let context):
            return formatKeyNotFound(key: key, context: context)

        case .valueNotFound(let type, let context):
            return formatValueNotFound(type: type, context: context)

        case .typeMismatch(let type, let context):
            return formatTypeMismatch(type: type, context: context)

        case .dataCorrupted(let context):
            return formatDataCorrupted(context: context)

        @unknown default:
            return "未知解码错误: \(error.localizedDescription)"
        }
    }

    // MARK: - 私有格式化方法

    private static func formatKeyNotFound(key: CodingKey, context: DecodingError.Context) -> String {
        var output = "❌ 解码失败:\n"
        output += "键未找到: \(key.stringValue)\n"
        output += "路径: \(formatPath(context.codingPath))\n"
        output += "描述: \(context.debugDescription)\n"

        if let underlyingError = context.underlyingError {
            output += "底层错误: \(underlyingError.localizedDescription)\n"
        }

        return output
    }

    private static func formatValueNotFound(type: Any.Type, context: DecodingError.Context) -> String {
        var output = "❌ 解码失败:\n"
        output += "值未找到,期望类型: \(type)\n"
        output += "路径: \(formatPath(context.codingPath))\n"
        output += "描述: \(context.debugDescription)\n"

        if let underlyingError = context.underlyingError {
            output += "底层错误: \(underlyingError.localizedDescription)\n"
        }

        return output
    }

    private static func formatTypeMismatch(type: Any.Type, context: DecodingError.Context) -> String {
        var output = "❌ 解码失败:\n"
        output += "类型不匹配,期望类型: \(type)\n"
        output += "路径: \(formatPath(context.codingPath))\n"
        output += "描述: \(context.debugDescription)\n"

        if let underlyingError = context.underlyingError {
            output += "底层错误: \(underlyingError.localizedDescription)\n"
        }

        return output
    }

    private static func formatDataCorrupted(context: DecodingError.Context) -> String {
        var output = "❌ 解码失败:\n"
        output += "数据损坏\n"
        output += "路径: \(formatPath(context.codingPath))\n"
        output += "描述: \(context.debugDescription)\n"

        if let underlyingError = context.underlyingError {
            output += "底层错误: \(underlyingError.localizedDescription)\n"
        }

        return output
    }

    /// 格式化 CodingPath 为易读的路径字符串
    private static func formatPath(_ path: [CodingKey]) -> String {
        if path.isEmpty {
            return "根路径"
        }

        return path.map { key in
            if let intValue = key.intValue {
                return "[\(intValue)]"
            } else {
                return key.stringValue
            }
        }.joined(separator: " -> ")
    }
}
