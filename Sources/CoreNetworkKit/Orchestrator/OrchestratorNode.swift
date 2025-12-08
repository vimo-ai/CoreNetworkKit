import Foundation

/// 编排节点
///
/// 表示编排图中的一个请求节点，支持依赖关系和配置
public struct OrchestratorNode<R: Request> {
    let request: R
    var config: TaskConfig
    var dependencies: [AnyHashable]

    /// 创建编排节点
    /// - Parameter request: Request 对象
    public init(request: R) {
        self.request = request
        self.config = TaskConfig()
        self.dependencies = []
    }

    // MARK: - Dependency Configuration

    /// 设置依赖节点（该节点将在依赖节点完成后执行）
    /// - Parameter nodes: 依赖的节点 ID
    /// - Returns: 新的节点
    public func after(_ nodes: AnyHashable...) -> OrchestratorNode {
        var newNode = self
        newNode.dependencies = nodes
        return newNode
    }

    // MARK: - Task Configuration

    /// 设置生命周期
    public func lifecycle(_ lifecycle: Lifecycle) -> OrchestratorNode {
        var newNode = self
        newNode.config.lifecycle = lifecycle
        return newNode
    }

    /// 设置缓存策略
    public func cache(_ policy: CachePolicy) -> OrchestratorNode {
        var newNode = self
        newNode.config.cache = policy
        return newNode
    }

    /// 设置重试策略
    public func retry(_ policy: RetryPolicy) -> OrchestratorNode {
        var newNode = self
        newNode.config.retry = policy
        return newNode
    }

    /// 设置单次请求超时
    public func timeout(_ interval: TimeInterval) -> OrchestratorNode {
        var newNode = self
        newNode.config.timeout = interval
        return newNode
    }

    /// 设置整体超时（包含所有重试）
    public func totalTimeout(_ interval: TimeInterval) -> OrchestratorNode {
        var newNode = self
        newNode.config.totalTimeout = interval
        return newNode
    }

    /// 设置防抖
    public func debounce(_ interval: TimeInterval) -> OrchestratorNode {
        var newNode = self
        newNode.config.control.debounce = interval
        return newNode
    }

    /// 设置节流
    public func throttle(_ interval: TimeInterval) -> OrchestratorNode {
        var newNode = self
        newNode.config.control.throttle = interval
        return newNode
    }

    /// 设置去重
    public func deduplicate() -> OrchestratorNode {
        var newNode = self
        newNode.config.control.deduplicate = true
        return newNode
    }

    /// 设置优先级
    public func priority(_ priority: ControlPolicy.Priority) -> OrchestratorNode {
        var newNode = self
        newNode.config.control.priority = priority
        return newNode
    }
}

// MARK: - Result Builder

/// 编排构建器
///
/// 使用 Result Builder 语法构建编排计划
@resultBuilder
public struct OrchestratorBuilder {
    public static func buildBlock<R1: Request>(
        _ node1: (id: AnyHashable, node: OrchestratorNode<R1>)
    ) -> OrchestratorPlan<R1.Response> {
        let rawNodes = [
            RawOrchestratorNode(id: node1.id, node: node1.node)
        ]
        let transform: ([AnyHashable: Any]) throws -> R1.Response = { results in
            guard let result = results[node1.id] as? R1.Response else {
                throw NetworkError.unknown(NSError(domain: "OrchestratorBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract result for node: \(node1.id)"]))
            }
            return result
        }
        return OrchestratorPlan(rawNodes: rawNodes, transform: transform)
    }

    public static func buildBlock<R1: Request, R2: Request>(
        _ node1: (id: AnyHashable, node: OrchestratorNode<R1>),
        _ node2: (id: AnyHashable, node: OrchestratorNode<R2>)
    ) -> OrchestratorPlan<(R1.Response, R2.Response)> {
        let rawNodes = [
            RawOrchestratorNode(id: node1.id, node: node1.node),
            RawOrchestratorNode(id: node2.id, node: node2.node)
        ]
        let transform: ([AnyHashable: Any]) throws -> (R1.Response, R2.Response) = { results in
            guard let result1 = results[node1.id] as? R1.Response,
                  let result2 = results[node2.id] as? R2.Response else {
                throw NetworkError.unknown(NSError(domain: "OrchestratorBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract results"]))
            }
            return (result1, result2)
        }
        return OrchestratorPlan(rawNodes: rawNodes, transform: transform)
    }

    public static func buildBlock<R1: Request, R2: Request, R3: Request>(
        _ node1: (id: AnyHashable, node: OrchestratorNode<R1>),
        _ node2: (id: AnyHashable, node: OrchestratorNode<R2>),
        _ node3: (id: AnyHashable, node: OrchestratorNode<R3>)
    ) -> OrchestratorPlan<(R1.Response, R2.Response, R3.Response)> {
        let rawNodes = [
            RawOrchestratorNode(id: node1.id, node: node1.node),
            RawOrchestratorNode(id: node2.id, node: node2.node),
            RawOrchestratorNode(id: node3.id, node: node3.node)
        ]
        let transform: ([AnyHashable: Any]) throws -> (R1.Response, R2.Response, R3.Response) = { results in
            guard let result1 = results[node1.id] as? R1.Response,
                  let result2 = results[node2.id] as? R2.Response,
                  let result3 = results[node3.id] as? R3.Response else {
                throw NetworkError.unknown(NSError(domain: "OrchestratorBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract results"]))
            }
            return (result1, result2, result3)
        }
        return OrchestratorPlan(rawNodes: rawNodes, transform: transform)
    }

    // MARK: - 4 节点支持

    public static func buildBlock<R1: Request, R2: Request, R3: Request, R4: Request>(
        _ node1: (id: AnyHashable, node: OrchestratorNode<R1>),
        _ node2: (id: AnyHashable, node: OrchestratorNode<R2>),
        _ node3: (id: AnyHashable, node: OrchestratorNode<R3>),
        _ node4: (id: AnyHashable, node: OrchestratorNode<R4>)
    ) -> OrchestratorPlan<(R1.Response, R2.Response, R3.Response, R4.Response)> {
        let rawNodes = [
            RawOrchestratorNode(id: node1.id, node: node1.node),
            RawOrchestratorNode(id: node2.id, node: node2.node),
            RawOrchestratorNode(id: node3.id, node: node3.node),
            RawOrchestratorNode(id: node4.id, node: node4.node)
        ]
        let transform: ([AnyHashable: Any]) throws -> (R1.Response, R2.Response, R3.Response, R4.Response) = { results in
            guard let result1 = results[node1.id] as? R1.Response,
                  let result2 = results[node2.id] as? R2.Response,
                  let result3 = results[node3.id] as? R3.Response,
                  let result4 = results[node4.id] as? R4.Response else {
                throw NetworkError.unknown(NSError(domain: "OrchestratorBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract results"]))
            }
            return (result1, result2, result3, result4)
        }
        return OrchestratorPlan(rawNodes: rawNodes, transform: transform)
    }

    // MARK: - 5 节点支持

    public static func buildBlock<R1: Request, R2: Request, R3: Request, R4: Request, R5: Request>(
        _ node1: (id: AnyHashable, node: OrchestratorNode<R1>),
        _ node2: (id: AnyHashable, node: OrchestratorNode<R2>),
        _ node3: (id: AnyHashable, node: OrchestratorNode<R3>),
        _ node4: (id: AnyHashable, node: OrchestratorNode<R4>),
        _ node5: (id: AnyHashable, node: OrchestratorNode<R5>)
    ) -> OrchestratorPlan<(R1.Response, R2.Response, R3.Response, R4.Response, R5.Response)> {
        let rawNodes = [
            RawOrchestratorNode(id: node1.id, node: node1.node),
            RawOrchestratorNode(id: node2.id, node: node2.node),
            RawOrchestratorNode(id: node3.id, node: node3.node),
            RawOrchestratorNode(id: node4.id, node: node4.node),
            RawOrchestratorNode(id: node5.id, node: node5.node)
        ]
        let transform: ([AnyHashable: Any]) throws -> (R1.Response, R2.Response, R3.Response, R4.Response, R5.Response) = { results in
            guard let result1 = results[node1.id] as? R1.Response,
                  let result2 = results[node2.id] as? R2.Response,
                  let result3 = results[node3.id] as? R3.Response,
                  let result4 = results[node4.id] as? R4.Response,
                  let result5 = results[node5.id] as? R5.Response else {
                throw NetworkError.unknown(NSError(domain: "OrchestratorBuilder", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to extract results"]))
            }
            return (result1, result2, result3, result4, result5)
        }
        return OrchestratorPlan(rawNodes: rawNodes, transform: transform)
    }
}
