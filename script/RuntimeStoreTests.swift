import Foundation

private struct RuntimeStoreTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RuntimeStoreTests {
    static func main() throws {
        let text = """
        100\t1\tMon_Aug_31_10:00:00_2026\t10.0\t1.0\t/AppOne\t/Applications/AppOne.app/Contents/MacOS/AppOne
        101\t100\tMon_Aug_31_10:00:01_2026\t20.0\t2.0\t/Helper\t/Applications/AppOne.app/Contents/Frameworks/Helper
        102\t101\tMon_Aug_31_10:00:02_2026\t5.0\t3.0\t/Worker\tworker
        200\t1\tMon_Aug_31_10:00:03_2026\t2.5\t4.0\t/AppTwo\t/Applications/AppTwo.app/Contents/MacOS/AppTwo
        300\t1\tMon_Aug_31_10:00:04_2026\t99.0\t9.0\t/Other\tother
        """
        let usage = RuntimeStore.usageByApplicationPID(Set([100, 200]),
                                                       fromProcessText: text)
        try expect(usage[100]?.cpu == 35.0 && usage[100]?.mem == 6.0,
                   "AppOne did not include its nested helper processes")
        try expect(usage[200]?.cpu == 2.5 && usage[200]?.mem == 4.0,
                   "AppTwo resource usage was not preserved")
        try expect(usage[300] == nil && usage.count == 2,
                   "unrelated process leaked into an application total")

        // The upgraded bridge includes UID, process state and elapsed time. Keep
        // abnormal PIDs visible ahead of high-CPU normal processes.
        let lifecycleText = """
        4100\t4200\t501\tMon_Aug_31_10:01:00_2026\tZE\t00:03\t0.1\t0.1\t/Zombie\t/Applications/Test.app/Zombie
        4101\t1\t501\tMon_Aug_31_10:01:01_2026\tSE\t1-02:03:04\t0.2\t0.2\t/Exiting\t/Applications/Test.app/Exiting
        4102\t1\t501\tMon_Aug_31_10:01:02_2026\tX\t00:05\t99.0\t0.3\t/Traced\t/Applications/Test.app/Traced
        4103\t1\t501\tMon_Aug_31_10:01:03_2026\tT\t00:06\t98.0\t0.4\t/Stopped\t/Applications/Test.app/Stopped
        4104\t1\t501\tMon_Aug_31_10:01:04_2026\tU\t00:07\t97.0\t0.5\t/Waiting\t/Applications/Test.app/Waiting
        4105\t1\t501\tMon_Aug_31_10:01:05_2026\tSZ\t00:08\t96.0\t0.6\t/NotZombie\t/Applications/Test.app/NotZombie
        4106\t1\t501\tMon_Aug_31_10:01:06_2026\tS\t00:09\t95.0\t0.7\t/Orphan\t/Applications/Test.app/Orphan
        """
        let lifecycleRows = RuntimeStore.rows(fromProcessText: lifecycleText, advanced: true)
        let lifecycleByPID = Dictionary(uniqueKeysWithValues: lifecycleRows.map { ($0.pid, $0) })
        try expect(lifecycleRows.prefix(2).map(\.lifecycle) == [.zombie, .exiting],
                   "advanced PID rows did not prioritize abnormal lifecycle states")
        try expect(lifecycleByPID[4100]?.lifecycle == .zombie,
                   "a state beginning with Z was not classified as zombie")
        try expect(lifecycleByPID[4101]?.lifecycle == .exiting,
                   "the additional E state flag was not classified as exiting")
        for pid in [4102, 4103, 4104, 4105, 4106] {
            try expect(lifecycleByPID[Int32(pid)]?.lifecycle == .normal,
                       "state for PID \(pid) was falsely classified as abnormal")
        }
        try expect(lifecycleByPID[4100]?.ppid == 4200 && lifecycleByPID[4100]?.uid == 501,
                   "new process metadata was not preserved")
        try expect(lifecycleByPID[4101]?.state == "SE" &&
                   lifecycleByPID[4101]?.elapsed == 93_784,
                   "state or ps elapsed time was not parsed")

        let legacyRows = RuntimeStore.rows(fromProcessText: text, advanced: true)
        try expect(!legacyRows.isEmpty && legacyRows.allSatisfy {
            $0.lifecycle == .normal && $0.uid == UInt32.max && $0.elapsed == 0
        }, "legacy seven-column process output lost compatibility")

        let firstLaunch = ProcessRow(pid: 500, startIdentity: "first", name: "App",
                                     detail: "", isNativeApp: true, cpu: 0, mem: 0,
                                     memBytes: 0)
        let reusedPID = ProcessRow(pid: 500, startIdentity: "second", name: "App",
                                   detail: "", isNativeApp: true, cpu: 0, mem: 0,
                                   memBytes: 0)
        try expect(firstLaunch.signalToken != reusedPID.signalToken,
                   "process icon identity did not change after PID reuse")

        func process(pid: Int32, start: String, state: String,
                     ppid: Int32 = 1) -> ProcessRow {
            ProcessRow(pid: pid, startIdentity: start, name: "test", detail: "",
                       isNativeApp: false, cpu: 0, mem: 0, memBytes: 0,
                       ppid: ppid, uid: 501, state: state, elapsed: 60)
        }

        var tracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        let zombie = process(pid: 500, start: "first", state: "Z")
        try expect(zombie.staleCleanupToken == "500|first|1|501",
                   "stale cleanup token did not bind parent and user identity")
        try expect(tracker.candidates(in: [zombie]).isEmpty,
                   "zombie was returned before two consecutive snapshots")
        let zombieCandidates = tracker.candidates(in: [zombie])
        try expect(zombieCandidates.map(\.signalToken) == [zombie.signalToken],
                   "zombie was not returned on the second consecutive snapshot")
        let stillPending = tracker.candidates(in: [zombie])
        try expect(stillPending.map(\.signalToken) == [zombie.signalToken],
                   "candidate was marked attempted before the caller selected it")
        tracker.markAttempted(stillPending)
        try expect(tracker.candidates(in: [zombie]).isEmpty,
                   "an attempted zombie token was returned more than once")
        _ = tracker.candidates(in: [process(pid: 500, start: "first", state: "R")])
        _ = tracker.candidates(in: [zombie])
        try expect(tracker.candidates(in: [zombie]).map(\.signalToken) ==
                   [zombie.signalToken],
                   "normal state did not clear the attempted token for a later retry")

        let resetZombie = process(pid: 501, start: "stable", state: "Z")
        _ = tracker.candidates(in: [resetZombie])
        _ = tracker.candidates(in: [process(pid: 501, start: "stable", state: "S")])
        try expect(tracker.candidates(in: [resetZombie]).isEmpty,
                   "normal state did not clear the zombie observation count")
        try expect(tracker.candidates(in: [resetZombie]).map(\.signalToken) ==
                   [resetZombie.signalToken],
                   "zombie was not returned after a fresh two-snapshot sequence")

        let oldExiting = process(pid: 502, start: "old", state: "SE")
        let reusedExiting = process(pid: 502, start: "new", state: "SE")
        _ = tracker.candidates(in: [oldExiting])
        _ = tracker.candidates(in: [oldExiting])
        try expect(tracker.candidates(in: [reusedExiting]).isEmpty,
                   "PID reuse inherited the previous process observation count")
        try expect(tracker.candidates(in: [reusedExiting]).isEmpty,
                   "exiting process was returned before three consecutive snapshots")
        let exitingCandidates = tracker.candidates(in: [reusedExiting])
        try expect(exitingCandidates.map(\.signalToken) == [reusedExiting.signalToken],
                   "exiting process was not returned on its third stable snapshot")
        tracker.markAttempted(exitingCandidates)
        try expect(tracker.candidates(in: [reusedExiting]).isEmpty,
                   "an attempted exiting token was returned more than once")

        let interruptedZombie = process(pid: 503, start: "interrupted", state: "Z")
        _ = tracker.candidates(in: [interruptedZombie])
        _ = tracker.candidates(in: [])
        try expect(tracker.candidates(in: [interruptedZombie]).isEmpty,
                   "a missing snapshot did not clear the consecutive observation count")
        try expect(tracker.candidates(in: [interruptedZombie]).map(\.signalToken) ==
                   [interruptedZombie.signalToken],
                   "zombie was not returned after two new consecutive snapshots")

        let originalParent = process(pid: 505, start: "same-process", state: "Z", ppid: 700)
        let newParent = process(pid: 505, start: "same-process", state: "Z", ppid: 701)
        _ = tracker.candidates(in: [originalParent])
        try expect(tracker.candidates(in: [newParent]).isEmpty,
                   "a parent change inherited the previous zombie observation count")
        let reparentedCandidates = tracker.candidates(in: [newParent])
        try expect(reparentedCandidates.map(\.staleCleanupToken) ==
                   [newParent.staleCleanupToken],
                   "a reparented zombie was not returned after a fresh stable sequence")

        var gapTracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        let gapZombie = process(pid: 506, start: "gap", state: "Z")
        _ = gapTracker.candidates(in: [gapZombie], now: 100)
        try expect(gapTracker.candidates(in: [gapZombie], now: 110).isEmpty,
                   "a stale snapshot count survived a long sampling gap")
        try expect(gapTracker.candidates(in: [gapZombie], now: 112).map(\.signalToken) ==
                   [gapZombie.signalToken],
                   "sampling did not restart after a long gap")

        var failedScanTracker = RuntimeStore.AutomaticCandidateTracker(currentUID: 501)
        let failedScanZombie = process(pid: 507, start: "failed-scan", state: "Z")
        _ = failedScanTracker.candidates(in: [failedScanZombie], now: 200)
        failedScanTracker.breakSequence()
        try expect(failedScanTracker.candidates(in: [failedScanZombie], now: 202).isEmpty,
                   "a failed scan did not interrupt consecutive observations")
        let afterFailure = failedScanTracker.candidates(in: [failedScanZombie], now: 204)
        try expect(afterFailure.map(\.signalToken) == [failedScanZombie.signalToken],
                   "sampling did not restart after a failed scan")
        failedScanTracker.markAttempted(afterFailure)
        failedScanTracker.breakSequence()
        _ = failedScanTracker.candidates(in: [failedScanZombie], now: 206)
        try expect(failedScanTracker.candidates(in: [failedScanZombie], now: 208).isEmpty,
                   "a failed scan cleared the already-attempted safety token")

        let otherUserZombie = ProcessRow(
            pid: 504, startIdentity: "other-user", name: "test", detail: "",
            isNativeApp: false, cpu: 0, mem: 0, memBytes: 0,
            ppid: 1, uid: 502, state: "Z", elapsed: 60)
        _ = tracker.candidates(in: [otherUserZombie])
        try expect(tracker.candidates(in: [otherUserZombie]).isEmpty,
                   "automatic tracker returned another user's process")

        let sixteenGiB = UInt64(16) * 1_024 * 1_024 * 1_024
        try expect(ByteFormat.memoryShort(sixteenGiB) == "16G",
                   "16 GiB physical memory was not rendered as 16G")

        let pageSize = UInt64(4_096)
        let memoryUsage = SystemMetrics.normalizedMemoryUsage(
            totalBytes: pageSize * 100,
            pageSize: pageSize,
            internalPages: 70,
            purgeablePages: 20,
            wiredPages: 10,
            compressedPages: 5)
        try expect(memoryUsage.usedBytes == pageSize * 65 && memoryUsage.percent == 65,
                   "memory usage did not exclude purgeable/file-cache pages")
        let clamped = SystemMetrics.normalizedMemoryUsage(
            totalBytes: pageSize * 100,
            pageSize: pageSize,
            internalPages: UInt64.max,
            purgeablePages: 0,
            wiredPages: UInt64.max,
            compressedPages: UInt64.max)
        try expect(clamped.usedBytes == pageSize * 100 && clamped.percent == 100,
                   "memory usage was not clamped to physical memory")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw RuntimeStoreTestFailure(description: message) }
    }
}
