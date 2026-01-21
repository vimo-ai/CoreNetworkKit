//
//  DownloadProgress.swift
//  CoreNetworkKit
//
//  下载进度模型
//

import Foundation

/// 下载进度信息
public struct DownloadProgress: Sendable {

    /// 文件名
    public let fileName: String

    /// 已下载字节数
    public let bytesDownloaded: Int64

    /// 总字节数（nil 表示未知大小）
    public let totalBytes: Int64?

    /// 下载速度（bytes/s）
    public let speed: Int64

    /// 预计剩余时间（秒）
    public let estimatedTimeRemaining: TimeInterval?

    /// 下载进度（0.0 - 1.0）
    public var fractionCompleted: Double {
        guard let total = totalBytes, total > 0 else { return 0 }
        return Double(bytesDownloaded) / Double(total)
    }

    /// 格式化的进度百分比
    public var percentageString: String {
        String(format: "%.1f%%", fractionCompleted * 100)
    }

    /// 格式化的下载速度
    public var formattedSpeed: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: speed) + "/s"
    }

    /// 格式化的已下载大小
    public var formattedDownloaded: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytesDownloaded)
    }

    /// 格式化的总大小
    public var formattedTotal: String? {
        guard let total = totalBytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    /// 格式化的剩余时间
    public var formattedTimeRemaining: String? {
        guard let eta = estimatedTimeRemaining, eta.isFinite, eta > 0 else { return nil }

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2

        return formatter.string(from: eta)
    }

    /// 是否为未知大小（进度不确定）
    public var isIndeterminate: Bool {
        totalBytes == nil || totalBytes == 0
    }

    public init(
        fileName: String,
        bytesDownloaded: Int64,
        totalBytes: Int64?,
        speed: Int64 = 0,
        estimatedTimeRemaining: TimeInterval? = nil
    ) {
        self.fileName = fileName
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
        self.speed = speed
        self.estimatedTimeRemaining = estimatedTimeRemaining
    }
}

// MARK: - 下载状态

/// 下载状态
public enum DownloadState: Sendable {
    /// 空闲
    case idle

    /// 连接中
    case connecting

    /// 下载中
    case downloading(DownloadProgress)

    /// 校验中
    case verifying

    /// 安装中
    case installing

    /// 已完成
    case completed

    /// 失败
    case failed(DownloadError)

    /// 已取消
    case cancelled

    /// 是否正在进行中
    public var isInProgress: Bool {
        switch self {
        case .connecting, .downloading, .verifying, .installing:
            return true
        default:
            return false
        }
    }

    /// 是否已结束（成功、失败或取消）
    public var isFinished: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        default:
            return false
        }
    }
}

// MARK: - 速度计算器

/// 下载速度计算器（滑动窗口平均）
public struct SpeedCalculator: Sendable {
    private var samples: [(timestamp: Date, bytes: Int64)]
    private let windowSize: Int
    private let windowDuration: TimeInterval

    public init(windowSize: Int = 5, windowDuration: TimeInterval = 2.0) {
        self.samples = []
        self.windowSize = windowSize
        self.windowDuration = windowDuration
    }

    /// 更新并返回当前速度（bytes/s）
    public mutating func update(bytesDownloaded: Int64) -> Int64 {
        let now = Date()
        samples.append((now, bytesDownloaded))

        // 清理过期样本
        let cutoff = now.addingTimeInterval(-windowDuration)
        samples = samples.filter { $0.timestamp > cutoff }

        // 保持窗口大小
        if samples.count > windowSize {
            samples.removeFirst(samples.count - windowSize)
        }

        // 计算速度
        guard samples.count >= 2,
              let first = samples.first,
              let last = samples.last else {
            return 0
        }

        let duration = last.timestamp.timeIntervalSince(first.timestamp)
        guard duration > 0 else { return 0 }

        let bytes = last.bytes - first.bytes
        return Int64(Double(bytes) / duration)
    }

    /// 计算预计剩余时间
    public func estimateTimeRemaining(downloaded: Int64, total: Int64?, speed: Int64) -> TimeInterval? {
        guard let total = total, speed > 0, total > downloaded else { return nil }
        let remaining = total - downloaded
        return Double(remaining) / Double(speed)
    }

    /// 重置计算器
    public mutating func reset() {
        samples.removeAll()
    }
}
