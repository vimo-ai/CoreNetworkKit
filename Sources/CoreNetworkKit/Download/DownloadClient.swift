//
//  DownloadClient.swift
//  CoreNetworkKit
//
//  文件下载客户端 - 基于 Alamofire，支持断点续传、进度回调、SHA256 校验
//

import Foundation
import Alamofire
import CryptoKit
import MLoggerKit

/// 下载任务句柄，用于取消和监控
public final class DownloadTask: @unchecked Sendable {
    private var request: DownloadRequest?
    private let url: URL
    private weak var client: DownloadClient?

    internal init(url: URL, client: DownloadClient) {
        self.url = url
        self.client = client
    }

    internal func setRequest(_ request: DownloadRequest) {
        self.request = request
    }

    /// 取消下载（自动保存断点数据）
    public func cancel() {
        request?.cancel(producingResumeData: true)
    }

    /// 是否正在下载
    public var isDownloading: Bool {
        guard let request = request else { return false }
        return !request.isCancelled && !request.isFinished
    }
}

/// 文件下载客户端
public final class DownloadClient: @unchecked Sendable {

    // MARK: - Properties

    private let session: Session
    private let logger = LoggerFactory.network
    private let fileManager = FileManager.default

    /// 断点续传数据缓存（URL -> resumeData）
    private var resumeDataCache: [URL: Data] = [:]
    private let cacheLock = NSLock()

    /// 进行中的下载任务
    private var activeTasks: [URL: DownloadTask] = [:]
    private let tasksLock = NSLock()

    /// 默认配置
    public struct Configuration: Sendable {
        /// 请求超时（秒）
        public var requestTimeout: TimeInterval

        /// 资源超时（秒），用于大文件下载
        public var resourceTimeout: TimeInterval

        /// 最大重试次数
        public var maxRetries: Int

        /// 重试基础延迟（秒）
        public var retryBaseDelay: TimeInterval

        /// 进度更新间隔（秒）
        public var progressUpdateInterval: TimeInterval

        public init(
            requestTimeout: TimeInterval = 30,
            resourceTimeout: TimeInterval = 600,
            maxRetries: Int = 3,
            retryBaseDelay: TimeInterval = 1.0,
            progressUpdateInterval: TimeInterval = 0.1
        ) {
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
            self.maxRetries = maxRetries
            self.retryBaseDelay = retryBaseDelay
            self.progressUpdateInterval = progressUpdateInterval
        }

        public static let `default` = Configuration()
    }

    private let configuration: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = .default) {
        self.configuration = configuration

        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfig.timeoutIntervalForResource = configuration.resourceTimeout

        self.session = Session(configuration: sessionConfig)
    }

    // MARK: - Public API

    /// 下载文件
    /// - Parameters:
    ///   - url: 下载 URL
    ///   - destination: 目标路径
    ///   - expectedSHA256: 期望的 SHA256 值（可选，用于校验）
    ///   - progress: 进度回调
    /// - Returns: 下载任务句柄和最终文件 URL 的元组
    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        expectedSHA256: String? = nil,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> (task: DownloadTask, fileURL: URL) {
        logger.info("📥 开始下载: \(url.lastPathComponent)", tag: "download")

        // 创建任务句柄
        let downloadTask = DownloadTask(url: url, client: self)
        registerTask(downloadTask, for: url)

        // 检查是否有断点数据
        let resumeData = getResumeData(for: url)

        do {
            // 执行下载（带重试）
            let tempURL = try await downloadWithRetry(
                from: url,
                resumeData: resumeData,
                downloadTask: downloadTask,
                progress: progress
            )

            // SHA256 校验
            if let expected = expectedSHA256 {
                logger.debug("🔐 开始 SHA256 校验...", tag: "download")
                let actual = try sha256(of: tempURL)

                guard actual.lowercased() == expected.lowercased() else {
                    logger.error("❌ SHA256 校验失败", tag: "download")
                    throw DownloadError.sha256Mismatch(
                        expected: expected,
                        actual: actual,
                        fileName: url.lastPathComponent
                    )
                }
                logger.info("✅ SHA256 校验通过", tag: "download")
            }

            // 移动到目标位置
            try moveToDestination(from: tempURL, to: destination)

            // 清理
            clearResumeData(for: url)
            unregisterTask(for: url)

            logger.info("✅ 下载完成: \(destination.lastPathComponent)", tag: "download")
            return (downloadTask, destination)

        } catch {
            unregisterTask(for: url)

            // 取消时不记录错误
            if let downloadError = error as? DownloadError, case .cancelled = downloadError {
                throw error
            }

            // 非取消错误才记录
            if !Task.isCancelled {
                logger.error("❌ 下载失败: \(error.localizedDescription)", tag: "download")
            }
            throw error
        }
    }

    /// 下载文件（简化版，仅返回文件 URL）
    @discardableResult
    public func download(
        from url: URL,
        to destination: URL,
        expectedSHA256: String? = nil
    ) async throws -> URL {
        let (_, fileURL) = try await download(from: url, to: destination, expectedSHA256: expectedSHA256) { _ in }
        return fileURL
    }

    /// 取消指定 URL 的下载
    public func cancelDownload(for url: URL) {
        tasksLock.lock()
        let task = activeTasks[url]
        tasksLock.unlock()

        task?.cancel()
        logger.info("⏸️ 下载已取消: \(url.lastPathComponent)", tag: "download")
    }

    /// 获取指定 URL 的下载任务
    public func getTask(for url: URL) -> DownloadTask? {
        tasksLock.lock()
        defer { tasksLock.unlock() }
        return activeTasks[url]
    }

    /// 清除指定 URL 的断点数据
    public func clearResumeData(for url: URL) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        resumeDataCache.removeValue(forKey: url)
    }

    /// 清除所有断点数据
    public func clearAllResumeData() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        resumeDataCache.removeAll()
    }

    // MARK: - Private Methods

    private func registerTask(_ task: DownloadTask, for url: URL) {
        tasksLock.lock()
        defer { tasksLock.unlock() }
        activeTasks[url] = task
    }

    private func unregisterTask(for url: URL) {
        tasksLock.lock()
        defer { tasksLock.unlock() }
        activeTasks.removeValue(forKey: url)
    }

    private func downloadWithRetry(
        from url: URL,
        resumeData: Data?,
        downloadTask: DownloadTask,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        var lastError: Error?
        var currentResumeData = resumeData

        for attempt in 0..<configuration.maxRetries {
            do {
                if attempt > 0 {
                    let delay = configuration.retryBaseDelay * pow(2, Double(attempt - 1))
                    logger.info("⏳ 第 \(attempt + 1) 次重试，等待 \(String(format: "%.1f", delay))s...", tag: "download")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }

                return try await performDownload(
                    from: url,
                    resumeData: currentResumeData,
                    downloadTask: downloadTask,
                    progress: progress
                )

            } catch let error as DownloadError {
                // 取消不重试
                if case .cancelled = error {
                    throw error
                }

                lastError = error

                // 检查是否可重试
                guard error.isRetryable else {
                    throw error
                }

                logger.warning("⚠️ 下载失败 (尝试 \(attempt + 1)/\(configuration.maxRetries)): \(error.localizedDescription)", tag: "download")

            } catch let afError as AFError {
                // 显式取消
                if afError.isExplicitlyCancelledError {
                    throw DownloadError.cancelled
                }

                // 尝试从 AFError 中提取 resumeData
                if let urlError = afError.underlyingError as? URLError,
                   let data = urlError.downloadTaskResumeData {
                    currentResumeData = data
                    setResumeData(data, for: url)
                }

                lastError = DownloadError.connectionFailed(afError)

                logger.warning("⚠️ 下载失败 (尝试 \(attempt + 1)/\(configuration.maxRetries)): \(afError.localizedDescription)", tag: "download")

            } catch {
                lastError = DownloadError.unknown(error)
                throw lastError!
            }
        }

        throw lastError ?? DownloadError.unknown(NSError(domain: "DownloadClient", code: -1))
    }

    private func performDownload(
        from url: URL,
        resumeData: Data?,
        downloadTask: DownloadTask,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            var speedCalculator = SpeedCalculator()
            var lastProgressUpdate = Date()
            let fileName = url.lastPathComponent

            let request: DownloadRequest

            if let data = resumeData {
                // 断点续传
                logger.info("🔄 从断点恢复下载...", tag: "download")
                request = session.download(resumingWith: data)
            } else {
                // 新下载
                request = session.download(url)
            }

            // 关联任务句柄（用于外部取消）
            downloadTask.setRequest(request)

            request
                .validate(statusCode: 200..<300)  // ← 添加 HTTP 状态验证
                .downloadProgress { prog in
                    let now = Date()

                    // 节流：按配置的间隔更新进度
                    guard now.timeIntervalSince(lastProgressUpdate) >= self.configuration.progressUpdateInterval else {
                        return
                    }
                    lastProgressUpdate = now

                    let downloaded = prog.completedUnitCount
                    let total = prog.totalUnitCount > 0 ? prog.totalUnitCount : nil
                    let speed = speedCalculator.update(bytesDownloaded: downloaded)
                    let eta = speedCalculator.estimateTimeRemaining(
                        downloaded: downloaded,
                        total: total,
                        speed: speed
                    )

                    let downloadProgress = DownloadProgress(
                        fileName: fileName,
                        bytesDownloaded: downloaded,
                        totalBytes: total,
                        speed: speed,
                        estimatedTimeRemaining: eta
                    )

                    progress(downloadProgress)
                }
                .response { response in
                    switch response.result {
                    case .success(let tempURL):
                        if let tempURL = tempURL {
                            continuation.resume(returning: tempURL)
                        } else {
                            continuation.resume(throwing: DownloadError.fileNotFound("临时文件不存在"))
                        }

                    case .failure(let error):
                        // 保存断点数据
                        if let data = response.resumeData {
                            self.setResumeData(data, for: url)
                        }

                        // 显式取消
                        if error.isExplicitlyCancelledError {
                            continuation.resume(throwing: DownloadError.cancelled)
                            return
                        }

                        // 转换错误
                        let downloadError = self.mapError(error, response: response.response)
                        continuation.resume(throwing: downloadError)
                    }
                }
        }
    }

    private func moveToDestination(from source: URL, to destination: URL) throws {
        // 确保目标目录存在
        let destinationDir = destination.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: destinationDir.path) {
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true)
        }

        // 删除已存在的文件
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        // 移动文件
        try fileManager.moveItem(at: source, to: destination)
    }

    private func mapError(_ error: AFError, response: HTTPURLResponse?) -> DownloadError {
        // 检查 HTTP 状态码
        if let statusCode = response?.statusCode, !(200...299).contains(statusCode) {
            return .httpError(statusCode: statusCode, message: HTTPURLResponse.localizedString(forStatusCode: statusCode))
        }

        // 检查底层错误
        if let urlError = error.underlyingError as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .networkConnectionLost:
                return .networkUnavailable
            case .timedOut:
                return .timeout
            case .cannotFindHost, .cannotConnectToHost:
                return .connectionFailed(urlError)
            default:
                return .connectionFailed(urlError)
            }
        }

        return .unknown(error)
    }

    // MARK: - SHA256

    private func sha256(of fileURL: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        var hasher = SHA256()
        let bufferSize = 1024 * 1024  // 1MB

        while autoreleasepool(invoking: {
            let data = handle.readData(ofLength: bufferSize)
            if data.isEmpty { return false }
            hasher.update(data: data)
            return true
        }) {}

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Resume Data Cache

    private func getResumeData(for url: URL) -> Data? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return resumeDataCache[url]
    }

    private func setResumeData(_ data: Data, for url: URL) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        resumeDataCache[url] = data
    }
}

// MARK: - Convenience Extensions

public extension DownloadClient {

    /// 下载文件到临时目录
    func downloadToTemp(
        from url: URL,
        expectedSHA256: String? = nil,
        progress: @escaping @Sendable (DownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        let tempDir = fileManager.temporaryDirectory
        let destination = tempDir.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        let (_, fileURL) = try await download(from: url, to: destination, expectedSHA256: expectedSHA256, progress: progress)
        return fileURL
    }

    /// 批量下载（并发）
    func downloadBatch(
        items: [(url: URL, destination: URL, sha256: String?)],
        maxConcurrency: Int = 3,
        progress: @escaping @Sendable (Int, Int, DownloadProgress?) -> Void = { _, _, _ in }
    ) async throws {
        let total = items.count
        var completed = 0

        try await withThrowingTaskGroup(of: Void.self) { group in
            var running = 0

            for (index, item) in items.enumerated() {
                // 控制并发数
                if running >= maxConcurrency {
                    try await group.next()
                    running -= 1
                }

                group.addTask {
                    try await self.download(
                        from: item.url,
                        to: item.destination,
                        expectedSHA256: item.sha256
                    ) { prog in
                        progress(index, total, prog)
                    }

                    completed += 1
                    progress(index, total, nil)
                }

                running += 1
            }

            // 等待所有任务完成
            try await group.waitForAll()
        }
    }
}
