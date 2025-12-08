import Foundation
import MLoggerKit

/// 轮询器
///
/// 支持定时轮询请求，提供：
/// - 生命周期绑定（自动停止）
/// - 更新回调
/// - 错误处理
/// - 停止条件
///
/// 使用示例：
/// ```swift
/// let poller = client.poll(every: 5) {
///     GetOrderStatusRequest(orderId: orderId)
/// }
/// .lifecycle(.view(owner: self))
/// .onUpdate { status in
///     print("Order status: \(status)")
/// }
/// .stopWhen { status in
///     status == .completed || status == .cancelled
/// }
/// .start()
/// ```
public final class Poller<Response> {
    private let logger = LoggerFactory.network

    // MARK: - Configuration

    private let interval: TimeInterval
    private let request: () async throws -> Response
    private var lifecycle: Lifecycle = .manual

    // MARK: - Lifecycle Owner

    private weak var lifecycleOwner: AnyObject?

    // MARK: - Callbacks

    private var onUpdateHandler: ((Response) -> Void)?
    private var onErrorHandler: ((Error) -> Void)?
    private var stopCondition: ((Response) -> Bool)?

    // MARK: - State

    private var pollingTask: Task<Void, Never>?
    private var isRunning = false

    // MARK: - Initialization

    /// 创建轮询器
    /// - Parameters:
    ///   - interval: 轮询间隔（秒）
    ///   - request: 请求生成函数
    public init(
        interval: TimeInterval,
        request: @escaping () async throws -> Response
    ) {
        self.interval = interval
        self.request = request
    }

    deinit {
        stop()
    }

    // MARK: - Configuration Methods

    /// 设置生命周期
    @discardableResult
    public func lifecycle(_ lifecycle: Lifecycle) -> Poller {
        self.lifecycle = lifecycle
        // 保存 owner 的弱引用
        if case .view(let owner) = lifecycle {
            self.lifecycleOwner = owner
        }
        return self
    }

    /// 设置更新回调
    @discardableResult
    public func onUpdate(_ handler: @escaping (Response) -> Void) -> Poller {
        self.onUpdateHandler = handler
        return self
    }

    /// 设置错误回调
    @discardableResult
    public func onError(_ handler: @escaping (Error) -> Void) -> Poller {
        self.onErrorHandler = handler
        return self
    }

    /// 设置停止条件
    @discardableResult
    public func stopWhen(_ condition: @escaping (Response) -> Bool) -> Poller {
        self.stopCondition = condition
        return self
    }

    // MARK: - Control Methods

    /// 启动轮询
    public func start() {
        guard !isRunning else {
            logger.warning("[Poller] Already running, ignoring start request")
            return
        }

        isRunning = true
        logger.debug("[Poller] Starting with interval: \(interval)s")

        pollingTask = Task { [weak self] in
            await self?.runPollingLoop()
        }
    }

    /// 停止轮询
    public func stop() {
        guard isRunning else {
            return
        }

        logger.debug("[Poller] Stopping")
        isRunning = false
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private Methods

    /// 轮询循环
    private func runPollingLoop() async {
        while !Task.isCancelled && isRunning {
            // 检查生命周期 owner 是否已释放
            if case .view = lifecycle, lifecycleOwner == nil {
                logger.debug("[Poller] Lifecycle owner deallocated, stopping")
                stop()
                break
            }

            do {
                // 执行请求
                let response = try await request()

                // 调用更新回调
                await MainActor.run {
                    self.onUpdateHandler?(response)
                }

                // 检查停止条件
                if let stopCondition = stopCondition, stopCondition(response) {
                    logger.debug("[Poller] Stop condition met, stopping")
                    stop()
                    break
                }

                // 等待下一次轮询
                try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))

            } catch is CancellationError {
                // 任务被取消
                logger.debug("[Poller] Cancelled")
                break

            } catch {
                // 请求失败
                logger.warning("[Poller] Request failed: \(error)")

                // 调用错误回调
                await MainActor.run {
                    self.onErrorHandler?(error)
                }

                // 继续轮询（除非被取消）
                if !Task.isCancelled && isRunning {
                    try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                }
            }
        }

        isRunning = false
        logger.debug("[Poller] Stopped")
    }
}

// MARK: - Lifecycle Support

extension Poller {
    /// 绑定到视图生命周期
    /// - Parameter owner: 生命周期拥有者
    /// - Returns: 自身，支持链式调用
    @discardableResult
    public func bind(to owner: AnyObject) -> Poller {
        self.lifecycleOwner = owner
        lifecycle(.view(owner: owner))
        return self
    }
}
