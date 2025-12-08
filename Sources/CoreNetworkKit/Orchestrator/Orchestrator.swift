import Foundation
import MLoggerKit

/// DAG 执行器
///
/// 负责执行编排计划，支持：
/// - 拓扑排序确定执行顺序
/// - 同层级并发执行
/// - 依赖管理
/// - 失败策略处理
public final class Orchestrator {
    private let logger = LoggerFactory.network
    private let executor: TaskExecutor

    // MARK: - Initialization

    public init(executor: TaskExecutor) {
        self.executor = executor
    }

    // MARK: - Public Methods

    /// 执行 DAG 编排
    /// - Parameters:
    ///   - plan: 编排计划
    ///   - failureStrategy: 失败策略
    /// - Returns: 编排结果
    /// - Throws: NetworkError
    public func execute<T>(
        plan: OrchestratorPlan<T>,
        failureStrategy: FailureStrategy
    ) async throws -> T {
        logger.debug("[Orchestrator] Starting DAG execution with \(plan.nodes.count) nodes")

        // 检查取消
        try Task.checkCancellation()

        // 1. 执行拓扑排序
        let layers = try topologicalSort(nodes: plan.nodes)
        logger.debug("[Orchestrator] Topology layers: \(layers.count)")

        // 2. 逐层执行
        var results: [AnyHashable: Any] = [:]
        var failedNodeIds: Set<AnyHashable> = []

        for (index, layer) in layers.enumerated() {
            try Task.checkCancellation()

            logger.debug("[Orchestrator] Executing layer \(index + 1)/\(layers.count) with \(layer.count) nodes")

            switch failureStrategy {
            case .failFast:
                do {
                    let layerResults = try await executeLayerFailFast(nodes: layer)
                    results.merge(layerResults) { _, new in new }
                } catch {
                    logger.error("[Orchestrator] Layer \(index + 1) failed: \(error)")
                    throw error
                }

            case .continueOnError:
                // 过滤掉依赖已失败的节点
                let runnableNodes = layer.filter { node in
                    node.dependencies.allSatisfy { !failedNodeIds.contains($0) && results[$0] != nil }
                }
                let skippedNodes = layer.filter { node in
                    !node.dependencies.allSatisfy { !failedNodeIds.contains($0) && results[$0] != nil }
                }

                // 标记被跳过的节点为失败
                for node in skippedNodes {
                    logger.warning("[Orchestrator] Skipping node '\(node.id)' due to failed dependencies")
                    failedNodeIds.insert(node.id)
                }

                if runnableNodes.isEmpty {
                    if !layer.isEmpty {
                        logger.warning("[Orchestrator] Layer \(index + 1) has no runnable nodes (all dependencies failed)")
                    }
                    continue
                }

                let (layerResults, layerErrors) = await executeLayerContinueOnError(nodes: runnableNodes)
                results.merge(layerResults) { _, new in new }
                failedNodeIds.formUnion(layerErrors.keys)

                // 如果整层都失败了，抛出错误
                if layerResults.isEmpty && !layerErrors.isEmpty {
                    let errorMessage = layerErrors.map { "\($0.key): \($0.value.localizedDescription)" }.joined(separator: ", ")
                    logger.error("[Orchestrator] All nodes in layer \(index + 1) failed: \(errorMessage)")
                    throw NetworkError.unknown(NSError(
                        domain: "Orchestrator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "All nodes in layer failed: \(errorMessage)"]
                    ))
                }
            }
        }

        // 3. 转换结果
        logger.debug("[Orchestrator] DAG execution completed, transforming results")
        return try plan.transform(results)
    }

    // MARK: - Private Methods

    /// 拓扑排序
    /// - Parameter nodes: 编排节点列表
    /// - Returns: 分层的节点列表（每层可并发执行）
    /// - Throws: NetworkError（如果存在循环依赖或无效依赖）
    private func topologicalSort(nodes: [AnyOrchestratorNode]) throws -> [[AnyOrchestratorNode]] {
        // 1. 检查重复 ID
        let ids = nodes.map(\.id)
        let uniqueIds = Set(ids)
        guard uniqueIds.count == nodes.count else {
            let duplicates = Dictionary(grouping: ids, by: { $0 })
                .filter { $0.value.count > 1 }
                .keys
            logger.error("[Orchestrator] Duplicate node IDs detected: \(duplicates)")
            throw NetworkError.unknown(NSError(
                domain: "Orchestrator",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Duplicate node IDs in orchestration graph: \(duplicates)"]
            ))
        }

        // 2. 检查依赖存在性
        let nodeMap = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            for dep in node.dependencies {
                guard nodeMap[dep] != nil else {
                    logger.error("[Orchestrator] Missing dependency: node '\(node.id)' depends on '\(dep)' which does not exist")
                    throw NetworkError.unknown(NSError(
                        domain: "Orchestrator",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Missing dependency: node '\(node.id)' depends on '\(dep)' which does not exist"]
                    ))
                }
            }
        }

        // 3. 拓扑排序（保持稳定顺序）
        var layers: [[AnyOrchestratorNode]] = []
        var remaining = Set(nodes)
        var completedIds = Set<AnyHashable>()

        while !remaining.isEmpty {
            // 找出所有依赖已满足的节点
            let currentLayer = remaining.filter { node in
                node.dependencies.allSatisfy { completedIds.contains($0) }
            }
            // 按 ID 排序以保持确定性
            .sorted { "\($0.id)" < "\($1.id)" }

            // 如果没有可执行的节点，说明存在循环依赖
            guard !currentLayer.isEmpty else {
                let remainingIds = remaining.map { $0.id }
                logger.error("[Orchestrator] Circular dependency detected among nodes: \(remainingIds)")
                throw NetworkError.unknown(NSError(
                    domain: "Orchestrator",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Circular dependency detected in orchestration graph among nodes: \(remainingIds)"]
                ))
            }

            // 添加到层级
            layers.append(currentLayer)

            // 更新状态
            currentLayer.forEach { node in
                remaining.remove(node)
                completedIds.insert(node.id)
            }
        }

        return layers
    }

    /// 执行单层节点（Fail-Fast 模式）
    /// - Parameter nodes: 当前层的节点
    /// - Returns: 执行结果字典
    /// - Throws: 任何节点的错误
    private func executeLayerFailFast(nodes: [AnyOrchestratorNode]) async throws -> [AnyHashable: Any] {
        try await withThrowingTaskGroup(of: (AnyHashable, Any).self) { group in
            // 并发启动所有节点
            for node in nodes {
                group.addTask {
                    let result = try await node.execute()
                    return (node.id, result)
                }
            }

            // 收集结果
            var results: [AnyHashable: Any] = [:]
            for try await (id, result) in group {
                results[id] = result
            }

            return results
        }
    }

    /// 执行单层节点（Continue-On-Error 模式）
    /// - Parameter nodes: 当前层的节点
    /// - Returns: (成功结果字典, 失败错误字典)
    private func executeLayerContinueOnError(nodes: [AnyOrchestratorNode]) async -> ([AnyHashable: Any], [AnyHashable: Error]) {
        await withTaskGroup(of: (AnyHashable, Result<Any, Error>).self) { group in
            // 并发启动所有节点
            for node in nodes {
                group.addTask {
                    do {
                        let value = try await node.execute()
                        return (node.id, Result<Any, Error>.success(value))
                    } catch {
                        return (node.id, Result<Any, Error>.failure(error))
                    }
                }
            }

            // 收集结果
            var results: [AnyHashable: Any] = [:]
            var errors: [AnyHashable: Error] = [:]

            for await (id, result) in group {
                switch result {
                case .success(let value):
                    results[id] = value
                case .failure(let error):
                    self.logger.warning("[Orchestrator] Node \(id) failed: \(error)")
                    errors[id] = error
                }
            }

            return (results, errors)
        }
    }
}
