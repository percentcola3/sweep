import Foundation

private struct TrafficStoreTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
@MainActor
private enum TrafficStoreTests {
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let endpoint = "http://127.0.0.1:9090"
    private static let browser = "app:test.browser"
    private static let directApp = "app:test.direct"
    private static let localTool = "comm:local-tool"

    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("traffic-store-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testRestoreAggregationAndCards(at: root.appendingPathComponent("restore.json"))
        try testResetPersists(at: root.appendingPathComponent("reset.json"))
        try testOtherControllerHistory(at: root.appendingPathComponent("other-controller.json"))
        print("traffic store tests passed (3 offline scenarios)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw TrafficStoreTestFailure(description: message) }
    }

    private static func defaults(endpoint overrideEndpoint: String? = nil) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: "traffic-store-tests.\(UUID().uuidString)") else {
            throw TrafficStoreTestFailure(description: "cannot create isolated defaults")
        }
        // Registration stays in memory; tests never change the user's preferences.
        defaults.register(defaults: ["SMNetMonPersistent": false,
                                     "SMNetMonClashEndpoint": overrideEndpoint ?? endpoint])
        return defaults
    }

    private static func connection(_ id: String, down: UInt64, chains: [String]?) -> ClashAPI.Connection {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ClashAPI.Connection(id: id,
            metadata: .init(network: "tcp", sourceIP: "127.0.0.1", sourcePort: "50000",
                            destinationIP: "203.0.113.10", destinationPort: "443", host: "example.test"),
            upload: down / 10, download: down,
            start: formatter.string(from: epoch.addingTimeInterval(1)), chains: chains,
            rule: "Domain", rulePayload: "example.test")
    }

    /// Encode the real ledger and only assemble the private store envelope as JSON.
    private static func writeHistory(to url: URL) throws {
        var ledger = TrafficLedger(startedAt: epoch)
        ledger.ingest(payload: .init(downloadTotal: 1_000, uploadTotal: 100, connections: []),
                      appKeys: [:], at: epoch)
        ledger.ingest(payload: .init(downloadTotal: 1_500, uploadTotal: 150, connections: [
            connection("browser-main", down: 100, chains: ["Node", "Auto"]),
            connection("browser-helper", down: 50, chains: ["Node", "Auto"]),
            connection("browser-direct", down: 80, chains: ["DIRECT"]),
            connection("browser-unknown-exit", down: 30, chains: nil),
            connection("unknown-app", down: 60, chains: ["Node"]),
            connection("direct-app", down: 120, chains: ["DIRECT"]),
        ]), appKeys: ["browser-main": browser, "browser-helper": browser,
                      "browser-direct": browser, "browser-unknown-exit": browser,
                      "direct-app": directApp], at: epoch.addingTimeInterval(2))
        let encodedLedger = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ledger))
        func accumulator(_ name: String, down: UInt64, up: UInt64) -> [String: Any] {
            ["down": down, "up": up, "rateDown": 99.0, "rateUp": 9.0,
             "name": name, "representativePID": 123, "seen": epoch.timeIntervalSinceReferenceDate]
        }
        let history: [String: Any] = [
            "version": 1, "endpoint": endpoint, "ledger": encodedLedger,
            "appTotals": [browser: accumulator("Browser", down: 300, up: 30),
                          directApp: accumulator("Direct App", down: 1_000, up: 100),
                          localTool: accumulator("Local Tool", down: 7_000, up: 700)],
            "names": [browser: "Browser", directApp: "Direct App", localTool: "Local Tool"],
            "tunnelDown": 900, "tunnelUp": 90, "physicalDown": 1_200, "physicalUp": 120,
        ]
        try JSONSerialization.data(withJSONObject: history).write(to: url, options: .atomic)
    }

    private static func testRestoreAggregationAndCards(at url: URL) throws {
        try writeHistory(to: url)
        let testDefaults = try defaults()
        let store = TrafficMonitorStore(defaults: testDefaults, historyURL: url)
        try expect(!store.persistentMonitoring && !store.sampling && store.lastSample == nil,
                   "restoration must not start live sampling")
        try expect(!store.historySaveFailed && store.sessionStartedAt == epoch,
                   "valid history and its session start were not restored")
        try expect(store.rows.count == 4 && store.rows.filter { $0.appKey == browser }.count == 1,
                   "main and helper connections must restore into one application row")
        guard let browserRow = store.rows.first(where: { $0.appKey == browser }) else {
            throw TrafficStoreTestFailure(description: "missing restored browser")
        }
        try expect(browserRow.proxyNodeDown == 150 && browserRow.proxyDirectDown == 80
                   && browserRow.proxyUnknownDown == 30 && browserRow.clashTotal == 286
                   && browserRow.sampledTotal == 330,
                   "restored browser counters must aggregate helpers without adding the OS sample")
        try expect(store.rows.allSatisfy { $0.rateDown == 0 && $0.rateUp == 0
                                        && $0.representativePID == 0 && $0.connectionCount == 0 },
                   "restored history must not advertise stale rates, PIDs or live connections")
        let targets = store.endpointsByApp[browser] ?? []
        try expect(targets.count == 3 && targets.allSatisfy { $0.activeConnections == 0 }
                   && targets.first(where: { $0.kind == .proxyNode })?.clashDown == 150,
                   "merged destination history must restore with inactive connections")

        // 60 unknown-app + 30 known-app unknown-exit + 60 missed core bytes = 150.
        try expect(store.nodeDown == 150 && store.nodeUp == 15
                   && store.directDown == 200 && store.directUp == 20
                   && store.unattributedDown == 150 && store.unattributedUp == 15,
                   "top cards must classify unknown app, unknown exit and core gap exactly once")
        try expect(store.nodeDown + store.directDown + store.unattributedDown == store.clashSessionDown
                   && store.nodeUp + store.directUp + store.unattributedUp == store.clashSessionUp
                   && store.clashSessionDown == 500 && store.clashSessionUp == 50,
                   "the three mutually exclusive cards must reconcile with the Clash session")
        try expect(store.tunnelDown == 900 && store.physicalDown == 1_200,
                   "interface references must restore independently of Clash accounting")

        try expect(store.rows.map(\.appKey) == [browser, TrafficLedger.unknownAppKey, directApp, localTool],
                   "default ranking must use node traffic only")
        store.sortOrder = .clashTotal
        try expect(store.rows.map(\.appKey) == [browser, directApp, TrafficLedger.unknownAppKey, localTool],
                   "Clash ranking must use its own totals")
        store.sortOrder = .appTotal
        try expect(store.rows.map(\.appKey) == [localTool, directApp, browser, TrafficLedger.unknownAppKey],
                   "application ranking must use OS samples independently of Clash totals")

        store.flushHistoryForTermination()
        let restored = TrafficMonitorStore(defaults: testDefaults, historyURL: url)
        try expect(restored.clashSessionDown == 500 && restored.nodeDown == 150
                   && restored.unattributedDown == 150 && restored.rows.count == 4,
                   "store save and restore must preserve accounting without double charging")
    }

    private static func testResetPersists(at url: URL) throws {
        try writeHistory(to: url)
        let testDefaults = try defaults()
        let store = TrafficMonitorStore(defaults: testDefaults, historyURL: url)
        let resetTime = Date()
        store.resetSession()
        store.flushHistoryForTermination()
        try expect(store.rows.isEmpty && store.endpointsByApp.isEmpty
                   && store.clashSessionDown == 0 && store.clashSessionUp == 0,
                   "reset must clear application and destination accounting")
        let restored = TrafficMonitorStore(defaults: testDefaults, historyURL: url)
        try expect(restored.rows.isEmpty && restored.endpointsByApp.isEmpty
                   && restored.nodeDown == 0 && restored.nodeUp == 0
                   && restored.directDown == 0 && restored.directUp == 0
                   && restored.unattributedDown == 0 && restored.unattributedUp == 0
                   && restored.tunnelDown == 0 && restored.tunnelUp == 0
                   && restored.physicalDown == 0 && restored.physicalUp == 0
                   && restored.clashSessionDown == 0 && restored.clashSessionUp == 0,
                   "saved reset must not resurrect any historical totals on restart")
        try expect(!restored.historySaveFailed && restored.sessionStartedAt >= resetTime,
                   "reset session start must be persisted")
    }

    private static func testOtherControllerHistory(at url: URL) throws {
        try writeHistory(to: url)
        let store = TrafficMonitorStore(defaults: try defaults(endpoint: "http://127.0.0.1:9091"),
                                        historyURL: url)
        try expect(store.rows.isEmpty && store.clashSessionDown == 0 && store.endpointsByApp.isEmpty,
                   "history from another controller must not contaminate this controller")
    }
}
