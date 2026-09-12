import Foundation

/// Item-level result returned by one or more cleanup bridges. Accounting is
/// reconciled against the immutable plan so missing bridge counters cannot be
/// presented as successful deletion.
struct CleanupExecutionResult: Equatable {
    var removed: Int = 0
    var skipped: Int = 0
    var failed: Int = 0
    /// Only paths whose deletion was confirmed by the executor. Skips and
    /// failures must remain available for retry with their original identity.
    var removedPaths: Set<String> = []

    mutating func merge(_ other: CleanupExecutionResult) {
        removed += other.removed
        skipped += other.skipped
        failed += other.failed
        removedPaths.formUnion(other.removedPaths)
    }

    func remainingPaths(in paths: [String]) -> [String] {
        paths.filter { path in
            !removedPaths.contains { removed in
                path == removed || path.hasPrefix(removed + "/")
            }
        }
    }

    static func reconciled(bridgeOutput: String, expectedCount: Int) -> CleanupExecutionResult {
        var reportedRemoved = 0
        var reportedSkipped = 0
        var reportedFailed = 0
        for line in bridgeOutput.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Int(parts[1]), value >= 0 else { continue }
            switch parts[0] {
            case "removed": reportedRemoved = value
            case "skipped": reportedSkipped = value
            case "failed": reportedFailed = value
            default: break
            }
        }

        let expected = max(0, expectedCount)
        let removed = min(reportedRemoved, expected)
        let skipped = min(reportedSkipped, expected - removed)
        let failedCapacity = expected - removed - skipped
        let reportedFailure = min(reportedFailed, failedCapacity)
        // A bridge that exits without accounting for a submitted item has not
        // proven either deletion or a deliberate skip, so fail closed.
        let unreportedFailure = failedCapacity - reportedFailure
        return CleanupExecutionResult(
            removed: removed,
            skipped: skipped,
            failed: reportedFailure + unreportedFailure)
    }
}
