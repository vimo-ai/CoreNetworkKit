# CoreNetworkKit 架构设计文档

> 版本: 2.0
> 日期: 2025-12-08
> 状态: ✅ 实现完成

---

## 一、概述

### 1.1 背景

CoreNetworkKit 是一个完整的 Swift 网络层解决方案，支持：
- **REST API** - 类型安全的请求/响应，Token 自动刷新
- **SSE Streaming** - Server-Sent Events，用于 AI 流式对话
- **WebSocket** - Socket.IO 实时通信

### 1.2 设计目标

1. **职责清晰** - 分层架构，每层单一职责
2. **灵活组合** - 各能力正交，可自由组合
3. **简洁 API** - 简单场景简单用，复杂场景有能力
4. **可测试** - 充分的测试覆盖
5. **渐进迁移** - 兼容现有代码，逐步升级

### 1.3 技术选型

| 组件 | 选型 | 理由 |
|-----|------|-----|
| 底层引擎 | Alamofire | 成熟稳定，功能丰富，无需造轮子 |
| WebSocket | Socket.IO | 支持房间、自动重连、心跳等高级功能 |
| 日志 | MLoggerKit | 复用现有基础设施 |
| 并发模型 | Swift Concurrency | async/await，原生支持 |

### 1.4 三种通信方式

| 方式 | 协议 | 客户端 | 适用场景 |
|-----|------|--------|---------|
| REST | Request | APIClient | 常规 API 调用 |
| SSE | StreamRequest | StreamClient | AI 流式响应 |
| WebSocket | - | WebSocketClient | 实时双向通信 |

---

## 二、架构总览

```
┌─────────────────────────────────────────────────────────────────┐
│                        Public API                               │
│                                                                 │
│  • network.request(...)          单请求                         │
│  • network.orchestrate {...}     DAG 编排                       │
│  • network.batch([...])          批量聚合                        │
│  • network.poll(interval:) {...} 轮询                           │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│                  Orchestrator (编排层)                           │
│                                                                 │
│  • 执行模式: single / parallel / serial / dag                    │
│  • 失败策略: failFast / continueOnError                          │
│  • 取消策略: cascading / isolate                                 │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│                  Task (任务层)                                   │
│                                                                 │
│  Task = Request + TaskConfig                                    │
│                                                                 │
│  TaskConfig:                                                    │
│  • lifecycle: view / persistent / manual                        │
│  • control: debounce / throttle / deduplicate / priority        │
│  • cache: none / cacheFirst / staleWhileRevalidate              │
│  • retry: none / fixed(n) / exponential                         │
│  • timeout: TimeInterval?                                       │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│                  Task Executor (执行层)                          │
│                                                                 │
│  CancellationScope {                                            │
│    [Control Gate] → [Cache Read] → [Auth+Retry+Send] → [Cache Write]  │
│  }                                                              │
└─────────────────────────────────────────────────────────────────┘
                               ↓
┌─────────────────────────────────────────────────────────────────┐
│                  Engine (引擎层)                                 │
│                                                                 │
│                      Alamofire                                  │
└─────────────────────────────────────────────────────────────────┘

独立模块:
┌──────────────────┐  ┌──────────────────┐
│  BatchLoader     │  │  Poller          │
│  请求聚合器       │  │  轮询调度器       │
└──────────────────┘  └──────────────────┘
```

---

## 三、分层详解

### 3.1 Public API 层

对外暴露简洁统一的接口。

```swift
public final class NetworkClient {

    /// 单请求
    func request<R: Request>(_ request: R) -> RequestBuilder<R>

    /// DAG 编排
    func orchestrate<T>(
        onFailure: FailureStrategy = .failFast,
        @OrchestratorBuilder builder: () -> OrchestratorPlan<T>
    ) async throws -> T

    /// 批量请求
    func batch<R: Request>(_ requests: R...) async throws -> [R.Response]

    /// 轮询
    func poll<R: Request>(
        every interval: TimeInterval,
        request: @escaping () -> R
    ) -> Poller<R.Response>
}
```

### 3.2 Orchestrator 编排层

组织多个 Task 的执行拓扑。

#### 3.2.1 执行模式

| 模式 | 说明 | 示例 |
|-----|------|-----|
| single | 单个请求（退化的 DAG） | `A` |
| parallel | 并发执行，无依赖 | `A \| B \| C` |
| serial | 串行执行，链式依赖 | `A → B → C` |
| dag | 任意依赖图 | `A → [B, C] → D` |

#### 3.2.2 配置策略

```swift
/// 失败策略
public enum FailureStrategy {
    case failFast        // 一个失败立即终止，返回错误
    case continueOnError // 继续执行，返回部分结果
}

/// 取消策略
public enum CancellationStrategy {
    case cascading  // 取消传播到所有下游节点
    case isolate    // 只取消当前节点
}
```

#### 3.2.3 DAG 执行逻辑

```
1. 拓扑排序，确定执行层级
2. 同一层级的节点并发执行
3. 等待当前层级全部完成，再执行下一层级
4. 任一节点失败，根据 FailureStrategy 决定是否继续
5. 取消时，根据 CancellationStrategy 决定传播范围
```

### 3.3 Task 任务层

Task 是请求的最小执行单元，包含请求本身和执行配置。

```swift
public struct NetworkTask<R: Request> {
    let request: R
    let config: TaskConfig
}

public struct TaskConfig {
    var lifecycle: Lifecycle = .manual
    var control: ControlPolicy = .init()
    var cache: CachePolicy = .none
    var retry: RetryPolicy = .none
    var timeout: TimeInterval? = nil
}
```

#### 3.3.1 Lifecycle 生命周期

```swift
public enum Lifecycle {
    /// 绑定到视图，视图消失时自动取消
    case view(owner: AnyObject)

    /// 持久执行，不会自动取消（上传、支付等）
    case persistent

    /// 手动控制
    case manual
}
```

#### 3.3.2 ControlPolicy 控制策略

```swift
public struct ControlPolicy {
    /// 防抖：等待指定时间无新请求后才执行
    var debounce: TimeInterval? = nil

    /// 节流：限制执行频率
    var throttle: TimeInterval? = nil

    /// 去重：相同请求复用正在进行的任务
    var deduplicate: Bool = false

    /// 优先级
    var priority: Priority = .normal

    public enum Priority: Int, Comparable {
        case low = 0
        case normal = 1
        case high = 2
        case critical = 3
    }
}
```

#### 3.3.3 CachePolicy 缓存策略

```swift
public enum CachePolicy {
    /// 不使用缓存
    case none

    /// 优先使用缓存，过期后请求网络
    case cacheFirst(maxAge: TimeInterval)

    /// 先返回缓存，同时请求网络更新
    case staleWhileRevalidate
}
```

#### 3.3.4 RetryPolicy 重试策略

```swift
public enum RetryPolicy {
    /// 不重试
    case none

    /// 固定次数重试
    case fixed(maxAttempts: Int, delay: TimeInterval)

    /// 指数退避重试
    case exponential(maxAttempts: Int, initialDelay: TimeInterval, multiplier: Double)
}
```

### 3.4 Task Executor 执行层

执行单个 Task，包含完整的处理管道。

#### 3.4.1 执行流程

```
┌─────────────────────────────────────────────────────────────┐
│  CancellationScope (取消作用域 - 贯穿全程)                    │
│                                                             │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 1. Control Gate (控制门)                           │     │
│  │    • Debounce: 等待无新请求                         │     │
│  │    • Throttle: 限制频率                            │     │
│  │    • Deduplicate: 相同请求复用                      │     │
│  │    → 不通过则等待或复用                             │     │
│  └────────────────────────────────────────────────────┘     │
│                          ↓                                  │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 2. Cache Read (缓存读取)                           │     │
│  │    • cacheFirst: 有效缓存直接返回                   │     │
│  │    • staleWhileRevalidate: 返回缓存，后台更新       │     │
│  │    → 命中有效缓存可能直接返回                       │     │
│  └────────────────────────────────────────────────────┘     │
│                          ↓                                  │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 3. Request Execution (请求执行)                    │     │
│  │                                                    │     │
│  │    ┌─────────────────────────────────────────┐     │     │
│  │    │ Retry Loop                              │     │     │
│  │    │                                         │     │     │
│  │    │   [Auth] → 添加认证信息                  │     │     │
│  │    │      ↓                                  │     │     │
│  │    │   [Send] → Alamofire 发送               │     │     │
│  │    │      ↓                                  │     │     │
│  │    │   失败? → 判断是否重试                   │     │     │
│  │    │          401 → 刷新 Token 再试          │     │     │
│  │    │          其他 → 根据 RetryPolicy        │     │     │
│  │    └─────────────────────────────────────────┘     │     │
│  └────────────────────────────────────────────────────┘     │
│                          ↓                                  │
│  ┌────────────────────────────────────────────────────┐     │
│  │ 4. Cache Write (缓存写入)                          │     │
│  │    • 写入新数据                                    │     │
│  │    • 通知 staleWhileRevalidate 的等待者            │     │
│  └────────────────────────────────────────────────────┘     │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

#### 3.4.2 关键设计点

**CancellationScope 贯穿全程**

不是某个阶段的中间件，而是包裹整个执行过程：

```swift
func execute<R: Request>(task: NetworkTask<R>) async throws -> R.Response {
    // 每个关键点检查取消
    try Task.checkCancellation()

    // Control Gate
    try await controlGate.pass(task)
    try Task.checkCancellation()

    // Cache Read
    if let cached = try await cacheRead(task) {
        return cached
    }
    try Task.checkCancellation()

    // Request Execution with Retry
    let response = try await executeWithRetry(task)

    // Cache Write
    await cacheWrite(task, response)

    return response
}
```

**Auth + Retry 绑定**

Token 刷新是重试逻辑的一部分：

```swift
func executeWithRetry<R: Request>(task: NetworkTask<R>) async throws -> R.Response {
    var lastError: Error?
    let maxAttempts = task.config.retry.maxAttempts

    for attempt in 0..<maxAttempts {
        do {
            let authedRequest = try await auth.prepare(task.request)
            return try await engine.send(authedRequest)
        } catch let error as APIError where error.isUnauthorized {
            // 401: 刷新 Token 后重试
            try await auth.refresh()
            continue
        } catch {
            lastError = error
            if !shouldRetry(error, attempt: attempt, policy: task.config.retry) {
                break
            }
            await delay(for: task.config.retry, attempt: attempt)
        }
    }

    throw lastError ?? APIError.unknown
}
```

### 3.5 Engine 引擎层

底层网络传输，使用 Alamofire 实现。

```swift
public protocol NetworkEngine {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public final class AlamofireEngine: NetworkEngine {
    private let session: Session

    public init(configuration: URLSessionConfiguration = .default) {
        self.session = Session(configuration: configuration)
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.request(request)
            .validate()
            .serializingData()
            .response
    }
}
```

---

## 四、独立模块

### 4.1 BatchLoader 请求聚合器

将多个同类请求合并为批量接口调用。

```swift
public final class BatchLoader<Key: Hashable, Value> {

    private let maxBatchSize: Int
    private let maxWaitTime: TimeInterval
    private let batchFn: ([Key]) async throws -> [Key: Value]

    public init(
        maxBatchSize: Int = 50,
        maxWaitTime: TimeInterval = 0.05,
        batchFn: @escaping ([Key]) async throws -> [Key: Value]
    )

    /// 加载单个 key，自动合并到批量请求
    public func load(_ key: Key) async throws -> Value

    /// 加载多个 key
    public func loadMany(_ keys: [Key]) async throws -> [Key: Value]
}
```

**使用示例**：

```swift
let userLoader = BatchLoader<Int, User>(
    maxBatchSize: 50,
    maxWaitTime: 0.05
) { userIds in
    let response = try await api.batchGetUsers(ids: userIds)
    return Dictionary(uniqueKeysWithValues: response.users.map { ($0.id, $0) })
}

// 这些调用会被自动合并
async let user1 = userLoader.load(1)
async let user2 = userLoader.load(2)
async let user3 = userLoader.load(3)

let users = try await [user1, user2, user3]
```

### 4.2 Poller 轮询调度器

定时执行请求。

```swift
public final class Poller<Response> {

    private let interval: TimeInterval
    private let request: () async throws -> Response

    public init(
        interval: TimeInterval,
        request: @escaping () async throws -> Response
    )

    /// 设置生命周期
    public func lifecycle(_ lifecycle: Lifecycle) -> Poller

    /// 设置更新回调
    public func onUpdate(_ handler: @escaping (Response) -> Void) -> Poller

    /// 设置错误回调
    public func onError(_ handler: @escaping (Error) -> Void) -> Poller

    /// 设置停止条件
    public func stopWhen(_ condition: @escaping (Response) -> Bool) -> Poller

    /// 开始轮询
    public func start()

    /// 停止轮询
    public func stop()
}
```

**使用示例**：

```swift
let poller = network.poll(every: 30) {
    GetUnreadCountRequest()
}
.lifecycle(.view(self))
.onUpdate { count in
    self.badgeCount = count
}
.stopWhen { $0 == 0 }

poller.start()
```

---

## 五、API 使用示例

### 5.1 单请求

```swift
// 最简形式
let user = try await network.request(GetUserRequest(id: 1)).send()

// 带配置
let user = try await network
    .request(GetUserRequest(id: 1))
    .lifecycle(.view(self))
    .cache(.cacheFirst(maxAge: 300))
    .retry(.exponential(maxAttempts: 3, initialDelay: 1, multiplier: 2))
    .send()
```

### 5.2 并发请求

```swift
// 简单并发
let (banners, products) = try await network.orchestrate {
    parallel {
        task(GetBannersRequest())
        task(GetProductsRequest())
    }
}
```

### 5.3 串行请求

```swift
// 链式依赖
let config = try await network.orchestrate {
    serial {
        task(LoginRequest(user: "test", pass: "123"))
        task(GetUserInfoRequest())
        task(GetConfigRequest())
    }
}
```

### 5.4 DAG 编排

```swift
// 复杂依赖
let result = try await network.orchestrate(onFailure: .failFast) {

    let login = task(LoginRequest(user, pass))
        .lifecycle(.persistent)  // 登录不能取消
        .retry(.fixed(maxAttempts: 3, delay: 1))

    let userInfo = task(GetUserInfoRequest())
        .after(login)
        .cache(.cacheFirst(maxAge: 300))

    let config = task(GetConfigRequest())
        .after(login)

    let permissions = task(GetPermissionsRequest())
        .after(userInfo, config)  // 等待 userInfo 和 config 都完成

    return permissions
}
```

### 5.5 批量请求

```swift
// 显式批量
let users = try await network.batch(
    GetUserRequest(id: 1),
    GetUserRequest(id: 2),
    GetUserRequest(id: 3)
)

// 使用 BatchLoader
let user = try await userLoader.load(userId)
```

### 5.6 轮询

```swift
let poller = network.poll(every: 30) {
    GetUnreadCountRequest()
}
.lifecycle(.view(self))
.onUpdate { count in
    self.unreadCount = count
}

poller.start()
```

---

## 六、错误处理

### 6.1 统一错误类型

```swift
public enum NetworkError: Error {
    /// 请求被取消
    case cancelled

    /// 请求超时
    case timeout

    /// 无网络连接
    case noNetwork

    /// 服务器错误
    case serverError(statusCode: Int, message: String?)

    /// 响应解码失败
    case decodingFailed(Error)

    /// 认证失败
    case authenticationFailed

    /// 重试次数耗尽
    case retryExhausted(lastError: Error)

    /// URL 构建失败
    case invalidURL

    /// 未知错误
    case unknown(Error)
}
```

### 6.2 编排错误

```swift
public enum OrchestrationError: Error {
    /// 单个节点失败（failFast 模式）
    case nodeFailed(nodeId: String, error: Error)

    /// 部分节点失败（continueOnError 模式）
    case partialFailure(successes: [String: Any], failures: [String: Error])

    /// 循环依赖
    case cyclicDependency
}
```

---

## 七、日志

使用现有 MLoggerKit，简单直接。

```swift
internal let logger = LoggerFactory.network

// 请求开始
logger.debug("→ \(request.method.rawValue) \(request.path)", tag: "request")

// 请求成功
logger.debug("← 200 \(request.path) (\(duration)ms)", tag: "response")

// 请求失败
logger.error("✗ \(error.localizedDescription)", tag: "error")

// 缓存命中
logger.debug("⚡ 缓存命中 \(request.path)", tag: "cache")

// 重试
logger.warning("↻ 重试 #\(attempt) \(request.path)", tag: "retry")

// Token 刷新
logger.info("🔑 Token 已刷新", tag: "auth")
```

---

## 八、测试策略

### 8.1 测试基础设施

```swift
/// Mock 网络引擎
public final class MockEngine: NetworkEngine {
    private var stubs: [String: Result<(Data, URLResponse), Error>] = [:]
    private var callRecords: [URLRequest] = []

    public func stub<R: Request>(_ type: R.Type, response: R.Response)
    public func stub<R: Request>(_ type: R.Type, error: Error)
    public func stub<R: Request>(_ type: R.Type, delay: TimeInterval, response: R.Response)

    public func verify<R: Request>(_ type: R.Type, calledTimes: Int)
    public func verify<R: Request>(_ type: R.Type, calledWith: (R) -> Bool)
}

/// Mock 时钟（测试防抖/超时/轮询）
public final class MockClock {
    public func advance(by duration: TimeInterval)
    public func advanceToEnd()
}

/// Mock Token 存储
public final class MockTokenStorage: TokenStorage {
    public var token: String?
    public var shouldFailRefresh: Bool = false
}
```

### 8.2 测试用例规划

#### Orchestrator 测试

```swift
// DAG 执行
func test_dag_executesInCorrectOrder()
func test_dag_parallelNodesRunConcurrently()
func test_dag_serialNodesRunSequentially()
func test_dag_complexDependencies()

// 失败策略
func test_failFast_stopsOnFirstError()
func test_failFast_cancelsDownstreamNodes()
func test_continueOnError_completesAllNodes()
func test_continueOnError_returnsPartialResults()

// 取消
func test_cancel_stopsAllPendingNodes()
func test_cancel_propagatesToRunningNodes()
func test_cascading_cancelsDownstream()
func test_isolate_onlyCancelsCurrentNode()
```

#### Control Gate 测试

```swift
// 防抖
func test_debounce_waitsBeforeExecuting()
func test_debounce_cancelsIfNewRequestArrives()
func test_debounce_executesAfterQuietPeriod()

// 去重
func test_deduplicate_reusesPendingRequest()
func test_deduplicate_newRequestAfterCompletion()
func test_deduplicate_differentRequestsNotDeduplicated()

// 节流
func test_throttle_blocksExcessRequests()
func test_throttle_allowsAfterInterval()

// 优先级
func test_priority_highExecutesFirst()
func test_priority_criticalInterruptsNormal()
```

#### Cache 测试

```swift
// 策略
func test_cacheFirst_returnsCachedData()
func test_cacheFirst_fetchesOnMiss()
func test_cacheFirst_fetchesOnExpired()
func test_staleWhileRevalidate_returnsStaleThenUpdates()
func test_none_alwaysFetchesNetwork()

// 边界
func test_cache_expiresCorrectly()
func test_cache_invalidatesOnError()
func test_cache_handlesRaceCondition()
```

#### Auth + Retry 测试

```swift
// 认证
func test_auth_addsTokenToRequest()
func test_auth_refreshesOn401()
func test_auth_failsAfterRefreshFailure()
func test_auth_onlyRefreshesOnce()

// 重试
func test_retry_retriesOnTransientError()
func test_retry_stopsAfterMaxAttempts()
func test_retry_exponentialBackoff()
func test_retry_noRetryOnClientError()
func test_retry_respectsTimeout()
```

#### Lifecycle 测试

```swift
func test_viewScope_cancelsOnDeinit()
func test_viewScope_cancelsOnInvalidate()
func test_persistentScope_neverAutoCancels()
func test_manualScope_requiresExplicitCancel()
func test_cancellation_throwsCancellationError()
func test_cancellation_interruptsAtAnyStage()
```

#### BatchLoader 测试

```swift
func test_batch_combinesMultipleRequests()
func test_batch_splitsResponseCorrectly()
func test_batch_respectsMaxBatchSize()
func test_batch_respectsMaxWaitTime()
func test_batch_handlesPartialFailure()
func test_batch_handlesEmptyResult()
```

#### Poller 测试

```swift
func test_poller_executesAtInterval()
func test_poller_stopsOnCondition()
func test_poller_stopsOnScopeInvalidate()
func test_poller_continuesOnError()
func test_poller_manualStop()
```

#### 集成测试

```swift
func test_fullFlow_singleRequestSuccess()
func test_fullFlow_singleRequestWithCache()
func test_fullFlow_retryThenSuccess()
func test_fullFlow_dagWithMixedLifecycles()
func test_fullFlow_cancelDuringRetry()
func test_fullFlow_tokenRefreshDuringDag()
```

### 8.3 覆盖率目标

| 组件 | 目标覆盖率 |
|-----|-----------|
| Orchestrator | 95%+ |
| Control Gate | 95%+ |
| Cache | 90%+ |
| Auth + Retry | 95%+ |
| Task Executor | 90%+ |
| BatchLoader | 90%+ |
| Poller | 85%+ |
| 整体 | 90%+ |

---

## 九、模块结构

```
CoreNetworkKit/
├── Sources/
│   └── CoreNetworkKit/
│       ├── Public/                      # 对外 API
│       │   ├── NetworkClient.swift
│       │   ├── RequestBuilder.swift
│       │   └── Types/
│       │       ├── Lifecycle.swift
│       │       ├── ControlPolicy.swift
│       │       ├── CachePolicy.swift
│       │       ├── RetryPolicy.swift
│       │       └── NetworkError.swift
│       │
│       ├── Orchestrator/                # 编排层
│       │   ├── Orchestrator.swift
│       │   ├── OrchestratorBuilder.swift
│       │   ├── ExecutionPlan.swift
│       │   └── Strategies/
│       │       ├── FailureStrategy.swift
│       │       └── CancellationStrategy.swift
│       │
│       ├── Task/                        # 任务层
│       │   ├── NetworkTask.swift
│       │   └── TaskConfig.swift
│       │
│       ├── Executor/                    # 执行层
│       │   ├── TaskExecutor.swift
│       │   ├── ControlGate.swift
│       │   ├── CacheManager.swift
│       │   └── AuthRetryHandler.swift
│       │
│       ├── Engine/                      # 引擎层
│       │   ├── NetworkEngine.swift
│       │   └── AlamofireEngine.swift
│       │
│       ├── Modules/                     # 独立模块
│       │   ├── BatchLoader.swift
│       │   └── Poller.swift
│       │
│       ├── Protocols/                   # 协议定义
│       │   ├── Request.swift            # (现有)
│       │   ├── TokenStorage.swift       # (现有)
│       │   └── TokenRefresher.swift     # (现有)
│       │
│       └── Internal/                    # 内部工具
│           ├── CancellationScope.swift
│           └── Logger.swift
│
└── Tests/
    └── CoreNetworkKitTests/
        ├── OrchestratorTests.swift
        ├── ControlGateTests.swift
        ├── CacheTests.swift
        ├── AuthRetryTests.swift
        ├── LifecycleTests.swift
        ├── BatchLoaderTests.swift
        ├── PollerTests.swift
        ├── IntegrationTests.swift
        └── Mocks/
            ├── MockEngine.swift
            ├── MockClock.swift
            └── MockTokenStorage.swift
```

---

## 十、迁移计划

### 10.1 阶段一：基础设施（不破坏现有代码）

1. 引入 Alamofire 依赖
2. 实现 AlamofireEngine
3. 新增类型定义（Lifecycle, ControlPolicy, CachePolicy, RetryPolicy）
4. 新增 NetworkTask, TaskConfig
5. 现有 APIClient 保持不变

### 10.2 阶段二：核心功能

1. 实现 TaskExecutor（管道）
2. 实现 ControlGate
3. 实现 CacheManager
4. 实现 AuthRetryHandler
5. 编写单元测试

### 10.3 阶段三：编排能力

1. 实现 Orchestrator
2. 实现 OrchestratorBuilder (Result Builder)
3. 实现 ExecutionPlan（DAG）
4. 编写编排测试

### 10.4 阶段四：独立模块

1. 实现 BatchLoader
2. 实现 Poller
3. 编写模块测试

### 10.5 阶段五：Public API

1. 实现 NetworkClient
2. 实现 RequestBuilder
3. 编写集成测试
4. 编写迁移指南

### 10.6 阶段六：迁移与清理

1. 逐步迁移现有代码
2. 废弃旧 API
3. 清理无用代码

---

## 十一、附录

### 11.1 与现有代码的兼容性

现有 `APIClient.send()` 方法保持不变，新旧 API 可共存：

```swift
// 旧 API（继续可用）
let user = try await apiClient.send(GetUserRequest(id: 1))

// 新 API
let user = try await network.request(GetUserRequest(id: 1)).send()
```

### 11.2 设计决策记录

| 决策 | 选择 | 理由 |
|-----|------|-----|
| 底层引擎 | Alamofire | 成熟稳定，无需造轮子 |
| 日志方案 | MLoggerKit | 复用现有，简单够用 |
| Batch 位置 | 独立模块 | 不是所有请求都能合并，需显式声明 |
| Polling 位置 | 独立模块 | 与 Lifecycle 正交，独立职责 |
| Lifecycle 实现 | CancellationScope | 贯穿全程，非中间件 |
| Auth + Retry | 绑定 | Token 刷新是重试的一部分 |
| 失败策略默认值 | failFast | 符合大多数场景预期 |
| 取消策略默认值 | cascading | 避免悬挂的下游节点 |

---

## 十二、实现细节补充

> 本章节基于外部架构审核反馈，补充关键实现细节。

### 12.1 缓存 Key 定义

缓存和去重都需要一个统一的"请求等价"判定策略。

#### CacheKey 计算规则

```swift
public struct CacheKey: Hashable {
    let method: String
    let url: String
    let queryHash: Int
    let bodyHash: Int?

    /// 从 Request 生成 CacheKey
    static func from<R: Request>(_ request: R) -> CacheKey {
        let url = request.baseURL.appendingPathComponent(request.path).absoluteString

        // Query 参数排序后 hash
        let sortedQuery = request.query?
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&") ?? ""

        // Body hash（仅对有 body 的请求）
        let bodyHash: Int? = {
            guard let body = request.body else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys  // 保证顺序一致
            guard let data = try? encoder.encode(body) else { return nil }
            return data.hashValue
        }()

        return CacheKey(
            method: request.method.rawValue,
            url: url,
            queryHash: sortedQuery.hashValue,
            bodyHash: bodyHash
        )
    }
}
```

#### 去重使用相同的 Key

```swift
// ControlGate 内部
private var pendingRequests: [CacheKey: Task<Any, Error>] = [:]

func deduplicate<R: Request>(_ request: R) async throws -> R.Response {
    let key = CacheKey.from(request)

    if let pending = pendingRequests[key] {
        // 复用正在进行的请求
        return try await pending.value as! R.Response
    }

    // 创建新请求...
}
```

### 12.2 Token 刷新 Single-Flight 保护

避免多个并发请求同时触发 Token 刷新。

```swift
actor TokenRefreshCoordinator {
    private var refreshTask: Task<String, Error>?

    /// 刷新 Token，保证并发只执行一次
    func refresh(using refresher: TokenRefresher) async throws -> String {
        // 如果已有刷新任务，直接等待
        if let task = refreshTask {
            return try await task.value
        }

        // 创建新的刷新任务
        let task = Task {
            try await refresher.refreshToken()
        }
        refreshTask = task

        defer { refreshTask = nil }
        return try await task.value
    }
}
```

### 12.3 Retry 幂等区分

不是所有请求都应该重试，需要区分幂等性。

```swift
public enum RetryPolicy {
    case none
    case fixed(maxAttempts: Int, delay: TimeInterval)
    case exponential(maxAttempts: Int, initialDelay: TimeInterval, multiplier: Double, maxDelay: TimeInterval = 30)
}

/// Request 协议扩展：声明是否可重试
public extension Request {
    /// 默认根据 HTTP 方法判断
    /// GET/HEAD/OPTIONS/TRACE 是幂等的，可重试
    /// POST/PATCH 默认不重试（除非显式声明）
    var isIdempotent: Bool {
        switch method {
        case .get, .head, .options, .trace, .delete, .put:
            return true
        case .post, .patch:
            return false
        }
    }
}

/// 重试判断逻辑
func shouldRetry<R: Request>(
    _ request: R,
    error: Error,
    attempt: Int,
    policy: RetryPolicy
) -> Bool {
    // 非幂等请求默认不重试
    guard request.isIdempotent else { return false }

    // 客户端错误（4xx）不重试
    if case .serverError(let code, _) = error as? NetworkError,
       (400..<500).contains(code) {
        return false
    }

    // 根据策略判断
    switch policy {
    case .none:
        return false
    case .fixed(let maxAttempts, _),
         .exponential(let maxAttempts, _, _, _):
        return attempt < maxAttempts - 1
    }
}
```

### 12.4 Retry 全局超时

防止重试时间过长。

```swift
public struct TaskConfig {
    // ... 现有字段

    /// 整体超时（包含所有重试）
    var totalTimeout: TimeInterval? = nil
}

func executeWithRetry<R: Request>(task: NetworkTask<R>) async throws -> R.Response {
    let startTime = Date()
    var lastError: Error?

    for attempt in 0..<maxAttempts {
        // 检查全局超时
        if let totalTimeout = task.config.totalTimeout {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= totalTimeout {
                throw NetworkError.timeout
            }
        }

        do {
            return try await executeOnce(task)
        } catch {
            lastError = error
            if !shouldRetry(task.request, error: error, attempt: attempt, policy: task.config.retry) {
                break
            }
            await delay(for: task.config.retry, attempt: attempt)
        }
    }

    throw NetworkError.retryExhausted(lastError: lastError ?? NetworkError.unknown)
}
```

### 12.5 Lifecycle 触发时机

明确 `.view(owner:)` 的取消时机。

```swift
public enum Lifecycle {
    /// 绑定到视图
    /// - 触发时机：owner 对象 deinit 时自动取消
    /// - 实现：使用 weak 引用监听
    case view(owner: AnyObject)

    /// 持久执行，不会自动取消
    case persistent

    /// 手动控制
    case manual
}

/// 内部实现
final class LifecycleObserver {
    private weak var owner: AnyObject?
    private let onInvalidate: () -> Void

    init(owner: AnyObject, onInvalidate: @escaping () -> Void) {
        self.owner = owner
        self.onInvalidate = onInvalidate

        // 定期检查 owner 是否还存活
        // 或使用 associated object + deinit hook
    }

    var isValid: Bool {
        return owner != nil
    }
}

/// SwiftUI 推荐用法
/// 配合 .task modifier，自动管理生命周期
struct MyView: View {
    var body: some View {
        Text("Hello")
            .task {
                // .task 自动在 view 消失时取消
                let user = try? await network
                    .request(GetUserRequest(id: 1))
                    .lifecycle(.manual)  // 由 .task 管理
                    .send()
            }
    }
}
```

### 12.6 DAG 结果类型安全

编排结果需要类型安全的访问方式。

```swift
/// 类型安全的节点句柄
public struct TaskNode<Response> {
    internal let id: String
    internal var dependencies: [String] = []
}

/// 编排结果
public struct OrchestrationResult {
    private var results: [String: Any] = [:]

    /// 类型安全地获取节点结果
    public func get<T>(_ node: TaskNode<T>) throws -> T {
        guard let value = results[node.id] else {
            throw OrchestrationError.nodeNotFound(node.id)
        }
        guard let typed = value as? T else {
            throw OrchestrationError.typeMismatch(node.id)
        }
        return typed
    }
}

/// continueOnError 模式的结果
public struct PartialOrchestrationResult {
    public let successes: [String: Any]
    public let failures: [String: Error]

    public func get<T>(_ node: TaskNode<T>) throws -> T {
        if let error = failures[node.id] {
            throw error
        }
        guard let value = successes[node.id] as? T else {
            throw OrchestrationError.nodeNotFound(node.id)
        }
        return value
    }
}
```

### 12.7 取消传播到 Alamofire

CancellationScope 需要真正取消底层网络请求。

```swift
public final class AlamofireEngine: NetworkEngine {
    private let session: Session

    /// 发送请求，支持取消传播
    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        // 创建 Alamofire DataRequest
        let dataRequest = session.request(request)

        return try await withTaskCancellationHandler {
            // 正常执行
            try await dataRequest
                .validate()
                .serializingData()
                .value
        } onCancel: {
            // Task 被取消时，同步取消 Alamofire 请求
            dataRequest.cancel()
        }
    }
}
```

### 12.8 BatchLoader 部分失败处理

批量请求中部分 Key 失败的处理策略。

```swift
public final class BatchLoader<Key: Hashable, Value> {

    public enum PartialFailureStrategy {
        /// 任一失败则全部失败
        case failAll
        /// 返回成功的，失败的单独处理
        case returnPartial
    }

    private let partialFailureStrategy: PartialFailureStrategy

    /// 加载单个 key
    public func load(_ key: Key) async throws -> Value {
        let results = try await loadBatch(containing: key)

        guard let value = results[key] else {
            throw BatchLoaderError.keyNotFound(key)
        }

        return value
    }

    /// 加载多个 key，返回成功的结果和失败的 key
    public func loadMany(_ keys: [Key]) async -> (
        successes: [Key: Value],
        failures: [Key: Error]
    ) {
        // 实现...
    }
}

public enum BatchLoaderError: Error {
    case keyNotFound(Any)
    case partialFailure(successes: [Any], failures: [Any: Error])
    case batchFailed(Error)
}
```

### 12.9 补充测试用例

基于审核反馈，补充以下测试场景：

```swift
// 并发竞争条件测试
func test_tokenRefresh_singleFlight_underConcurrentRequests()
func test_deduplicate_raceCondition_sameCacheKey()
func test_cache_staleWhileRevalidate_concurrentReads()

// 取消传播测试
func test_cancel_propagatesToAlamofireRequest()
func test_cancel_duringCacheRead()
func test_cancel_duringTokenRefresh()

// BatchLoader 部分失败测试
func test_batch_partialFailure_failAllStrategy()
func test_batch_partialFailure_returnPartialStrategy()

// 重试幂等测试
func test_retry_skipsNonIdempotentByDefault()
func test_retry_respectsTotalTimeout()
func test_retry_stopsOnClientError()

// DAG 类型安全测试
func test_dag_typeSafeResultAccess()
func test_dag_detectsCyclicDependency()
```

---

## 十三、迁移指南

### 13.1 从旧 API 迁移

#### 单请求迁移

```swift
// ❌ 旧 API (APIClient)
let user = try await apiClient.send(GetUserRequest(id: 1))

// ✅ 新 API (NetworkClient)
let client = NetworkClient(
    engine: AlamofireEngine(),
    tokenStorage: myTokenStorage,
    tokenRefresher: myTokenRefresher
)
let user = try await client.request(GetUserRequest(id: 1)).execute()
```

#### 添加缓存/重试

```swift
// ✅ 链式配置
let user = try await client
    .request(GetUserRequest(id: 1))
    .cache(.cacheFirst(maxAge: 300))
    .retry(.exponential(maxAttempts: 3))
    .execute()
```

#### 生命周期绑定

```swift
// ✅ 绑定到视图
let user = try await client
    .request(lifecycle: self, GetUserRequest(id: 1))
    .execute()

// 或使用 RequestBuilder
let user = try await client
    .request(GetUserRequest(id: 1))
    .lifecycle(.view(owner: self))
    .execute()
```

### 13.2 DAG 编排使用

```swift
// 并发获取多个资源
let (user, config) = try await client.orchestrate {
    ("user", OrchestratorNode(request: GetUserRequest(id: 1)))
    ("config", OrchestratorNode(request: GetConfigRequest()))
}

// 带依赖关系
let result = try await client.orchestrate {
    ("auth", OrchestratorNode(request: LoginRequest()))
    ("user", OrchestratorNode(request: GetUserRequest()).after("auth"))
    ("config", OrchestratorNode(request: GetConfigRequest()).after("auth"))
}
```

### 13.3 批量请求

```swift
// 使用 batch 方法
let users = try await client.batch([
    GetUserRequest(id: 1),
    GetUserRequest(id: 2),
    GetUserRequest(id: 3)
])

// 使用 BatchLoader (DataLoader 模式)
let loader = client.createBatchLoader(maxBatchSize: 50) { userIds in
    try await api.batchGetUsers(ids: userIds)
}

let user = try await loader.load(userId)
```

### 13.4 轮询

```swift
let poller = client.poll(every: 30) {
    GetUnreadCountRequest()
}
.lifecycle(.view(owner: self))
.onUpdate { count in
    self.badgeCount = count
}
.stopWhen { $0 == 0 }

poller.start()
```

### 13.5 错误处理

```swift
do {
    let user = try await client.request(GetUserRequest(id: 1)).execute()
} catch NetworkError.cancelled {
    // 请求被取消
} catch NetworkError.timeout {
    // 请求超时
} catch NetworkError.noNetwork {
    // 无网络连接
} catch NetworkError.serverError(let code, let message) {
    // 服务器错误
} catch NetworkError.decodingFailed(let error) {
    // 解码失败
} catch NetworkError.authenticationFailed {
    // 认证失败
} catch {
    // 其他错误
}
```

---

## 十四、SSE Streaming (AI 流式响应)

### 14.1 概述

SSE (Server-Sent Events) 用于处理服务器推送的流式数据，主要应用于 AI 对话场景。

### 14.2 核心组件

#### StreamRequest 协议

```swift
public protocol StreamRequest: Request {
    /// 流式响应中每个数据块的类型
    associatedtype Chunk: Decodable

    /// SSE 数据行前缀，默认 "data:"
    var streamDataPrefix: String { get }

    /// 流结束标记，默认 "[DONE]"
    var streamDoneMarker: String { get }
}
```

#### StreamClient

```swift
public final class StreamClient {
    /// 发起流式请求，返回 AsyncThrowingStream
    public func stream<R: StreamRequest>(_ request: R) -> AsyncThrowingStream<R.Chunk, Error>

    /// 发起流式请求，通过回调处理
    public func stream<R: StreamRequest>(
        _ request: R,
        onChunk: @escaping (R.Chunk) -> Void,
        onComplete: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) -> Task<Void, Never>
}
```

### 14.3 认证支持

StreamClient 复用 `AuthenticationStrategy` 协议：

```swift
struct AIStreamRequest: StreamRequest {
    var authentication: AuthenticationStrategy {
        BearerTokenAuthenticationStrategy()  // JWT Bearer Token
    }
}
```

### 14.4 使用示例

```swift
// 定义请求
struct AICompletionRequest: StreamRequest {
    typealias Response = EmptyBody
    typealias Chunk = AIChunk

    let messages: [Message]

    var baseURL: URL { URL(string: "https://api.openai.com")! }
    var path: String { "/v1/chat/completions" }
    var method: HTTPMethod { .post }
    var body: RequestBody? { RequestBody(messages: messages, stream: true) }
    var authentication: AuthenticationStrategy { BearerTokenAuthenticationStrategy() }
}

// 使用 for-await
let client = StreamClient(tokenStorage: myTokenStorage)
for try await chunk in client.stream(AICompletionRequest(messages: [...])) {
    print(chunk.delta.content ?? "")
}

// 使用回调
client.stream(
    AICompletionRequest(messages: [...]),
    onChunk: { chunk in updateUI(chunk) },
    onComplete: { finishLoading() },
    onError: { error in showError(error) }
)
```

---

## 十五、WebSocket (Socket.IO)

### 15.1 概述

WebSocket 模块基于 Socket.IO 实现，支持：
- 多种认证方式 (Query Param / Bearer Header / Custom Header)
- 类型安全的事件监听
- 房间管理
- 自动重连
- SwiftUI 状态集成

### 15.2 核心组件

#### WebSocketConfiguration

```swift
public struct WebSocketConfiguration {
    let url: URL
    let token: String?
    let authMethod: WebSocketAuthMethod
    let enableLogging: Bool
    let reconnects: Bool
    let reconnectAttempts: Int
    let reconnectWait: TimeInterval
    let extraParams: [String: Any]?
    let extraHeaders: [String: String]?
}

public enum WebSocketAuthMethod {
    case queryParam(key: String = "token")  // ?token=xxx
    case bearerHeader                        // Authorization: Bearer xxx
    case customHeader(key: String)           // X-Auth-Token: xxx
    case none
}
```

#### WebSocketClient

```swift
public final class WebSocketClient: ObservableObject {
    // 状态
    @Published var connectionState: WebSocketConnectionState
    @Published var isConnected: Bool
    @Published var lastError: Error?

    // 连接管理
    func connect()
    func disconnect()
    func reconnect(withToken: String)

    // 事件监听 (类型安全)
    func on<T: Decodable>(_ event: String, handler: @escaping (T) -> Void)
    func off(_ event: String)

    // 发送消息
    func emit<T: Encodable>(_ event: String, data: T)
    func emit(_ event: String, data: [String: Any])

    // 房间管理
    func join(room: String, params: [String: Any])
    func leave(room: String)
}
```

### 15.3 认证方式

```swift
// 方式 1: Token 作为 query 参数 (默认)
let client = WebSocketClient(url: serverURL, token: "xxx")
// 连接: ws://server?token=xxx

// 方式 2: JWT Bearer Token (Header)
let client = WebSocketClient(url: serverURL, bearerToken: "jwt")
// 连接时 Header: Authorization: Bearer jwt

// 方式 3: 自定义 Header
let config = WebSocketConfiguration(
    url: serverURL,
    token: "xxx",
    authMethod: .customHeader(key: "X-Auth-Token")
)
let client = WebSocketClient(configuration: config)

// 方式 4: 完整配置
let config = WebSocketConfiguration(
    url: serverURL,
    token: "jwt",
    authMethod: .bearerHeader,
    extraParams: ["clientType": "ios"],
    extraHeaders: ["X-Client-Version": "1.0"]
)
```

### 15.4 使用示例

```swift
// 初始化
let wsClient = WebSocketClient(url: serverURL, bearerToken: jwtToken)

// 监听事件
wsClient.on("message:new") { (message: ChatMessage) in
    print("New message: \(message)")
}

wsClient.on("user:joined") { (user: User) in
    print("\(user.name) joined")
}

// 连接
wsClient.connect()

// 加入房间
wsClient.join(room: "session-123", params: ["projectPath": "/path"])

// 发送消息
wsClient.emit("send", data: ["text": "Hello"])
wsClient.emit("typing", data: TypingEvent(isTyping: true))

// SwiftUI 集成
struct ChatView: View {
    @ObservedObject var wsClient: WebSocketClient

    var body: some View {
        VStack {
            if wsClient.isConnected {
                Text("Connected")
            } else {
                Text("Disconnected")
            }
        }
    }
}

// Token 刷新后重连
wsClient.reconnect(withToken: newToken)

// 断开连接
wsClient.disconnect()
```

### 15.5 错误处理

```swift
public enum WebSocketError: Error {
    case connectionError(String)
    case notConnected
    case encodingFailed
    case decodingFailed
}
```

---

## 十六、模块结构 (完整)

```
CoreNetworkKit/
├── Sources/CoreNetworkKit/
│   ├── Core/
│   │   ├── APIClient.swift           # REST 客户端
│   │   ├── StreamClient.swift        # SSE 流式客户端
│   │   └── ...
│   │
│   ├── WebSocket/
│   │   ├── WebSocketClient.swift     # Socket.IO 封装
│   │   └── WebSocketEvent.swift      # 配置和类型定义
│   │
│   ├── Protocols/
│   │   ├── Request.swift             # REST 请求协议
│   │   ├── StreamRequest.swift       # SSE 请求协议
│   │   ├── AuthenticationStrategy.swift
│   │   └── ...
│   │
│   ├── Engine/
│   │   └── URLSessionEngine.swift
│   │
│   └── ...
│
└── Package.swift                      # 依赖: Alamofire, Socket.IO
```
