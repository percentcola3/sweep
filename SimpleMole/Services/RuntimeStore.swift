import Foundation
import AppKit

/// 进程与端口数据：默认走 NSWorkspace（应用级、无子进程），
/// 高级模式走 app_runtime.sh 的 ps 输出并按进程树聚合。
enum RuntimeStore {
    /// 物理内存（用于把 ps 的内存百分比换算成字节）。
    static let physicalMemory: UInt64 = {
        var total: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        return sysctlbyname("hw.memsize", &total, &size, nil, 0) == 0 ? total : 0
    }()

    private static func memToBytes(_ percent: Double) -> UInt64 {
        UInt64(max(0, percent) / 100.0 * Double(physicalMemory))
    }

    struct RawProcess {
        let pid: Int32
        let ppid: Int32
        let uid: UInt32
        let startIdentity: String
        let state: String
        let elapsed: TimeInterval
        let cpu: Double
        let mem: Double
        let command: String
        let arguments: String
        var lifecycle: ProcessLifecycle { ProcessLifecycle(processState: state) }
    }

    struct ProcessUsage: Equatable {
        var cpu: Double = 0
        var mem: Double = 0
        var memBytes: UInt64 { memToBytes(mem) }
    }

    /// 连续快照策略。调用方执行前显式标记，异常状态未变化期间同一启动身份不重复返回。
    struct AutomaticCandidateTracker {
        private struct Observation {
            let cleanupToken: String
            let lifecycle: ProcessLifecycle
            let count: Int
        }

        private let currentUID: UInt32
        private var observations: [Int32: Observation] = [:]
        private var attemptedTokens: Set<String> = []
        private var lastSnapshotAt: TimeInterval?

        init(currentUID: UInt32 = UInt32(getuid())) {
            self.currentUID = currentUID
        }

        mutating func candidates(
            in rows: [ProcessRow],
            now: TimeInterval = Date().timeIntervalSinceReferenceDate
        ) -> [ProcessRow] {
            // 进程页关闭、机器休眠或采样延迟后，旧计数不得与新快照拼接。
            if let lastSnapshotAt,
               now < lastSnapshotAt || now - lastSnapshotAt > 6 {
                observations.removeAll()
            }
            lastSnapshotAt = now

            let presentPIDs = Set(rows.map(\.pid))
            for pid in observations.keys.filter({ !presentPIDs.contains($0) }) {
                if let removed = observations.removeValue(forKey: pid) {
                    attemptedTokens.remove(removed.cleanupToken)
                }
            }

            var candidates: [ProcessRow] = []
            var seenPIDs: Set<Int32> = []
            for row in rows where seenPIDs.insert(row.pid).inserted {
                guard row.uid == currentUID,
                      let threshold = Self.threshold(for: row.lifecycle) else {
                    if let removed = observations.removeValue(forKey: row.pid) {
                        attemptedTokens.remove(removed.cleanupToken)
                    }
                    attemptedTokens.remove(row.staleCleanupToken)
                    continue
                }

                let previous = observations[row.pid]
                let count: Int
                if previous?.cleanupToken == row.staleCleanupToken,
                   previous?.lifecycle == row.lifecycle {
                    count = (previous?.count ?? 0) + 1
                } else {
                    // 状态恢复、父进程变化、生命周期变化或 PID 被复用，
                    // 都会从第一次观察重新计算。
                    if let previous {
                        attemptedTokens.remove(previous.cleanupToken)
                    }
                    count = 1
                }
                observations[row.pid] = Observation(cleanupToken: row.staleCleanupToken,
                                                    lifecycle: row.lifecycle,
                                                    count: count)

                guard count >= threshold,
                      !attemptedTokens.contains(row.staleCleanupToken) else { continue }
                candidates.append(row)
            }
            return candidates
        }

        /// 读取失败意味着这一轮状态未知：打断连续计数，但保留已尝试身份，
        /// 防止恢复后对同一异常进程重复发信号。
        mutating func breakSequence() {
            observations.removeAll()
            lastSnapshotAt = nil
        }

        /// 调用方完成本轮去重和限量后再标记，避免未执行的候选被永久跳过。
        mutating func markAttempted(_ rows: [ProcessRow]) {
            attemptedTokens.formUnion(rows.map(\.staleCleanupToken))
        }

        private static func threshold(for lifecycle: ProcessLifecycle) -> Int? {
            switch lifecycle {
            case .zombie: return 2
            case .exiting: return 3
            case .normal: return nil
            }
        }
    }

    /// NSWorkspace 提供应用身份，ps 提供主进程及其子进程的实时资源占用。
    static func nativeRows(fromProcessText text: String) -> (rows: [ProcessRow], total: Int) {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "ForgeSweep"
        let applications = NSWorkspace.shared.runningApplications.filter { application in
            guard !application.isTerminated,
                  application.processIdentifier > 1,
                  application.processIdentifier != ownPID,
                  application.activationPolicy != .prohibited,
                  nativeStartIdentity(for: application) != nil else { return false }
            let name = application.localizedName ?? application.bundleIdentifier ?? ""
            return !name.isEmpty && name != ownName && name != "Mole"
        }
        let applicationPIDs = Set(applications.map(\.processIdentifier))
        let usage = usageByApplicationPID(applicationPIDs, fromProcessText: text)
        var rows = applications.compactMap { application -> ProcessRow? in
            guard let startIdentity = nativeStartIdentity(for: application) else { return nil }
            let pid = application.processIdentifier
            let resource = usage[pid] ?? ProcessUsage()
            return ProcessRow(pid: pid, startIdentity: startIdentity,
                              name: application.localizedName ?? application.bundleIdentifier ?? "",
                              detail: L10n.shared.tf("proc.detail.app", pid),
                              isNativeApp: true, cpu: resource.cpu, mem: resource.mem,
                              memBytes: resource.memBytes)
        }
        rows.sort {
            if $0.memBytes != $1.memBytes { return $0.memBytes > $1.memBytes }
            if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let total = rows.count
        return (Array(rows.prefix(40)), total)
    }

    /// 把进程树资源聚合到对应的 NSRunningApplication 主 PID。
    static func usageByApplicationPID(_ applicationPIDs: Set<Int32>,
                                      fromProcessText text: String) -> [Int32: ProcessUsage] {
        let records = parseRecords(text)
        let byPID = Dictionary(uniqueKeysWithValues: records.map { ($0.pid, $0) })
        var usage: [Int32: ProcessUsage] = [:]
        for record in records {
            guard let owner = owningApplicationPID(of: record,
                                                    applicationPIDs: applicationPIDs,
                                                    byPID: byPID) else { continue }
            var current = usage[owner] ?? ProcessUsage()
            current.cpu += record.cpu
            current.mem += record.mem
            usage[owner] = current
        }
        return usage
    }

    /// 高级 PID 模式：解析 ps TSV 并聚合成应用组或单 PID 行。
    /// sortByMemory 用于快捷面板的“内存占用最高”列表。
    static func rows(fromProcessText text: String, advanced: Bool, sortByMemory: Bool = false) -> [ProcessRow] {
        let records = parseRecords(text)
        guard !records.isEmpty else { return [] }
        var byPID: [Int32: RawProcess] = [:]
        for record in records { byPID[record.pid] = record }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        var visible: [RawProcess] = []
        for record in records {
            let root = rootPID(of: record, byPID: byPID)
            let rootRecord = byPID[root] ?? record
            let source = "\(rootRecord.command) \(rootRecord.arguments)"
            let isSystem = source.hasPrefix("/System/") || source.hasPrefix("/usr/")
                || source.hasPrefix("/sbin/") || source.hasPrefix("/private/")
                || source.contains("/System/Library/")
            if !isSystem && record.pid != ownPID {
                visible.append(record)
            }
        }

        if advanced {
            return visible
                .sorted {
                    let leftPriority = lifecyclePriority($0.lifecycle)
                    let rightPriority = lifecyclePriority($1.lifecycle)
                    if leftPriority != rightPriority { return leftPriority < rightPriority }
                    if $0.cpu != $1.cpu { return $0.cpu > $1.cpu }
                    return $0.pid < $1.pid
                }
                .prefix(40)
                .map { ProcessRow(pid: $0.pid,
                                  startIdentity: $0.startIdentity,
                                  name: "\($0.command)  PID \($0.pid)",
                                  detail: L10n.shared.tf("proc.detail.pid", $0.pid),
                                  isNativeApp: false,
                                  cpu: $0.cpu, mem: $0.mem,
                                  memBytes: memToBytes($0.mem),
                                  ppid: $0.ppid, uid: $0.uid,
                                  state: $0.state, elapsed: $0.elapsed) }
        }

        struct Group {
            var pid: Int32
            var startIdentity: String
            var name: String
            var cpu: Double
            var mem: Double
            var count: Int
            var ppid: Int32
            var uid: UInt32
            var state: String
            var elapsed: TimeInterval
        }
        var groups: [Int32: Group] = [:]
        for record in visible {
            let root = rootPID(of: record, byPID: byPID)
            let rootRecord = byPID[root] ?? record
            if var group = groups[root] {
                group.cpu += record.cpu
                group.mem += record.mem
                group.count += 1
                groups[root] = group
            } else {
                groups[root] = Group(pid: root, startIdentity: rootRecord.startIdentity,
                                     name: applicationName(for: rootRecord),
                                     cpu: record.cpu, mem: record.mem, count: 1,
                                     ppid: rootRecord.ppid, uid: rootRecord.uid,
                                     state: rootRecord.state, elapsed: rootRecord.elapsed)
            }
        }
        return groups.values
            .sorted { sortByMemory ? $0.mem > $1.mem : $0.cpu > $1.cpu }
            .prefix(40)
            .map { ProcessRow(pid: $0.pid,
                              startIdentity: $0.startIdentity,
                              name: $0.count > 1 ? "\($0.name) · \($0.count)" : $0.name,
                              detail: L10n.shared.tf("proc.detail.pid", $0.pid),
                              isNativeApp: false,
                              cpu: $0.cpu, mem: $0.mem,
                              memBytes: memToBytes($0.mem),
                              ppid: $0.ppid, uid: $0.uid,
                              state: $0.state, elapsed: $0.elapsed) }
    }

    static func portRows(fromText text: String) -> [PortRow] {
        var rows: [PortRow] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 5, let pid = Int32(parts[1]),
                  validBridgeStartIdentity(parts[2]) else { continue }
            rows.append(PortRow(port: parts[0], pid: pid, startIdentity: parts[2],
                                command: parts[3], endpoint: parts[4...].joined(separator: "\t")))
        }
        return rows
    }

    /// 把原生应用列表与完整进程表合并为清理风险策略使用的运行态快照。
    /// `app_runtime.sh` 失败时调用方传入 `isComplete: false`，所有需要运行态
    /// 保护的 Safe 项都会在最终执行前失败关闭。
    static func runningApplicationSnapshot(fromProcessText text: String,
                                           isComplete: Bool) -> RunningApplicationSnapshot {
        var bundleIdentifiers: [String] = []
        var processNames: [String] = []

        for application in NSWorkspace.shared.runningApplications where !application.isTerminated {
            if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
                bundleIdentifiers.append(bundleIdentifier)
            }
            if let name = application.localizedName, !name.isEmpty {
                processNames.append(name)
            }
            if let executableName = application.executableURL?.lastPathComponent,
               !executableName.isEmpty {
                processNames.append(executableName)
            }
        }

        for record in parseRecords(text) {
            let commandName = (record.command as NSString).lastPathComponent
            if !commandName.isEmpty { processNames.append(commandName) }

            // ps 的 command 字段在部分 macOS 版本上会被截短；arguments 的首项
            // 保留真实可执行文件名，可补足 node/xcodebuild 等 CLI owner。
            let firstArgument = record.arguments.split(separator: " ", maxSplits: 1)
                .first.map(String.init) ?? ""
            let argumentName = (firstArgument as NSString).lastPathComponent
            if !argumentName.isEmpty { processNames.append(argumentName) }
        }

        return RunningApplicationSnapshot(bundleIdentifiers: bundleIdentifiers,
                                          processNames: processNames,
                                          isComplete: isComplete)
    }

    /// NSRunningApplication exposes the launch instant independently of PID.
    /// Preserve the exact Double bit pattern so the confirmation callback can
    /// distinguish a newly launched process that reused the same PID.
    static func nativeStartIdentity(for application: NSRunningApplication) -> String? {
        guard let launchDate = application.launchDate else { return nil }
        return String(launchDate.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    }

    // MARK: - 私有

    private static func parseRecords(_ text: String) -> [RawProcess] {
        var records: [RawProcess] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if parts.count >= 10,
               let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
               let uid = UInt32(parts[2]), pid > 1,
               validBridgeStartIdentity(parts[3]) {
                records.append(RawProcess(pid: pid, ppid: ppid, uid: uid,
                                          startIdentity: parts[3], state: parts[4],
                                          elapsed: parseElapsed(parts[5]),
                                          cpu: Double(parts[6]) ?? 0,
                                          mem: Double(parts[7]) ?? 0,
                                          command: parts[8],
                                          arguments: parts[9...].joined(separator: "\t")))
            } else if parts.count >= 7,
                      let pid = Int32(parts[0]), let ppid = Int32(parts[1]),
                      pid > 1, validBridgeStartIdentity(parts[2]) {
                // 兼容尚未升级 bridge 的七列输出。未知元数据不得被判为异常。
                records.append(RawProcess(pid: pid, ppid: ppid, uid: UInt32.max,
                                          startIdentity: parts[2], state: "", elapsed: 0,
                                          cpu: Double(parts[3]) ?? 0,
                                          mem: Double(parts[4]) ?? 0,
                                          command: parts[5],
                                          arguments: parts[6...].joined(separator: " ")))
            }
        }
        return records
    }

    /// `ps etime` 格式为 `[[dd-]hh:]mm:ss`。
    private static func parseElapsed(_ value: String) -> TimeInterval {
        let dayAndTime = value.split(separator: "-", maxSplits: 1,
                                     omittingEmptySubsequences: false)
        guard dayAndTime.count <= 2 else { return 0 }
        let days: UInt64
        let timeText: Substring
        if dayAndTime.count == 2 {
            guard let parsedDays = UInt64(dayAndTime[0]) else { return 0 }
            days = parsedDays
            timeText = dayAndTime[1]
        } else {
            days = 0
            timeText = dayAndTime[0]
        }

        let components = timeText.split(separator: ":",
                                        omittingEmptySubsequences: false)
        guard (2...3).contains(components.count),
              components.allSatisfy({ UInt64($0) != nil }) else { return 0 }
        let numbers = components.map { UInt64($0)! }
        let hours = components.count == 3 ? numbers[0] : 0
        let minutes = components.count == 3 ? numbers[1] : numbers[0]
        let seconds = components.count == 3 ? numbers[2] : numbers[1]
        guard minutes < 60, seconds < 60 else { return 0 }
        return TimeInterval(days * 86_400 + hours * 3_600 + minutes * 60 + seconds)
    }

    private static func lifecyclePriority(_ lifecycle: ProcessLifecycle) -> Int {
        switch lifecycle {
        case .zombie: return 0
        case .exiting: return 1
        case .normal: return 2
        }
    }

    private static func validBridgeStartIdentity(_ value: String) -> Bool {
        value.range(
            of: #"^[A-Z][a-z]{2}_[A-Z][a-z]{2}_[0-9]{1,2}_[0-9]{2}:[0-9]{2}:[0-9]{2}_[0-9]{4}$"#,
            options: .regularExpression) != nil
    }

    private static func rootPID(of record: RawProcess, byPID: [Int32: RawProcess]) -> Int32 {
        var root = record.pid
        var parent = record.ppid
        var steps = 0
        while parent > 1, steps < 80 {
            guard let parentRecord = byPID[parent] else { break }
            root = parentRecord.pid
            parent = parentRecord.ppid
            steps += 1
        }
        return root
    }

    private static func owningApplicationPID(of record: RawProcess,
                                             applicationPIDs: Set<Int32>,
                                             byPID: [Int32: RawProcess]) -> Int32? {
        var current = record
        var steps = 0
        while steps < 80 {
            if applicationPIDs.contains(current.pid) { return current.pid }
            guard current.ppid > 1, let parent = byPID[current.ppid] else { return nil }
            current = parent
            steps += 1
        }
        return nil
    }

    private static func applicationName(for record: RawProcess) -> String {
        let source = record.arguments.isEmpty ? record.command : record.arguments
        if let appRange = source.range(of: ".app/") {
            let prefix = String(source[..<appRange.upperBound])
            let name = (prefix as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            if !stem.isEmpty { return stem }
        }
        let name = (record.command as NSString).lastPathComponent
        if name.lowercased().contains("electron") { return L10n.shared.t("proc.electron") }
        return name.isEmpty ? L10n.shared.t("proc.unknown") : name
    }
}
