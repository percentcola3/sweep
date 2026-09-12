import AppKit
import Combine
import Foundation

/// Clash 控制器连接状态。
enum TrafficClashState: Equatable {
    case notConfigured
    case ok
    case unauthorized
    case unreachable
    /// 本地代理连接与控制器观测不一致；不能据此确定具体原因。
    case stale
}

/// 流量监控编排：nettop 字节差分、lsof 端点快照、Clash/mihomo 控制器
/// 与路由归类全部在此汇聚成按应用聚合的发布状态。所有数据源只读，
/// 任一来源失败不影响其余来源继续工作。
@MainActor
final class TrafficMonitorStore: ObservableObject {
    @Published private(set) var rows: [TrafficAppRow] = []
    @Published private(set) var endpointsByApp: [String: [TrafficEndpointRow]] = [:]
    @Published private(set) var clashConnections: [ClashAPI.Connection] = []
    @Published var sortOrder: TrafficSortOrder = .proxyNode {
        didSet { rows = sortOrder.sorted(rows) }
    }
    @Published private(set) var nodeDown: UInt64 = 0
    @Published private(set) var nodeUp: UInt64 = 0
    @Published private(set) var directDown: UInt64 = 0
    @Published private(set) var directUp: UInt64 = 0
    @Published private(set) var unattributedDown: UInt64 = 0
    @Published private(set) var unattributedUp: UInt64 = 0
    @Published private(set) var sessionStartedAt = Date()
    @Published private(set) var historySaveFailed = false

    // 顶部汇总卡（会话 = 自上次重置累计）。
    @Published private(set) var tunnelDown: UInt64 = 0
    @Published private(set) var tunnelUp: UInt64 = 0
    @Published private(set) var physicalDown: UInt64 = 0
    @Published private(set) var physicalUp: UInt64 = 0
    @Published private(set) var clashSessionDown: UInt64 = 0
    @Published private(set) var clashSessionUp: UInt64 = 0
    /// 控制器自核心启动的累计值，包含 DIRECT，不能作为节点计费流量。
    @Published private(set) var clashCoreDown: UInt64 = 0
    @Published private(set) var clashCoreUp: UInt64 = 0

    @Published private(set) var sampling = false
    @Published private(set) var lastSample: Date?
    /// nettop 采样是否仍可用（失败时保留旧数据并提示）。
    @Published private(set) var bytesSourceAvailable = true
    @Published private(set) var clashState: TrafficClashState = .notConfigured

    /// 开启后即使不打开流量页也持续采样（后台记账用）。
    @Published var persistentMonitoring: Bool {
        didSet { defaults.set(persistentMonitoring, forKey: Self.persistentKey); syncPersistentTimer() }
    }
    /// `http://host:port` 或 `unix:/path/to.sock`。
    @Published var clashEndpoint: String {
        didSet {
            guard clashEndpoint != oldValue else { return }
            defaults.set(clashEndpoint, forKey: Self.endpointKey)
            // Keep recorded history; a new controller starts a fresh baseline.
            // Only the explicit Reset button discards the user's session.
            generation += 1
            ledger.rebase()
            clashConnections = []
            clashCoreDown = 0; clashCoreUp = 0
            clashState = clashEndpoint.isEmpty ? .notConfigured : .unreachable
            routeCache.removeAll()
            proxyClientByEndpoint.removeAll()
            flowAppByTuple.removeAll()
            lastPortDiscovery = .distantPast
            rebuildEndpoints(flows: [])
            rebuildRows()
            saveHistory(force: true)
        }
    }
    @Published var clashSecret: String {
        didSet { defaults.set(clashSecret, forKey: Self.secretKey) }
    }
    /// 发现到的本地代理端口（lsof 端点归类用）。
    @Published private(set) var mixedPort: Int?
    private var proxyPorts: Set<Int> = []

    private static let persistentKey = "SMNetMonPersistent"
    private static let endpointKey = "SMNetMonClashEndpoint"
    private static let secretKey = "SMNetMonClashSecret"
    private static let mixedPortKey = "SMNetMonMixedPort"
    private static let proxyPortsKey = "SMNetMonProxyPorts"

    private let defaults: UserDefaults
    private var inFlight = false
    private var persistentTimer: Timer?
    private var pageVisible = false
    private var generation = 0
    private let historyURL: URL
    private let historyQueue = DispatchQueue(label: "com.forgesweep.traffic-history", qos: .utility)
    private var lastHistorySave = Date.distantPast
    private var ledger = TrafficLedger()

    private struct AppAccumulator: Codable, Sendable {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var rateDown: Double = 0
        var rateUp: Double = 0
        var name: String
        var bundleIdentifier: String?
        var representativePID: Int32 = 0
        var seen: Date = .distantPast
    }

    private var appTotals: [String: AppAccumulator] = [:]
    private var lastProcessBytes: [Int32: (inbound: UInt64, outbound: UInt64)] = [:]
    private var lastSampleTime: Date?
    private var routeCache: [String: (interface: String, expires: Date)] = [:]
    private var lastBytesSampleTime: Date?
    private var lastProcessNames: [Int32: String] = [:]
    private var lastInterfaceCounters: [String: (inbound: UInt64, outbound: UInt64)] = [:]
    /// 进入代理端口的本地 socket（host:port → appKey）：Clash 连接的
    /// sourceIP:sourcePort 与它做连接级归因，不依赖 mihomo 的进程探测。
    private var proxyClientByEndpoint: [String: String] = [:]
    private var flowAppByTuple: [String: String] = [:]
    private var currentConnectionCounts: [String: Int] = [:]
    private var staleStrikes = 0
    private var bundleIdentities: [String: (key: String, name: String, bundleIdentifier: String?)] = [:]
    private var workspaceApps: [Int32: (bundleURL: URL, bundleIdentifier: String?,
                                        name: String)] = [:]
    private var processParents: [Int32: (ppid: Int32, comm: String, args: String)] = [:]
    /// appKey → 展示名（含从 Clash processPath 归因出的应用）。
    private var appDisplayNames: [String: String] = [:]

    init(defaults: UserDefaults = .standard, historyURL: URL? = nil) {
        self.defaults = defaults
        self.historyURL = historyURL ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/ForgeSweep/traffic-session.json")
        persistentMonitoring = defaults.bool(forKey: Self.persistentKey)
        clashEndpoint = defaults.string(forKey: Self.endpointKey) ?? ""
        clashSecret = defaults.string(forKey: Self.secretKey) ?? ""
        if let port = defaults.integer(forKey: Self.mixedPortKey) as Int?, (1...65535).contains(port) {
            mixedPort = port
            proxyPorts.insert(port)
        }
        for port in defaults.array(forKey: Self.proxyPortsKey) as? [Int] ?? [] where (1...65535).contains(port) {
            proxyPorts.insert(port)
        }
        restoreHistory()
        clashState = clashEndpoint.isEmpty ? .notConfigured : .unreachable
        if persistentMonitoring { syncPersistentTimer() }
    }

    // MARK: - 公共入口

    /// 由中央定时器（流量页可见时）驱动的一次采样。
    func tick() {
        guard !inFlight else { return }
        inFlight = true
        Task { [weak self] in
            await self?.sample()
            self?.inFlight = false
        }
    }

    func setPageVisible(_ visible: Bool) {
        pageVisible = visible
        syncPersistentTimer()
        if visible { tick() }
        else { saveHistory(force: true) }
    }

    /// Reset counters and baselines together; an already running sample may not
    /// publish pre-reset observations into the new session.
    func resetSession() {
        generation += 1
        ledger.reset(at: Date())
        appTotals.removeAll()
        lastProcessBytes.removeAll()
        lastProcessNames.removeAll()
        lastInterfaceCounters.removeAll()
        routeCache.removeAll()
        proxyClientByEndpoint.removeAll()
        flowAppByTuple.removeAll()
        currentConnectionCounts.removeAll()
        lastSampleTime = nil
        lastBytesSampleTime = nil
        tunnelDown = 0; tunnelUp = 0
        physicalDown = 0; physicalUp = 0
        clashCoreDown = 0; clashCoreUp = 0
        staleStrikes = 0
        rows = []
        endpointsByApp = [:]
        clashConnections = []
        publishLedger()
        saveHistory(force: true)
    }

    /// 自动发现本机 Clash/mihomo 控制器并落盘配置。
    @discardableResult
    func discoverClash() async -> Bool {
        let result = await MoleEngine.shared.runBridge("bin/app_netmon.sh",
                                                       arguments: ["discover"], timeout: 15)
        guard result.succeeded else { return false }
        let discovery = Parsers.clashDiscovery(result.output)
        applyDiscoveredPorts(discovery)
        if let unixEndpoint = discovery.endpoints.first(where: { $0.hasPrefix("unix:") })
            ?? discovery.endpoints.first {
            clashEndpoint = unixEndpoint
        }
        if let secret = discovery.secret { clashSecret = secret }
        return await testConnection()
    }

    func applyClashConfiguration(endpoint: String, secret: String) {
        clashSecret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        clashEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        lastPortDiscovery = .distantPast
    }

    /// 用当前配置打一次 /connections 验证连通性。
    @discardableResult
    func testConnection() async -> Bool {
        guard !clashEndpoint.isEmpty else {
            clashState = .notConfigured
            return false
        }
        let requestedGeneration = generation
        let result = await fetchClashConnections()
        guard requestedGeneration == generation else { return false }
        switch result {
        case .success: clashState = .ok
        case .unauthorized: clashState = .unauthorized
        case .unreachable: clashState = .unreachable
        }
        return clashState == .ok
    }

    // MARK: - 采样

    private enum ClashFetchResult {
        case success(ClashAPI.ConnectionsPayload)
        case unauthorized
        case unreachable
    }

    private func sample() async {
        sampling = true
        defer { sampling = false }
        let sampleGeneration = generation
        // The three OS snapshots can run independently. Fetch Clash immediately
        // afterwards, before route lookups, to narrow the attribution time gap.
        async let processesResult = MoleEngine.shared.runRuntime("processes", timeout: 10)
        async let byteSnapshot = MoleEngine.shared.runBridge("bin/app_netmon.sh", arguments: ["bytes"], timeout: 20)
        async let flowSnapshot = MoleEngine.shared.runBridge("bin/app_netmon.sh", arguments: ["flows"], timeout: 15)
        let (processes, bytesResult, flowsResult) = await (processesResult, byteSnapshot, flowSnapshot)
        guard sampleGeneration == generation else { return }
        if processes.succeeded { refreshProcessContext(processes.output) }
        let now = Date()
        let elapsed = lastSampleTime.map { max(now.timeIntervalSince($0), 0.001) } ?? 0
        let bytesElapsed = lastBytesSampleTime.map { max(now.timeIntervalSince($0), 0.001) } ?? 0
        var pidDeltas: [Int32: (inbound: UInt64, outbound: UInt64)] = [:]
        if bytesResult.succeeded {
            let samples = Parsers.netmonProcessSamples(bytesResult.output)
            bytesSourceAvailable = !samples.isEmpty
            if !samples.isEmpty {
                var current: [Int32: (inbound: UInt64, outbound: UInt64)] = [:]
                var names: [Int32: String] = [:]
                for row in samples {
                    current[row.pid] = (row.bytesIn, row.bytesOut)
                    names[row.pid] = row.command
                    guard let previous = lastProcessBytes[row.pid], lastProcessNames[row.pid] == row.command else { continue }
                    let down = row.bytesIn >= previous.inbound ? row.bytesIn - previous.inbound : 0
                    let up = row.bytesOut >= previous.outbound ? row.bytesOut - previous.outbound : 0
                    pidDeltas[row.pid] = (down, up)
                }
                lastProcessBytes = current
                lastProcessNames = names
                lastBytesSampleTime = now
            }
        } else {
            bytesSourceAvailable = false
        }
        let flows = flowsResult.succeeded ? Parsers.netmonFlows(flowsResult.output) : []
        await discoverMixedPortIfNeeded()
        guard sampleGeneration == generation else { return }
        rebuildProxyJoinMap(flows: flows)
        await sampleClash(flows: flows, generation: sampleGeneration)
        guard sampleGeneration == generation else { return }
        await sampleRoutes(for: flows, generation: sampleGeneration)
        guard sampleGeneration == generation else { return }
        sampleInterfaces(elapsed: elapsed)
        lastSampleTime = now
        accumulate(pidDeltas: pidDeltas, elapsed: bytesElapsed, flows: flows, samplesText: bytesResult.output)
        rebuildRows()
        lastSample = Date()
        saveHistory()
    }

    private func fetchClashConnections() async -> ClashFetchResult {
        guard !clashEndpoint.isEmpty else { return .unreachable }
        var environment: [String: String] = ["CLASH_ENDPOINT": clashEndpoint]
        if !clashSecret.isEmpty { environment["CLASH_SECRET"] = clashSecret }
        let result = await MoleEngine.shared.runBridge("bin/app_netmon.sh",
                                                       arguments: ["clash"],
                                                       extraEnvironment: environment,
                                                       timeout: 10)
        guard result.succeeded else {
            return result.output.localizedCaseInsensitiveContains("unauthorized")
                ? .unauthorized : .unreachable
        }
        let data = Data(result.output.utf8)
        guard let payload = ClashAPI.connections(from: data) else {
            return result.output.localizedCaseInsensitiveContains("unauthorized")
                ? .unauthorized : .unreachable
        }
        return .success(payload)
    }

    private func sampleClash(flows: [NetmonFlow], generation sampleGeneration: Int) async {
        guard !clashEndpoint.isEmpty else {
            clashState = .notConfigured
            clashConnections = []
            return
        }
        let result = await fetchClashConnections()
        guard sampleGeneration == generation else { return }
        switch result {
        case .success(let payload):
            clashConnections = (payload.connections ?? []).sorted {
                $0.download + $0.upload > $1.download + $1.upload
            }
            clashCoreDown = payload.downloadTotal
            clashCoreUp = payload.uploadTotal
            let hasProxySockets = flows.contains { exitKind(remote: $0.remote) == .proxy }
            if clashConnections.isEmpty && clashCoreDown == 0 && clashCoreUp == 0 && hasProxySockets {
                staleStrikes += 1
                clashState = staleStrikes >= 3 ? .stale : .ok
            } else {
                staleStrikes = 0
                clashState = .ok
            }
            let keys = Dictionary(clashConnections.map { ($0.id, clashAppKey($0)) }, uniquingKeysWith: { first, _ in first })
            ledger.ingest(payload: payload, appKeys: keys, at: Date())
            publishLedger()
        case .unauthorized:
            clashState = .unauthorized
            clashConnections = []
        case .unreachable:
            clashState = .unreachable
            clashConnections = []
        }
        // API errors retain accounting baselines and history. A later successful
        // response can recover increments for connections which are still alive.
    }

    /// Explicit proxy sockets join on source endpoint + protocol. TUN sockets
    /// additionally match the original destination; process metadata is fallback.
    private func clashAppKey(_ connection: ClashAPI.Connection) -> String {
        let metadata = connection.metadata
        if let ip = metadata.sourceIP, let port = metadata.sourcePort, let proto = metadata.network {
            let source = TrafficAttribution.socketKey(proto: proto, host: ip, port: port)
            if let key = proxyClientByEndpoint[source] { return key }
            if let destination = metadata.destinationIP, let destinationPort = metadata.destinationPort,
               let key = flowAppByTuple[source + "|\(TrafficAttribution.normalizedHost(destination))|\(destinationPort)"] {
                return key
            }
        }
        if let path = metadata.processPath, let identity = identityFromPath(path) { return identity.key }
        let process = metadata.processPath.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent }
            ?? metadata.process.flatMap { $0.isEmpty ? nil : $0 }
        guard let process else { return TrafficLedger.unknownAppKey }
        // Browser helper names with missing paths can still join if there is one
        // unambiguous owning application in the current process snapshot.
        let candidates = Set(processParents.compactMap { pid, record -> String? in
            guard (record.comm as NSString).lastPathComponent == process else { return nil }
            return appIdentity(pid: pid, commFallback: process).key
        })
        return candidates.count == 1 ? candidates.first! : "comm:\(process)"
    }

    private func rebuildProxyJoinMap(flows: [NetmonFlow]) {
        var proxies: [String: Set<String>] = [:]
        var tuples: [String: Set<String>] = [:]
        for flow in flows {
            let identity = appIdentity(pid: flow.pid, commFallback: flow.command)
            let source = TrafficAttribution.socketKey(proto: flow.proto,
                host: TrafficAttribution.remoteHost(flow.local), port: TrafficAttribution.remotePort(flow.local))
            let tuple = TrafficAttribution.flowKey(proto: flow.proto, local: flow.local, remote: flow.remote)
            tuples[tuple, default: []].insert(identity.key)
            if TrafficAttribution.isLoopback(TrafficAttribution.remoteHost(flow.remote)),
               let port = Int(TrafficAttribution.remotePort(flow.remote)), proxyPorts.contains(port) {
                proxies[source, default: []].insert(identity.key)
            }
        }
        proxyClientByEndpoint = proxies.compactMapValues { $0.count == 1 ? $0.first : nil }
        flowAppByTuple = tuples.compactMapValues { $0.count == 1 ? $0.first : nil }
    }

    private func applyDiscoveredPorts(_ discovery: ClashDiscovery) {
        proxyPorts = discovery.proxyPorts
        mixedPort = discovery.mixedPort
        if let mixedPort {
            proxyPorts.insert(mixedPort)
            defaults.set(mixedPort, forKey: Self.mixedPortKey)
        } else {
            defaults.removeObject(forKey: Self.mixedPortKey)
        }
        defaults.set(proxyPorts.sorted(), forKey: Self.proxyPortsKey)
    }

    /// Refresh local listeners periodically so changing Clash ports does not
    /// leave persisted port assignments active indefinitely.
    private var lastPortDiscovery = Date.distantPast

    private func discoverMixedPortIfNeeded() async {
        guard Date().timeIntervalSince(lastPortDiscovery) >= 30 else { return }
        lastPortDiscovery = Date()
        let requestedGeneration = generation
        let result = await MoleEngine.shared.runBridge("bin/app_netmon.sh",
                                                       arguments: ["discover"], timeout: 15)
        guard result.succeeded, requestedGeneration == generation else { return }
        applyDiscoveredPorts(Parsers.clashDiscovery(result.output))
    }

    /// 为尚无路由缓存的远端地址批量查一次出口接口。
    private func sampleRoutes(for flows: [NetmonFlow], generation sampleGeneration: Int) async {
        let now = Date()
        routeCache = routeCache.filter { $0.value.expires > now }
        var missing: [String] = []
        for flow in flows {
            let host = TrafficAttribution.remoteHost(flow.remote)
            guard TrafficAttribution.isRoutableAddress(host), routeCache[host] == nil,
                  !missing.contains(host) else { continue }
            missing.append(host)
            if missing.count >= 40 { break }
        }
        guard !missing.isEmpty,
              let script = MoleEngine.shared.resourceURL("bin/app_netmon.sh") else { return }
        let stdinData = Data((missing.joined(separator: "\n") + "\n").utf8)
        let result = await MoleEngine.shared.run(
            executable: URL(fileURLWithPath: "/bin/bash"),
            arguments: [script.path, "routes"],
            environment: MoleEngine.shared.standardEnvironment(),
            currentDirectory: MoleEngine.shared.resourcesURL,
            stdinData: stdinData,
            timeout: 30)
        guard result.succeeded, sampleGeneration == generation else { return }
        for route in Parsers.netmonRoutes(result.output) {
            routeCache[route.address] = (route.interface, Date().addingTimeInterval(5))
        }
    }

    /// 接口级差分用于交叉参考；不同接口可能承载同一批数据，不相加。
    private func sampleInterfaces(elapsed: TimeInterval) {
        let counters = SystemMetrics.interfaceCounters()
        guard elapsed > 0, !lastInterfaceCounters.isEmpty else {
            lastInterfaceCounters = counters
            return
        }
        for (name, counter) in counters {
            guard let previous = lastInterfaceCounters[name] else { continue }
            let deltaIn = counter.inbound >= previous.inbound
                ? counter.inbound - previous.inbound : 0
            let deltaOut = counter.outbound >= previous.outbound
                ? counter.outbound - previous.outbound : 0
            if name.hasPrefix("utun") {
                tunnelDown += deltaIn
                tunnelUp += deltaOut
            } else if name.hasPrefix("en") || name.hasPrefix("bridge") {
                physicalDown += deltaIn
                physicalUp += deltaOut
            }
        }
        lastInterfaceCounters = counters
    }

    // MARK: - 归因

    private func refreshProcessContext(_ text: String) {
        var apps: [Int32: (URL, String?, String)] = [:]
        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            let pid = application.processIdentifier
            guard pid > 0, let bundleURL = application.bundleURL else { continue }
            apps[pid] = (bundleURL,
                         application.bundleIdentifier,
                         application.localizedName ?? bundleURL.lastPathComponent)
        }
        workspaceApps = apps

        var parents: [Int32: (Int32, String, String)] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 10,
                  let pid = Int32(parts[0]), let ppid = Int32(parts[1]), pid > 0 else { continue }
            parents[pid] = (ppid, parts[8], parts[9...].joined(separator: "\t"))
        }
        processParents = parents
        for (_, app) in apps {
            _ = identityForBundle(app.0, preferredName: app.2, preferredIdentifier: app.1)
        }
    }

    /// Aggregate browser/Electron helpers into the outer app, consistently for
    /// NSWorkspace, executable paths, parent processes and Clash processPath.
    private func identityForBundle(_ url: URL, preferredName: String? = nil,
                                   preferredIdentifier: String? = nil)
        -> (key: String, name: String, bundleIdentifier: String?) {
        let outer = TrafficAttribution.applicationURL(in: url.path) ?? url.standardizedFileURL
        if let cached = bundleIdentities[outer.path] { return cached }
        let bundle = Bundle(url: outer)
        let identifier = bundle?.bundleIdentifier ?? (outer == url ? preferredIdentifier : nil)
        let name = (outer == url ? preferredName : nil)
            ?? bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? outer.deletingPathExtension().lastPathComponent
        let key = identifier.map { "app:\($0)" } ?? "app-path:\(outer.path)"
        let identity = (key, name, identifier)
        bundleIdentities[outer.path] = identity
        appDisplayNames[key] = name
        return identity
    }

    private func identityFromPath(_ path: String) -> (key: String, name: String, bundleIdentifier: String?)? {
        guard let url = TrafficAttribution.applicationURL(in: path) else { return nil }
        return identityForBundle(url)
    }

    private func identityFromProcess(_ record: (ppid: Int32, comm: String, args: String))
        -> (key: String, name: String, bundleIdentifier: String?)? {
        if let identity = identityFromPath(record.comm) { return identity }
        // app_runtime's whitespace-delimited ps bridge can put the tail of a
        // spaced executable path into args. Reconstruct that leading path only
        // when it resolves to an actual app directory.
        if let url = TrafficAttribution.applicationURL(in: record.comm + " " + record.args),
           FileManager.default.fileExists(atPath: url.path) {
            return identityForBundle(url)
        }
        return nil
    }

    private func appIdentity(pid: Int32, commFallback: String?)
        -> (key: String, name: String, bundleIdentifier: String?) {
        if let app = workspaceApps[pid] {
            return identityForBundle(app.bundleURL, preferredName: app.name, preferredIdentifier: app.bundleIdentifier)
        }
        if let record = processParents[pid], let identity = identityFromProcess(record) { return identity }
        var current = processParents[pid]?.ppid ?? 0
        var visited: Set<Int32> = [pid]
        while current > 1, visited.count < 10, visited.insert(current).inserted {
            if let app = workspaceApps[current] {
                return identityForBundle(app.bundleURL, preferredName: app.name, preferredIdentifier: app.bundleIdentifier)
            }
            if let record = processParents[current], let identity = identityFromProcess(record) { return identity }
            current = processParents[current]?.ppid ?? 0
        }
        let fallback = commFallback ?? processParents[pid]?.comm ?? "process"
        let name = (fallback as NSString).lastPathComponent
        let key = "comm:\(name)"
        appDisplayNames[key] = name
        return (key, name, nil)
    }

    // MARK: - 累计与发布

    private func accumulate(pidDeltas: [Int32: (inbound: UInt64, outbound: UInt64)],
                            elapsed: TimeInterval,
                            flows: [NetmonFlow],
                            samplesText: String) {
        let samples = Parsers.netmonProcessSamples(samplesText)
        var commByPID: [Int32: String] = [:]
        for sampleRow in samples { commByPID[sampleRow.pid] = sampleRow.command }

        for (pid, delta) in pidDeltas {
            let identity = appIdentity(pid: pid, commFallback: commByPID[pid])
            var accumulator = appTotals[identity.key]
                ?? AppAccumulator(name: identity.name,
                                  bundleIdentifier: identity.bundleIdentifier)
            accumulator.down += delta.inbound
            accumulator.up += delta.outbound
            accumulator.name = identity.name
            accumulator.bundleIdentifier = identity.bundleIdentifier
            accumulator.representativePID = pid
            accumulator.seen = Date()
            appTotals[identity.key] = accumulator
        }
        if elapsed > 0 {
            for key in Array(appTotals.keys) {
                appTotals[key]?.rateDown = 0
                appTotals[key]?.rateUp = 0
            }
            for (pid, delta) in pidDeltas {
                let identity = appIdentity(pid: pid, commFallback: commByPID[pid])
                appTotals[identity.key]?.rateDown += Double(delta.inbound) / elapsed
                appTotals[identity.key]?.rateUp += Double(delta.outbound) / elapsed
            }
        }

        rebuildEndpoints(flows: flows)
    }

    private func rebuildEndpoints(flows: [NetmonFlow]) {
        let historyEndpoints = ledger.endpointsByApp
        var endpoints = historyEndpoints.mapValues { list in
            list.map { entry in
                let kind: TrafficExitKind
                switch entry.kind {
                case .direct: kind = .proxyDirect
                case .node: kind = .proxyNode
                case .unknown: kind = .unknown
                }
                return TrafficEndpointRow(appKey: entry.appKey,
                    remote: entry.isOverflow ? L10n.shared.t("netmon.history.otherTargets") : entry.remote,
                    proto: entry.proto, kind: kind, clashHost: entry.host,
                    clashChains: entry.chains, clashRule: entry.rule,
                    clashDown: entry.down, clashUp: entry.up, lastSeen: entry.lastSeen,
                    activeConnections: clashState == .ok || clashState == .stale ? entry.activeConnections : 0)
            }
        }
        var flowCounts: [String: Int] = [:]
        for flow in flows {
            let identity = appIdentity(pid: flow.pid, commFallback: flow.command)
            flowCounts[identity.key, default: 0] += 1
            let kind = exitKind(remote: flow.remote)
            // Suppress the local proxy hop only if this particular socket joined
            // a live controller connection. Unmatched proxy clients stay visible.
            if kind == .proxy {
                let source = TrafficAttribution.socketKey(proto: flow.proto,
                    host: TrafficAttribution.remoteHost(flow.local), port: TrafficAttribution.remotePort(flow.local))
                let matched = clashConnections.contains { connection in
                    guard let host = connection.metadata.sourceIP, let port = connection.metadata.sourcePort,
                          let proto = connection.metadata.network else { return false }
                    return source == TrafficAttribution.socketKey(proto: proto, host: host, port: port)
                }
                if matched { continue }
            }
            let row = TrafficEndpointRow(appKey: identity.key, remote: flow.remote, proto: flow.proto,
                kind: kind, clashHost: nil, clashChains: [], clashRule: "", clashDown: 0, clashUp: 0,
                lastSeen: Date(), activeConnections: 1)
            if let index = endpoints[identity.key]?.firstIndex(where: { $0.id == row.id }) {
                endpoints[identity.key]?[index].activeConnections += 1
            } else {
                endpoints[identity.key, default: []].append(row)
            }
        }
        currentConnectionCounts = flowCounts
        for (key, list) in endpoints {
            let clashCount = historyEndpoints[key]?.reduce(0) { $0 + $1.activeConnections } ?? 0
            currentConnectionCounts[key] = max(flowCounts[key] ?? 0,
                clashState == .ok || clashState == .stale ? clashCount : 0)
            endpoints[key] = list.sorted {
                let lhs = $0.clashDown + $0.clashUp, rhs = $1.clashDown + $1.clashUp
                if lhs != rhs { return lhs > rhs }
                if $0.activeConnections != $1.activeConnections { return $0.activeConnections > $1.activeConnections }
                return $0.id < $1.id
            }
        }
        endpointsByApp = endpoints
    }

    private func exitKind(remote: String) -> TrafficExitKind {
        let cached = routeCache[TrafficAttribution.remoteHost(remote)]
        let interface = cached.flatMap { $0.expires > Date() ? $0.interface : nil }
        return TrafficAttribution.exitKind(remote: remote, proxyPorts: proxyPorts, interface: interface)
    }

    private func publishLedger() {
        clashSessionDown = ledger.sessionDown
        clashSessionUp = ledger.sessionUp
        sessionStartedAt = ledger.startedAt
        nodeDown = 0; nodeUp = 0; directDown = 0; directUp = 0
        unattributedDown = ledger.unattributedDown
        unattributedUp = ledger.unattributedUp
        for (key, totals) in ledger.apps {
            if key == TrafficLedger.unknownAppKey {
                unattributedDown += totals.down; unattributedUp += totals.up
            } else {
                nodeDown += totals.nodeDown; nodeUp += totals.nodeUp
                directDown += totals.directDown; directUp += totals.directUp
                unattributedDown += totals.unknownDown; unattributedUp += totals.unknownUp
            }
        }
    }

    private func rebuildRows() {
        var built: [TrafficAppRow] = []
        let allKeys = Set(appTotals.keys).union(ledger.apps.keys).union(endpointsByApp.keys)
        for key in allKeys {
            let totals = appTotals[key]
            let clash = ledger.apps[key]
            let endpointCount = currentConnectionCounts[key] ?? 0
            let kinds = TrafficExitKind.allCases.filter { kind in
                endpointsByApp[key]?.contains(where: { $0.kind == kind }) ?? false
            }
            let name = key == TrafficLedger.unknownAppKey ? L10n.shared.t("netmon.clash.unknownApp")
                : totals?.name ?? appDisplayNames[key] ?? String(key.dropFirst(key.hasPrefix("comm:") ? 5 : 4))
            built.append(TrafficAppRow(appKey: key, displayName: name,
                bundleIdentifier: totals?.bundleIdentifier,
                representativePID: totals?.representativePID ?? 0,
                sessionDown: totals?.down ?? 0, sessionUp: totals?.up ?? 0,
                rateDown: totals?.rateDown ?? 0, rateUp: totals?.rateUp ?? 0,
                proxyDirectDown: clash?.directDown ?? 0, proxyDirectUp: clash?.directUp ?? 0,
                proxyNodeDown: clash?.nodeDown ?? 0, proxyNodeUp: clash?.nodeUp ?? 0,
                proxyUnknownDown: clash?.unknownDown ?? 0, proxyUnknownUp: clash?.unknownUp ?? 0,
                connectionCount: endpointCount, exitKinds: kinds))
        }
        rows = sortOrder.sorted(built)
    }

    // MARK: - Session persistence

    private struct History: Codable, Sendable {
        var version = 1
        var endpoint: String
        var ledger: TrafficLedger
        var appTotals: [String: AppAccumulator]
        var names: [String: String]
        var tunnelDown: UInt64
        var tunnelUp: UInt64
        var physicalDown: UInt64
        var physicalUp: UInt64
    }

    private func restoreHistory() {
        guard FileManager.default.fileExists(atPath: historyURL.path) else { return }
        do {
            let data = try Data(contentsOf: historyURL)
            let history = try JSONDecoder().decode(History.self, from: data)
            guard history.version == 1, history.endpoint == clashEndpoint else { return }
            ledger = history.ledger
            appTotals = history.appTotals.mapValues { value in
                var value = value
                value.rateDown = 0; value.rateUp = 0; value.representativePID = 0
                return value
            }
            appDisplayNames = history.names
            tunnelDown = history.tunnelDown; tunnelUp = history.tunnelUp
            physicalDown = history.physicalDown; physicalUp = history.physicalUp
            publishLedger()
            rebuildEndpoints(flows: [])
            rebuildRows()
        } catch {
            historySaveFailed = true
        }
    }

    private func saveHistory(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastHistorySave) >= 5 else { return }
        lastHistorySave = Date()
        let snapshot = History(endpoint: clashEndpoint, ledger: ledger, appTotals: appTotals,
            names: appDisplayNames, tunnelDown: tunnelDown, tunnelUp: tunnelUp,
            physicalDown: physicalDown, physicalUp: physicalUp)
        let url = historyURL
        historyQueue.async { [weak self] in
            let failed: Bool
            do {
                let data = try JSONEncoder().encode(snapshot)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                failed = false
            } catch { failed = true }
            Task { @MainActor [weak self] in self?.historySaveFailed = failed }
        }
    }

    func flushHistoryForTermination() {
        persistentTimer?.invalidate()
        persistentTimer = nil
        saveHistory(force: true)
        historyQueue.sync {}
    }

    // MARK: - 工具

    private func syncPersistentTimer() {
        if persistentMonitoring || pageVisible, persistentTimer == nil {
            persistentTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.tick() }
            }
        } else if !persistentMonitoring && !pageVisible, let timer = persistentTimer {
            timer.invalidate()
            persistentTimer = nil
        }
    }
}
