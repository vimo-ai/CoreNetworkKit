//
//  DownloadError.swift
//  CoreNetworkKit
//
//  文件下载错误类型
//

import Foundation

/// 下载错误
public enum DownloadError: LocalizedError, Sendable {

    // MARK: - 网络错误

    /// 网络不可用
    case networkUnavailable

    /// 请求超时
    case timeout

    /// HTTP 错误
    case httpError(statusCode: Int, message: String?)

    /// 连接失败（存储错误描述以保证 Sendable）
    case connectionFailed(String)

    /// 重定向失败
    case redirectFailed(url: String)

    // MARK: - 文件错误

    /// 无效的 URL
    case invalidURL(String)

    /// 文件系统错误
    case fileSystemError(String)

    /// 磁盘空间不足
    case insufficientDiskSpace(required: Int64, available: Int64)

    /// 文件不存在
    case fileNotFound(String)

    /// 权限被拒绝
    case permissionDenied(String)

    // MARK: - 校验错误

    /// SHA256 校验失败
    case sha256Mismatch(expected: String, actual: String, fileName: String)

    /// 下载文件损坏
    case corruptedDownload(String)

    // MARK: - 安装错误

    /// 安装失败
    case installFailed(String)

    /// 解压失败
    case unzipFailed(String)

    // MARK: - 其他

    /// 已取消
    case cancelled

    /// 未知错误（存储错误描述以保证 Sendable）
    case unknown(String)

    // MARK: - 便捷构造

    /// 从 Error 创建连接失败错误
    public static func connectionFailed(_ error: Error) -> DownloadError {
        .connectionFailed(error.localizedDescription)
    }

    /// 从 Error 创建未知错误
    public static func unknown(_ error: Error) -> DownloadError {
        .unknown(error.localizedDescription)
    }

    // MARK: - LocalizedError

    public var errorDescription: String? {
        switch self {
        case .networkUnavailable:
            return "网络不可用，请检查网络连接"

        case .timeout:
            return "下载超时，请重试"

        case .httpError(let statusCode, let message):
            if let message = message, !message.isEmpty {
                return "HTTP 错误 (\(statusCode)): \(message)"
            }
            return "HTTP 错误 (\(statusCode))"

        case .connectionFailed(let message):
            return "连接失败: \(message)"

        case .redirectFailed(let url):
            return "重定向失败: \(url)"

        case .invalidURL(let url):
            return "无效的 URL: \(url)"

        case .fileSystemError(let reason):
            return "文件系统错误: \(reason)"

        case .insufficientDiskSpace(let required, let available):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            let requiredStr = formatter.string(fromByteCount: required)
            let availableStr = formatter.string(fromByteCount: available)
            return "磁盘空间不足（需要 \(requiredStr)，可用 \(availableStr)）"

        case .fileNotFound(let path):
            return "文件不存在: \(path)"

        case .permissionDenied(let path):
            return "权限被拒绝: \(path)"

        case .sha256Mismatch(let expected, let actual, let fileName):
            return "文件校验失败 (\(fileName))\n期望: \(expected.prefix(16))...\n实际: \(actual.prefix(16))..."

        case .corruptedDownload(let reason):
            return "下载文件已损坏: \(reason)"

        case .installFailed(let reason):
            return "安装失败: \(reason)"

        case .unzipFailed(let reason):
            return "解压失败: \(reason)"

        case .cancelled:
            return "下载已取消"

        case .unknown(let message):
            return "未知错误: \(message)"
        }
    }

    // MARK: - 辅助方法

    /// 是否可重试
    public var isRetryable: Bool {
        switch self {
        case .timeout, .connectionFailed, .networkUnavailable:
            return true
        case .httpError(let statusCode, _):
            // 5xx 服务器错误可重试，4xx 不可重试
            return statusCode >= 500
        default:
            return false
        }
    }
}
