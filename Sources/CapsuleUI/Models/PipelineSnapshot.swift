import Foundation
import SharedInfrastructure

/// Complete snapshot of a pipeline execution with all stages
public struct PipelineSnapshot: Sendable, Identifiable {
    public let id: UUID
    public let generatedAt: Date
    public let inputText: String
    public let config: ConfigRoot.Capsule
    public let stages: [PipelineStage]
    public let totalDuration: TimeInterval
    public let success: Bool

    public init(
        id: UUID = UUID(),
        generatedAt: Date = Date(),
        inputText: String,
        config: ConfigRoot.Capsule,
        stages: [PipelineStage],
        totalDuration: TimeInterval,
        success: Bool
    ) {
        self.id = id
        self.generatedAt = generatedAt
        self.inputText = inputText
        self.config = config
        self.stages = stages
        self.totalDuration = totalDuration
        self.success = success
    }

    /// Find stage by type (returns first occurrence)
    public func stage(ofType type: PipelineStageType) -> PipelineStage? {
        stages.first { $0.type == type }
    }

    /// Check if all stages completed successfully
    public var allStagesSuccessful: Bool {
        stages.allSatisfy { $0.isSuccessful }
    }

    /// Get aggregate metrics
    public var aggregateMetrics: AggregateMetrics {
        AggregateMetrics(
            totalStages: stages.count,
            successfulStages: stages.filter { $0.isSuccessful }.count,
            failedStages: stages.filter { !$0.isSuccessful }.count,
            totalDuration: totalDuration,
            averageStageDuration: totalDuration / Double(max(stages.count, 1)),
            slowestStage: stages.max(by: { $0.metrics.duration < $1.metrics.duration })?.type
        )
    }
}

/// Aggregate performance metrics for the entire pipeline
public struct AggregateMetrics: Sendable {
    public let totalStages: Int
    public let successfulStages: Int
    public let failedStages: Int
    public let totalDuration: TimeInterval
    public let averageStageDuration: TimeInterval
    public let slowestStage: PipelineStageType?

    public init(
        totalStages: Int,
        successfulStages: Int,
        failedStages: Int,
        totalDuration: TimeInterval,
        averageStageDuration: TimeInterval,
        slowestStage: PipelineStageType?
    ) {
        self.totalStages = totalStages
        self.successfulStages = successfulStages
        self.failedStages = failedStages
        self.totalDuration = totalDuration
        self.averageStageDuration = averageStageDuration
        self.slowestStage = slowestStage
    }
}
