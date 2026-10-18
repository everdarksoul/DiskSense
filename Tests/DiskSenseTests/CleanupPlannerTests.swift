import Foundation
import Testing
@testable import DiskSense

struct CleanupPlannerTests {
    private func item(_ path: String, _ bytes: Int64, _ kind: JunkItem.Kind = .devCache) -> JunkItem {
        JunkItem(name: URL(fileURLWithPath: path).lastPathComponent, path: path, bytes: bytes, kind: kind, note: "Generated test data")
    }

    @Test func reachesGoalUsingLargestCandidatesAndStops() {
        let plan = CleanupPlanner.makePlan(from: [item("/cache/small", 20), item("/cache/medium", 40), item("/cache/large", 80)], goalBytes: 100)
        #expect(plan.candidates.map(\.bytes) == [80, 40])
        #expect(plan.proposedBytes == 120)
        #expect(plan.reachesGoal)
        #expect(plan.shortfallBytes == 0)
    }

    @Test func reportsShortfallWithoutAddingUnrelatedKinds() {
        let plan = CleanupPlanner.makePlan(from: [item("/cache/one", 40), item("/cache/two", 20, .buildArtifacts), item("/app/support", 1_000, .orphaned), item("/logs", 1_000, .logs), item("/trash", 1_000, .trash)], goalBytes: 100)
        #expect(plan.proposedBytes == 60)
        #expect(plan.shortfallBytes == 40)
        #expect(!plan.reachesGoal)
        #expect(plan.candidates.count == 2)
    }

    @Test func overlappingAndDuplicatePathsAreCountedOnce() {
        let inputs = [item("/cache/tools", 90), item("/cache/tools/child", 120), item("/cache/tools/./", 80), item("/cache/tools-extra", 30)]
        let plan = CleanupPlanner.makePlan(from: inputs, goalBytes: 1_000)
        #expect(plan.candidates.map(\.path) == ["/cache/tools", "/cache/tools-extra"])
        #expect(plan.proposedBytes == 120)
    }

    @Test func tiesAndSignaturesAreIndependentOfInputOrder() {
        let inputs = [item("/cache/z", 50), item("/cache/a", 50), item("/cache/b", 50)]
        let forward = CleanupPlanner.makePlan(from: inputs, goalBytes: 80)
        let reverse = CleanupPlanner.makePlan(from: Array(inputs.reversed()), goalBytes: 80)
        #expect(forward.candidates.map(\.path) == ["/cache/a", "/cache/b"])
        #expect(forward.candidates.map(\.path) == reverse.candidates.map(\.path))
        #expect(forward.sourceSignature == reverse.sourceSignature)
        #expect(CleanupPlanner.signature(of: [item("/cache/a", 51)]) != CleanupPlanner.signature(of: [item("/cache/a", 50)]))
    }

    @Test func nonpositiveGoalsAndCandidateSizesProduceNoInvalidPlans() {
        let inputs = [item("/cache/valid", 50), item("/cache/zero", 0), item("/cache/negative", -10), item("relative/path", 200)]
        #expect(CleanupPlanner.makePlan(from: inputs, goalBytes: 0).candidates.isEmpty)
        #expect(CleanupPlanner.makePlan(from: inputs, goalBytes: -1).goalBytes == 0)
        #expect(CleanupPlanner.makePlan(from: inputs, goalBytes: 100).proposedBytes == 50)
    }

    @Test func corruptHugeMeasurementsDoNotOverflow() {
        #expect(CleanupPlanner.totalBytes([item("/cache/one", Int64.max), item("/cache/two", 100)]) == Int64.max)
    }
}
