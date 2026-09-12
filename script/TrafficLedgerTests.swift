import Foundation

private struct TrafficTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
private enum TrafficLedgerTests {
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func main() throws {
        try testBaselineAndNewConnections()
        try testAggregationAndHistory()
        try testRestartResetAndRestore()
        try testOlderConnectionsAndPartialResponses()
        try testUnknownExitAndAppIdentity()
        try testEndpointLimit()
        try testAppTrafficSorting()
        print("traffic ledger tests passed (7 scenarios)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        if !condition() { throw TrafficTestFailure(description: message) }
    }

    private static func connection(_ id: String, down: UInt64, up: UInt64 = 0,
                                    host: String = "example.test", chains: [String]? = ["Node", "Auto"],
                                    rule: String = "Domain", start: Date = epoch) -> ClashAPI.Connection {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ClashAPI.Connection(
            id: id,
            metadata: .init(network: "tcp", type: "HTTP", sourceIP: "127.0.0.1",
                            sourcePort: "50000", destinationIP: "203.0.113.10",
                            destinationPort: "443", host: host, process: nil, processPath: nil),
            upload: up, download: down, start: formatter.string(from: start),
            chains: chains, rule: rule, rulePayload: "example.test")
    }

    private static func sample(_ ledger: inout TrafficLedger, total: UInt64, up: UInt64 = 0,
                               _ connections: [ClashAPI.Connection]?,
                               apps: [String: String] = [:], seconds: TimeInterval = 0) {
        ledger.ingest(payload: .init(downloadTotal: total, uploadTotal: up, connections: connections),
                      appKeys: apps, at: epoch.addingTimeInterval(seconds))
    }

    private static func testBaselineAndNewConnections() throws {
        var ledger = TrafficLedger(startedAt: epoch)
        sample(&ledger, total: 1_000, [connection("old", down: 800)], apps: ["old": "browser"])
        try expect(ledger.sessionDown == 0 && ledger.apps["browser"]?.down == 0,
                   "first snapshot must not charge pre-session bytes")
        sample(&ledger, total: 1_150, [connection("old", down: 850), connection("new", down: 70)],
               apps: ["old": "browser", "new": "browser"], seconds: 2)
        try expect(ledger.apps["browser"]?.nodeDown == 120,
                   "existing delta plus the new connection's first frame must be recorded")
        try expect(ledger.sessionDown == 150 && ledger.unattributedDown == 30,
                   "short connections missed between polls must remain unattributed")
        sample(&ledger, total: 1_150, [], seconds: 3)
        try expect(ledger.apps["browser"]?.down == 120, "closed connection totals must remain")
        try expect(ledger.endpointsByApp["browser"]?.first?.activeConnections == 0,
                   "closed destinations must remain as inactive history")
    }

    private static func testAggregationAndHistory() throws {
        var ledger = TrafficLedger(startedAt: epoch)
        sample(&ledger, total: 0, [])
        sample(&ledger, total: 250, up: 25,
               [connection("one", down: 100, up: 10), connection("two", down: 80, up: 8),
                connection("direct", down: 30, up: 3, chains: ["Group", "DIRECT"]),
                connection("other", down: 40, up: 4, host: "other.test")],
               apps: ["one": "browser", "two": "browser", "direct": "browser", "other": "browser"])
        try expect(ledger.apps["browser"]?.down == 250 && ledger.apps["browser"]?.up == 25,
                   "multiple processes/connections assigned to one app must aggregate")
        try expect(ledger.apps["browser"]?.directDown == 30
                   && ledger.apps["browser"]?.nodeDown == 220,
                   "DIRECT and node counters must remain distinct")
        let endpoints = ledger.endpointsByApp["browser"] ?? []
        try expect(endpoints.count == 3 && endpoints[0].down == 180
                   && endpoints[0].activeConnections == 2,
                   "same destination and chain must merge, ordered by total traffic")
        sample(&ledger, total: 250, up: 25, [], seconds: 2)
        try expect(ledger.endpointsByApp["browser"]?.count == 3,
                   "endpoint history must survive closed connections")
    }

    private static func testRestartResetAndRestore() throws {
        var ledger = TrafficLedger(startedAt: epoch)
        sample(&ledger, total: 0, [])
        sample(&ledger, total: 100, up: 20, [connection("one", down: 100, up: 20)],
               apps: ["one": "browser"])
        let data = try JSONEncoder().encode(ledger)
        var restored = try JSONDecoder().decode(TrafficLedger.self, from: data)
        sample(&restored, total: 150, up: 30, [connection("one", down: 150, up: 30)],
               apps: ["one": "browser"], seconds: 5)
        try expect(restored.sessionDown == 150 && restored.apps["browser"]?.down == 150,
                   "JSON restore must preserve both counters and baseline without double charging")
        try expect(restored.startedAt == epoch, "JSON restore must preserve session start")
        sample(&restored, total: 30, up: 2, [connection("restarted", down: 25, up: 2)],
               apps: ["restarted": "browser"], seconds: 6)
        try expect(restored.sessionDown == 180 && restored.sessionUp == 32,
                   "a core restart must include counters accumulated by the new core")
        try expect(restored.apps["browser"]?.down == 175 && restored.unattributedDown == 5,
                   "core restart must preserve prior history and expose unmatched bytes")
        restored.rebase()
        sample(&restored, total: 9_000, up: 700, [connection("different", down: 8_000)], seconds: 7)
        try expect(restored.sessionDown == 180, "switching controllers must not import lifetime totals")
        restored.reset(at: epoch.addingTimeInterval(8))
        sample(&restored, total: 9_050, up: 700, [connection("different", down: 8_050)], seconds: 9)
        try expect(restored.sessionDown == 0 && restored.apps.values.allSatisfy { $0.down == 0 },
                   "reset must establish a fresh baseline")
    }

    private static func testOlderConnectionsAndPartialResponses() throws {
        var ledger = TrafficLedger(startedAt: epoch)
        sample(&ledger, total: 1_000, [])
        sample(&ledger, total: 1_100,
               [connection("old", down: 900, start: epoch.addingTimeInterval(-100))],
               apps: ["old": "browser"])
        try expect(ledger.apps["browser"]?.down == 0 && ledger.unattributedDown == 100,
                   "late-observed old connection must not import pre-session bytes")
        sample(&ledger, total: 1_150, nil, seconds: 2)
        // A failed API request does not call ingest, leaving these baselines intact.
        sample(&ledger, total: 1_200, [connection("old", down: 970)],
               apps: ["old": "browser"], seconds: 10)
        try expect(ledger.apps["browser"]?.down == 70 && ledger.unattributedDown == 130,
                   "partial or failed responses must preserve connection baselines")

        var delayed = TrafficLedger(startedAt: epoch)
        sample(&delayed, total: 1_000, [], seconds: 20)
        sample(&delayed, total: 1_010,
               [connection("before-baseline", down: 900, start: epoch.addingTimeInterval(10))],
               apps: ["before-baseline": "browser"], seconds: 21)
        try expect(delayed.apps["browser"]?.down == 0 && delayed.unattributedDown == 10,
                   "newly observed connections must use the actual core baseline time window")
    }

    private static func testUnknownExitAndAppIdentity() throws {
        var ledger = TrafficLedger(startedAt: epoch)
        sample(&ledger, total: 0, [connection("baseline", down: 0, chains: nil)])
        sample(&ledger, total: 35,
               [connection("baseline", down: 10, chains: nil),
                connection("empty", down: 20, chains: []), connection("unknown", down: 5)],
               apps: ["baseline": "browser", "empty": "browser"])
        try expect(ledger.apps["browser"]?.unknownDown == 30
                   && ledger.apps["browser"]?.nodeDown == 0,
                   "missing or empty chains must never be labeled node traffic")
        try expect(ledger.apps[TrafficLedger.unknownAppKey]?.nodeDown == 5,
                   "connections without app attribution still retain their exit and bytes")
        sample(&ledger, total: 45, [connection("unknown", down: 15)], apps: ["unknown": "browser"])
        try expect(ledger.apps[TrafficLedger.unknownAppKey]?.nodeDown == 15,
                   "an already-charged connection must retain stable app attribution")
    }

    private static func testEndpointLimit() throws {
        var ledger = TrafficLedger(maxEndpointsPerApp: 1, startedAt: epoch)
        sample(&ledger, total: 0, [])
        sample(&ledger, total: 150,
               [connection("one", down: 10), connection("two", down: 20, host: "two.test"),
                connection("three", down: 30, host: "three.test"),
                connection("direct", down: 40, chains: ["DIRECT"]),
                connection("unknown", down: 50, chains: [])],
               apps: ["one": "browser", "two": "browser", "three": "browser",
                      "direct": "browser", "unknown": "browser"])
        let endpoints = ledger.endpointsByApp["browser"] ?? []
        try expect(endpoints.count == 4 && endpoints.filter(\.isOverflow).count == 3,
                   "endpoint retention must be bounded with separate exit overflow buckets")
        try expect(endpoints.reduce(UInt64(0)) { $0 + $1.down } == 150
                   && ledger.apps["browser"]?.down == 150,
                   "endpoint eviction must never lose app traffic")
        try expect(endpoints.first?.down == 50, "overflow history participates in traffic ordering")
    }

    private static func testAppTrafficSorting() throws {
        func row(_ appKey: String, sampledDown: UInt64 = 0, sampledUp: UInt64 = 0,
                 nodeDown: UInt64 = 0, nodeUp: UInt64 = 0,
                 directDown: UInt64 = 0, directUp: UInt64 = 0,
                 unknownDown: UInt64 = 0, unknownUp: UInt64 = 0) -> TrafficAppRow {
            TrafficAppRow(appKey: appKey, displayName: appKey, bundleIdentifier: nil,
                          representativePID: 0, sessionDown: sampledDown, sessionUp: sampledUp,
                          rateDown: 0, rateUp: 0, proxyDirectDown: directDown,
                          proxyDirectUp: directUp, proxyNodeDown: nodeDown, proxyNodeUp: nodeUp,
                          proxyUnknownDown: unknownDown, proxyUnknownUp: unknownUp,
                          connectionCount: 0, exitKinds: [])
        }
        let nodeHeavy = row("proxy-heavy", sampledDown: 100, nodeDown: 400, nodeUp: 200)
        let directHeavy = row("direct-heavy", sampledDown: 200, nodeDown: 100,
                              directDown: 500, directUp: 200)
        let sampledHeavy = row("sample-heavy", sampledDown: 700, sampledUp: 300,
                               nodeDown: 300, directDown: 20)
        let unknownHeavy = row("unknown-heavy", sampledDown: 50, nodeDown: 20,
                               unknownDown: 650, unknownUp: 250)
        let rows = [sampledHeavy, nodeHeavy, unknownHeavy, directHeavy]
        try expect(TrafficSortOrder.proxyNode.sorted(rows).map(\.appKey)
                   == ["proxy-heavy", "sample-heavy", "direct-heavy", "unknown-heavy"],
                   "node ranking must sort upload plus download, excluding DIRECT and unknown")
        try expect(TrafficSortOrder.clashTotal.sorted(rows).map(\.appKey)
                   == ["unknown-heavy", "direct-heavy", "proxy-heavy", "sample-heavy"],
                   "Clash ranking must include node, DIRECT and unknown exit bytes only")
        try expect(TrafficSortOrder.appTotal.sorted(rows).map(\.appKey)
                   == ["sample-heavy", "direct-heavy", "proxy-heavy", "unknown-heavy"],
                   "app ranking must use system-sampled upload plus download independently")

        let overlap = row("overlap", sampledDown: 100, nodeDown: 100)
        let largerSample = row("larger-sample", sampledDown: 150)
        let largerProxy = row("larger-proxy", nodeDown: 150)
        try expect(TrafficSortOrder.appTotal.sorted([overlap, largerSample]).first?.appKey
                   == "larger-sample", "sample and Clash observations must not be added for app ranking")
        try expect(TrafficSortOrder.clashTotal.sorted([overlap, largerProxy]).first?.appKey
                   == "larger-proxy", "sample and Clash observations must not be added for Clash ranking")
        try expect(TrafficSortOrder.proxyNode.sorted([overlap, largerProxy]).first?.appKey
                   == "larger-proxy", "sample and Clash observations must not be added for node ranking")
    }
}
