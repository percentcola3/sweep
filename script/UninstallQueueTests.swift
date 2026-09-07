import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func app(_ name: String, path: String? = nil,
                 bundleID: String? = nil, identity: String = "1:2:3") -> UninstallApp {
    UninstallApp(name: name, bundleID: bundleID ?? "com.example.\(name)",
                 source: "App", path: path ?? "/Applications/\(name).app", size: "1 MB",
                 appIdentity: identity, infoIdentity: "1:4:5")
}

private func plan(_ name: String, needsAdmin: Bool = false,
                  isBrewCask: Bool = false, protected: Bool = true) -> UninstallPlan {
    UninstallPlan(files: [UninstallFile(bytes: 1_024, label: "app",
                                       path: "/Applications/\(name).app")],
                  needsAdmin: needsAdmin, isBrewCask: isBrewCask,
                  caskToken: isBrewCask ? name.lowercased() : "-",
                  includesProtectedAppData: protected,
                  scannedAt: Date(timeIntervalSince1970: 1_000))
}

/// An intentionally suspended fake bridge: no filesystem or process changes.
/// The MainActor can enqueue more work while the single worker awaits completion.
@MainActor
private final class AsyncQueueHarness {
    var queue = UninstallQueue()
    private var worker: Task<Void, Never>?
    private var completion: CheckedContinuation<Bool, Never>?
    private var suspensionWaiter: CheckedContinuation<Void, Never>?
    private var idleWaiter: CheckedContinuation<Void, Never>?
    private(set) var starts: [UUID] = []
    private(set) var finishes: [UUID] = []
    private(set) var inFlight = 0
    private(set) var maximumInFlight = 0

    @discardableResult
    func enqueue(_ name: String) -> UUID {
        let id = queue.enqueue(app: app(name), plan: plan(name))!
        startWorker()
        return id
    }

    func startWorker() {
        guard worker == nil, let job = queue.startNext(blocked: false) else { return }
        starts.append(job.id)
        inFlight += 1
        maximumInFlight = max(maximumInFlight, inFlight)
        worker = Task { @MainActor in
            let succeeded = await withCheckedContinuation { continuation in
                completion = continuation
                suspensionWaiter?.resume()
                suspensionWaiter = nil
            }
            expect(queue.finish(job.id, succeeded: succeeded, message: "fake result"),
                   "only the active fake job can finish")
            finishes.append(job.id)
            inFlight -= 1
            worker = nil
            startWorker()
            if worker == nil {
                idleWaiter?.resume()
                idleWaiter = nil
            }
        }
    }

    func waitUntilSuspended() async {
        if completion != nil { return }
        await withCheckedContinuation { suspensionWaiter = $0 }
    }

    func completeCurrent(succeeded: Bool) {
        let current = completion
        completion = nil
        expect(current != nil, "fake worker must be suspended before completing")
        current?.resume(returning: succeeded)
    }

    func waitUntilIdle() async {
        if worker == nil { return }
        await withCheckedContinuation { idleWaiter = $0 }
    }
}

@main
struct UninstallQueueTests {
    @MainActor
    static func main() async {
        testFIFOAndSharedGate()
        testDuplicatePathAndCancellation()
        testRequestSnapshot()
        testHistoryAndRestart()
        await testAsyncWorker()
        print("Uninstall queue tests passed")
    }

    private static func testFIFOAndSharedGate() {
        var queue = UninstallQueue()
        let first = queue.enqueue(app: app("First"), plan: plan("First"))!
        let second = queue.enqueue(app: app("Second"), plan: nil)!
        expect(queue.hasPendingJobs && queue.hasWork, "enqueued work must be visible")
        expect(queue.startNext(blocked: true) == nil && queue.activeJob == nil,
               "another disk operation must block execution, not enqueueing")
        expect(queue.jobs.map(\.state) == [.queued, .queued],
               "a shared busy gate must not consume a pending job")
        expect(queue.startNext(blocked: false)?.id == first, "worker must start FIFO")
        expect(queue.activeJob?.state == .running, "cached preview starts in running state")
        expect(queue.startNext(blocked: false) == nil, "an active worker must exclude another")
        expect(!queue.markRunning(second) && !queue.finish(second, succeeded: true, message: "wrong"),
               "pending work cannot be marked active or finished by a different callback")
        expect(queue.finish(first, succeeded: false, message: "route changed"),
               "active failure must be recorded")
        expect(queue.jobs.first?.message == "route changed", "failure reason must remain visible")
        expect(!queue.finish(first, succeeded: true, message: "late callback"),
               "a late callback must not rewrite completed state")
        expect(queue.startNext(blocked: false)?.id == second, "failure must not stall the next job")
        expect(queue.activeJob?.state == .preparing, "missing preview must prepare before apply")
        expect(queue.markRunning(second) && queue.activeJob?.state == .running,
               "only the active preparation may advance to running")
        expect(queue.finish(second, succeeded: true, message: "done"), "second job should complete")
        expect(!queue.hasWork && !queue.hasPendingJobs && queue.activeJob == nil,
               "finished history must not hold the shared gate")
    }

    private static func testDuplicatePathAndCancellation() {
        var queue = UninstallQueue()
        let firstApp = app("Same")
        let first = queue.enqueue(app: firstApp, plan: plan("Same"))!
        let alias = app("ChangedID", path: "/Applications/Temporary/../Same.app",
                        bundleID: "com.example.replaced", identity: "9:8:7")
        expect(queue.containsPendingOrActive(alias), "deduplication must use normalized path")
        expect(queue.enqueue(app: alias, plan: nil) == nil,
               "a changed bundle identity at the same path must not add duplicate work")
        expect(queue.enqueue(app: app("NoIdentity", identity: ""), plan: nil) == nil,
               "an identity-less app cannot enter a destructive queue")
        let pending = queue.enqueue(app: app("Pending"), plan: nil)!
        _ = queue.startNext(blocked: false)
        expect(!queue.cancel(first), "active removal must not be cancelled via pending cancellation")
        expect(queue.cancel(pending) && !queue.jobs.contains { $0.id == pending },
               "pending cancellation must remove only the requested job")
        expect(!queue.cancel(pending), "repeated cancellation should not affect any other job")
        expect(queue.enqueue(app: firstApp, plan: nil) == nil, "running path must stay deduplicated")
        _ = queue.finish(first, succeeded: false, message: "retry allowed")
        expect(!queue.cancel(first), "completed history cannot be cancelled as pending work")
        let retry = queue.enqueue(app: firstApp, plan: plan("Same"))!
        expect(retry != first && queue.jobs.count == 1 && queue.jobs[0].id == retry,
               "an explicit retry gets a new request and replaces that app's old history")
    }

    private static func testRequestSnapshot() {
        var queue = UninstallQueue()
        var selectedApp = app("A", identity: "1:100:200")
        var selectedPlan = plan("A", needsAdmin: true, isBrewCask: true, protected: false)
        let originalApp = selectedApp
        let originalPlan = selectedPlan
        let first = queue.enqueue(app: selectedApp, plan: selectedPlan)!
        selectedApp = app("B", identity: "2:300:400")
        selectedPlan = plan("B", protected: true)
        _ = queue.enqueue(app: selectedApp, plan: selectedPlan)
        let running = queue.startNext(blocked: false)!
        expect(running.id == first && running.app == originalApp && running.plan == originalPlan,
               "later selection must not replace the confirmed app or preview snapshot")
        expect(running.app.appIdentity == "1:100:200" && running.app.infoIdentity == "1:4:5",
               "queued apply must retain both bound filesystem identities")
        expect(running.plan?.needsAdmin == true && running.plan?.isBrewCask == true
                && running.plan?.caskToken == "a" && running.plan?.includesProtectedAppData == false,
               "cask route and protected-data coverage must remain part of this request")
    }

    private static func testHistoryAndRestart() {
        var queue = UninstallQueue()
        var finishedIDs: [UUID] = []
        for index in 0..<12 {
            let id = queue.enqueue(app: app("History\(index)"), plan: nil)!
            finishedIDs.append(id)
            expect(queue.startNext(blocked: false)?.id == id, "history fixture must stay FIFO")
            _ = queue.finish(id, succeeded: index.isMultiple(of: 2), message: "history \(index)")
        }
        expect(queue.jobs.count == 8 && queue.jobs.map(\.id) == Array(finishedIDs.suffix(8)),
               "only the latest eight finished jobs should be retained")
        let active = queue.enqueue(app: app("Active"), plan: nil)!
        _ = queue.startNext(blocked: false)
        let pending = queue.enqueue(app: app("Waiting"), plan: nil)!
        queue.dismissFinished()
        expect(queue.jobs.map(\.id) == [active, pending],
               "dismissing history must preserve both active and pending work")
        let restarted = UninstallQueue()
        expect(restarted.jobs.isEmpty && !restarted.hasWork,
               "a new instance must not resume prior destructive confirmations")
    }

    @MainActor
    private static func testAsyncWorker() async {
        let harness = AsyncQueueHarness()
        let first = harness.enqueue("SlowFirst")
        await harness.waitUntilSuspended()
        let second = harness.enqueue("SecondWhileBusy")
        expect(harness.queue.jobs.first { $0.id == second }?.state == .queued,
               "the UI actor must accept another request while the first bridge is suspended")
        for _ in 0..<10 { harness.startWorker() }
        expect(harness.starts == [first] && harness.inFlight == 1,
               "repeated wakeups must not launch duplicate workers")
        harness.completeCurrent(succeeded: true)
        await harness.waitUntilSuspended()
        expect(harness.starts == [first, second], "completion must immediately advance FIFO")
        let third = harness.enqueue("ThirdAfterFailure")
        harness.completeCurrent(succeeded: false)
        await harness.waitUntilSuspended()
        expect(harness.starts == [first, second, third], "a failed async job must not stop FIFO")
        harness.completeCurrent(succeeded: true)
        await harness.waitUntilIdle()
        expect(harness.maximumInFlight == 1 && harness.inFlight == 0,
               "asynchronous execution must never exceed one destructive worker")
        expect(harness.finishes == [first, second, third] && !harness.queue.hasWork,
               "all accepted async requests must finish once and in order")
        expect(harness.queue.jobs.map(\.state) == [.succeeded, .failed, .succeeded],
               "per-job outcomes must remain independent")
    }
}
