import Foundation

/// Only controller counters are recorded here. Core totals and observed connections
/// remain separate: bytes missed between polls must never be presented as direct traffic.
struct TrafficLedger: Codable, Sendable {
    static let unknownAppKey = "traffic:unknown"

    enum ExitKind: String, Codable, Sendable { case direct, node, unknown }

    struct AppTotals: Codable, Equatable, Sendable {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var directDown: UInt64 = 0
        var directUp: UInt64 = 0
        var nodeDown: UInt64 = 0
        var nodeUp: UInt64 = 0
        var unknownDown: UInt64 = 0
        var unknownUp: UInt64 = 0

        fileprivate mutating func add(down: UInt64, up: UInt64, kind: ExitKind) {
            self.down = TrafficLedger.add(self.down, down)
            self.up = TrafficLedger.add(self.up, up)
            switch kind {
            case .direct:
                directDown = TrafficLedger.add(directDown, down)
                directUp = TrafficLedger.add(directUp, up)
            case .node:
                nodeDown = TrafficLedger.add(nodeDown, down)
                nodeUp = TrafficLedger.add(nodeUp, up)
            case .unknown:
                unknownDown = TrafficLedger.add(unknownDown, down)
                unknownUp = TrafficLedger.add(unknownUp, up)
            }
        }
    }

    struct Endpoint: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let appKey: String
        let remote: String
        let proto: String
        let host: String?
        let chains: [String]
        let rule: String
        let kind: ExitKind
        var down: UInt64 = 0
        var up: UInt64 = 0
        var firstSeen: Date
        var lastSeen: Date
        var activeConnections: Int = 0
        let isOverflow: Bool
    }

    private struct Counters: Codable, Sendable {
        var down: UInt64
        var up: UInt64
    }

    private struct ConnectionBaseline: Codable, Sendable {
        var counters: Counters
        var appKey: String
        var hasRecordedBytes: Bool
    }

    private(set) var startedAt: Date
    private(set) var lastSampleAt: Date?
    private(set) var sessionDown: UInt64 = 0
    private(set) var sessionUp: UInt64 = 0
    private(set) var apps: [String: AppTotals] = [:]
    private var observedDown: UInt64 = 0
    private var observedUp: UInt64 = 0
    private var coreBaseline: Counters?
    private var accountingStartedAt: Date?
    private var connections: [String: ConnectionBaseline] = [:]
    private var endpointTotals: [String: [String: Endpoint]] = [:]
    private let maxEndpointsPerApp: Int

    var unattributedDown: UInt64 { sessionDown > observedDown ? sessionDown - observedDown : 0 }
    var unattributedUp: UInt64 { sessionUp > observedUp ? sessionUp - observedUp : 0 }

    /// Closed connections remain in this descending history; at most the configured
    /// ordinary destinations plus one overflow bucket for each exit kind per app.
    var endpointsByApp: [String: [Endpoint]] {
        endpointTotals.mapValues { entries in
            entries.values.sorted {
                let left = Self.add($0.down, $0.up)
                let right = Self.add($1.down, $1.up)
                return left == right ? $0.id < $1.id : left > right
            }
        }
    }

    init(maxEndpointsPerApp: Int = 200, startedAt: Date = Date()) {
        self.maxEndpointsPerApp = max(0, maxEndpointsPerApp)
        self.startedAt = startedAt
    }

    mutating func reset(at date: Date = Date()) {
        self = Self(maxEndpointsPerApp: maxEndpointsPerApp, startedAt: date)
    }

    /// Used when switching controllers. The next successful sample establishes a
    /// new baseline while already recorded history remains available.
    mutating func rebase() {
        coreBaseline = nil
        accountingStartedAt = nil
        connections.removeAll()
        clearActiveConnections()
    }

    /// Call only after a successful /connections response. Keeping the baselines
    /// through failed requests and JSON persistence lets the next response catch up.
    mutating func ingest(payload: ClashAPI.ConnectionsPayload,
                         appKeys: [String: String], at date: Date = Date()) {
        let isFirstSample = coreBaseline == nil
        let restarted = coreBaseline.map {
            payload.downloadTotal < $0.down || payload.uploadTotal < $0.up
        } ?? false
        if isFirstSample { accountingStartedAt = date }
        if let previous = coreBaseline {
            sessionDown = Self.add(sessionDown, restarted
                                  ? payload.downloadTotal : payload.downloadTotal - previous.down)
            sessionUp = Self.add(sessionUp, restarted
                                ? payload.uploadTotal : payload.uploadTotal - previous.up)
        }
        coreBaseline = Counters(down: payload.downloadTotal, up: payload.uploadTotal)
        lastSampleAt = date
        clearActiveConnections()
        if restarted { connections.removeAll() }

        // A payload without connection details can still advance core counters.
        // Do not discard existing baselines on this partial response.
        guard let snapshot = payload.connections else { return }
        var current: [String: ConnectionBaseline] = [:]
        for connection in snapshot {
            // IDs are unique in mihomo. Ignore duplicate entries in a malformed response.
            guard current[connection.id] == nil else { continue }
            let previous = connections[connection.id]
            let candidateKey = appKeys[connection.id].flatMap { $0.isEmpty ? nil : $0 }
                ?? Self.unknownAppKey
            // Preserve an identity once bytes were charged to it. A baseline-only
            // unknown connection can still adopt subsequently discovered process info.
            let appKey = previous.map {
                $0.appKey == Self.unknownAppKey && !$0.hasRecordedBytes
                    ? candidateKey : $0.appKey
            } ?? candidateKey
            let down: UInt64
            let up: UInt64
            if isFirstSample {
                down = 0
                up = 0
            } else if let previous {
                // Per-connection counters can also reset; conservatively baseline
                // that direction instead of charging an uncertain lifetime value.
                down = connection.download >= previous.counters.down
                    ? connection.download - previous.counters.down : 0
                up = connection.upload >= previous.counters.up
                    ? connection.upload - previous.counters.up : 0
            } else if Self.connectionStarted(connection.start,
                                             since: accountingStartedAt ?? startedAt) {
                down = connection.download
                up = connection.upload
            } else {
                // A late-observed connection may predate this monitoring session.
                // Its unobservable session portion remains in the core difference.
                down = 0
                up = 0
            }
            let kind: ExitKind = connection.isDirectExit ? .direct
                : (connection.chains?.isEmpty == false ? .node : .unknown)
            var totals = apps[appKey] ?? AppTotals()
            totals.add(down: down, up: up, kind: kind)
            apps[appKey] = totals
            observedDown = Self.add(observedDown, down)
            observedUp = Self.add(observedUp, up)
            recordEndpoint(connection, appKey: appKey, kind: kind,
                           down: down, up: up, at: date)
            current[connection.id] = ConnectionBaseline(
                counters: Counters(down: connection.download, up: connection.upload),
                appKey: appKey,
                hasRecordedBytes: previous?.hasRecordedBytes == true || down > 0 || up > 0)
        }
        connections = current
    }

    private mutating func clearActiveConnections() {
        for appKey in Array(endpointTotals.keys) {
            Self.clearActiveConnections(in: &endpointTotals[appKey, default: [:]])
        }
    }

    private static func clearActiveConnections(in entries: inout [String: Endpoint]) {
        for endpointKey in Array(entries.keys) {
            entries[endpointKey]?.activeConnections = 0
        }
    }

    private mutating func recordEndpoint(_ connection: ClashAPI.Connection,
                                         appKey: String, kind: ExitKind,
                                         down: UInt64, up: UInt64, at date: Date) {
        let host = connection.metadata.host.flatMap { $0.isEmpty ? nil : $0 }
        let address = host ?? connection.metadata.destinationIP ?? "?"
        let port = connection.metadata.destinationPort ?? ""
        let remote = port.isEmpty ? address
            : (address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)")
        let proto = (connection.metadata.network ?? "").uppercased()
        let chains = connection.chains ?? []
        let rule = [connection.rule, connection.rulePayload].compactMap { $0 }
            .filter { !$0.isEmpty }.joined(separator: " · ")
        // Length prefixes avoid collisions between user-controlled names and separators.
        let id = Self.key([appKey, remote, proto, kind.rawValue,
                           connection.rule ?? "", connection.rulePayload ?? ""] + chains)
        // Pass the stored dictionary by reference. Taking a local value copy here
        // would copy every retained destination for each active connection.
        Self.recordEndpoint(id: id, appKey: appKey, remote: remote, proto: proto,
                            host: host, chains: chains, rule: rule, kind: kind,
                            down: down, up: up, at: date, limit: maxEndpointsPerApp,
                            entries: &endpointTotals[appKey, default: [:]])
    }

    private static func recordEndpoint(id: String, appKey: String, remote: String,
                                        proto: String, host: String?, chains: [String],
                                        rule: String, kind: ExitKind, down: UInt64,
                                        up: UInt64, at date: Date, limit: Int,
                                        entries: inout [String: Endpoint]) {
        let overflow = entries[id] == nil
            && entries.values.lazy.filter({ !$0.isOverflow }).count >= limit
        let entryID = overflow ? Self.key([appKey, "overflow", kind.rawValue]) : id
        var entry = entries[entryID] ?? Endpoint(
            id: entryID, appKey: appKey, remote: overflow ? "" : remote,
            proto: overflow ? "" : proto, host: overflow ? nil : host,
            chains: overflow ? [] : chains, rule: overflow ? "" : rule, kind: kind,
            firstSeen: date, lastSeen: date, isOverflow: overflow)
        entry.down = Self.add(entry.down, down)
        entry.up = Self.add(entry.up, up)
        entry.lastSeen = date
        entry.activeConnections += 1
        entries[entryID] = entry
    }

    private static func connectionStarted(_ value: String, since date: Date) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let start = formatter.date(from: value) { return start >= date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value).map { $0 >= date } ?? false
    }

    private static func key(_ values: [String]) -> String {
        values.map { "\($0.utf8.count):\($0)" }.joined()
    }

    private static func add(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (result, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : result
    }
}
