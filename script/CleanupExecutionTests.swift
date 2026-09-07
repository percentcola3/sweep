import Foundation

@main
struct CleanupExecutionTests {
    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        if !condition() {
            throw NSError(domain: "CleanupExecutionTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
    }

    static func main() throws {
        let complete = CleanupExecutionResult.reconciled(
            bridgeOutput: "removed=3\nskipped=2\nfailed=1\n", expectedCount: 6)
        try expect(complete == CleanupExecutionResult(removed: 3, skipped: 2, failed: 1),
                   "bridge counters were not preserved")

        let unreported = CleanupExecutionResult.reconciled(
            bridgeOutput: "removed=1\nskipped=1\n", expectedCount: 4)
        try expect(unreported == CleanupExecutionResult(removed: 1, skipped: 1, failed: 2),
                   "unreported submitted items must fail closed")

        let invalid = CleanupExecutionResult.reconciled(
            bridgeOutput: "removed=-1\nskipped=nope\nfailed=0\n", expectedCount: 2)
        try expect(invalid == CleanupExecutionResult(removed: 0, skipped: 0, failed: 2),
                   "invalid bridge counters must not claim success")

        var aggregate = CleanupExecutionResult(skipped: 4)
        aggregate.merge(complete)
        try expect(aggregate == CleanupExecutionResult(removed: 3, skipped: 6, failed: 1),
                   "runtime skips and route results were not aggregated separately")
    }
}
