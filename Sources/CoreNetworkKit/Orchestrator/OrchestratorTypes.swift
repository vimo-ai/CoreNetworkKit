import Foundation

/// 失败策略
///
/// 定义编排器在某个节点失败时的处理方式
public enum FailureStrategy {
    /// 一个失败立即终止整个编排
    case failFast

    /// 继续执行，返回部分结果
    case continueOnError
}

/// 取消策略
///
/// 定义取消操作的传播行为
public enum CancellationStrategy {
    /// 取消传播到所有下游节点
    case cascading

    /// 只取消当前节点，不影响其他节点
    case isolate
}

/// 原始节点数据（用于 Builder 阶段，不包含 executor）
public struct RawOrchestratorNode {
    let id: AnyHashable
    let request: any Request
    let config: TaskConfig
    let dependencies: [AnyHashable]

    public init<R: Request>(id: AnyHashable, node: OrchestratorNode<R>) {
        self.id = id
        self.request = node.request
        self.config = node.config
        self.dependencies = node.dependencies
    }
}

/// 编排计划
///
/// 封装编排器的执行计划和最终结果的转换逻辑
public struct OrchestratorPlan<T> {
    /// 原始节点数据（Builder 阶段填充）
    let rawNodes: [RawOrchestratorNode]
    /// 类型擦除后的节点（执行阶段填充）
    let nodes: [AnyOrchestratorNode]
    let transform: ([AnyHashable: Any]) throws -> T

    /// Builder 使用的初始化器（只有原始节点）
    public init(
        rawNodes: [RawOrchestratorNode],
        transform: @escaping ([AnyHashable: Any]) throws -> T
    ) {
        self.rawNodes = rawNodes
        self.nodes = []
        self.transform = transform
    }

    /// 执行器使用的初始化器（有类型擦除节点）
    public init(
        nodes: [AnyOrchestratorNode],
        transform: @escaping ([AnyHashable: Any]) throws -> T
    ) {
        self.rawNodes = []
        self.nodes = nodes
        self.transform = transform
    }

    /// 使用 executor 和 authContext 转换原始节点为可执行节点
    func withExecutor(_ executor: TaskExecutor, authContext: AuthenticationContext) -> OrchestratorPlan<T> {
        let erasedNodes = rawNodes.map { raw in
            AnyOrchestratorNode(
                id: raw.id,
                request: raw.request,
                config: raw.config,
                dependencies: raw.dependencies,
                executor: executor,
                authContext: authContext
            )
        }
        return OrchestratorPlan(nodes: erasedNodes, transform: transform)
    }
}

/// 类型擦除的编排节点
///
/// 用于统一存储不同 Request 类型的节点
public struct AnyOrchestratorNode: Hashable {
    let id: AnyHashable
    let dependencies: [AnyHashable]
    let execute: () async throws -> Any
    let config: TaskConfig

    public init<R: Request>(
        id: AnyHashable,
        node: OrchestratorNode<R>,
        executor: TaskExecutor,
        authContext: AuthenticationContext
    ) {
        self.id = id
        self.dependencies = node.dependencies
        self.config = node.config
        self.execute = Self.makeExecute(
            request: node.request,
            config: node.config,
            executor: executor,
            authContext: authContext
        )
    }

    /// 从原始节点数据创建（用于执行阶段）
    public init(
        id: AnyHashable,
        request: any Request,
        config: TaskConfig,
        dependencies: [AnyHashable],
        executor: TaskExecutor,
        authContext: AuthenticationContext
    ) {
        self.id = id
        self.dependencies = dependencies
        self.config = config
        self.execute = Self.makeExecuteAny(
            request: request,
            config: config,
            executor: executor,
            authContext: authContext
        )
    }

    /// 创建执行闭包（泛型版本）
    private static func makeExecute<R: Request>(
        request: R,
        config: TaskConfig,
        executor: TaskExecutor,
        authContext: AuthenticationContext
    ) -> () async throws -> Any {
        return {
            let builder = RequestBuilder(
                request: request,
                executor: executor,
                authContext: authContext
            )
            // 应用配置
            builder.lifecycle(config.lifecycle)
            builder.cache(config.cache)
            builder.retry(config.retry)
            if let timeout = config.timeout {
                builder.timeout(timeout)
            }
            if let totalTimeout = config.totalTimeout {
                builder.totalTimeout(totalTimeout)
            }
            return try await builder.execute()
        }
    }

    /// 创建执行闭包（存在类型版本）
    private static func makeExecuteAny(
        request: any Request,
        config: TaskConfig,
        executor: TaskExecutor,
        authContext: AuthenticationContext
    ) -> () async throws -> Any {
        return {
            try await executeRequest(request, config: config, executor: executor, authContext: authContext)
        }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: AnyOrchestratorNode, rhs: AnyOrchestratorNode) -> Bool {
        lhs.id == rhs.id
    }
}

/// 执行任意 Request（使用类型擦除）
private func executeRequest(
    _ request: any Request,
    config: TaskConfig,
    executor: TaskExecutor,
    authContext: AuthenticationContext
) async throws -> Any {
    func execute<R: Request>(_ r: R) async throws -> Any {
        let builder = RequestBuilder(
            request: r,
            executor: executor,
            authContext: authContext
        )
        builder.lifecycle(config.lifecycle)
        builder.cache(config.cache)
        builder.retry(config.retry)
        if let timeout = config.timeout {
            builder.timeout(timeout)
        }
        if let totalTimeout = config.totalTimeout {
            builder.totalTimeout(totalTimeout)
        }
        return try await builder.execute()
    }
    return try await execute(request)
}
