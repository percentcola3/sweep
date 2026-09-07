import Foundation

/// 原生采集的系统指标快照。
///
/// 基础指标用于菜单栏和快捷面板；其余字段给状态面板和后续 JSON 导出
/// 使用。所有字段都有安全的零值，采集失败不会阻塞主界面。
struct MetricsSnapshot: Equatable, Sendable {
    var collectedAt: Date = Date()
    var cpuPercent: Double = 0
    var loadAverage: [Double] = []
    var logicalCPUCount: Int = 0
    var physicalCPUCount: Int = 0
    var memoryPercent: Double = 0
    var memoryUsedBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var memoryAvailableBytes: UInt64 = 0
    var memoryPressure: String = "unknown"
    var swapUsedBytes: UInt64 = 0
    var swapTotalBytes: UInt64 = 0
    var diskFreeBytes: UInt64 = 0
    var diskUsedPercent: Double = 0
    var diskReadMBps: Double = 0
    var diskWriteMBps: Double = 0
    var batteryPercent: Double = 0
    var batteryHealthPercent: Double = 0
    var batteryCycleCount: Int = 0
    var batteryCharging: Bool = false
    var networkRxMBps: Double = 0
    var networkTxMBps: Double = 0
    var uptimeSeconds: UInt64 = 0
    var healthScore: Int = 0
}

/// 清理扫描的实时状态。进度按原生目录遍历的已完成条目计算，currentPath
/// 只保留当前正在处理的目录，避免将每个文件写入日志而拖慢扫描。
struct CleanupScanProgress: Equatable, Sendable {
    var phase: String = ""
    var completed: Int = 0
    var total: Int = 0
    var currentPath: String = ""
    var isComplete: Bool = false
    /// Detailed count reported by the native directory walker.
    var detailCompleted: Int = 0
    var detailTotal: Int = 0

    var fraction: Double? {
        guard total > 0 else { return nil }
        let raw = min(1, max(0, Double(completed) / Double(total)))
        return raw
    }

    var countText: String? {
        guard total > 0 else { return nil }
        return "\(min(completed, total))/\(total)"
    }

    var detailCountText: String? {
        guard detailTotal > 0 else { return nil }
        return "\(min(detailCompleted, detailTotal))/\(detailTotal)"
    }
}

enum CleanupSource: String, Codable, CaseIterable, Hashable, Sendable {
    case core
    case appLeftover
    case installer
    case projectArtifact
    case developerCache
    case tool
    case aiSession
    case aiCache
    case aiModel
    case xcodeCache
    case xcodeArchive
    case slim
    case system
    case unknown
}

enum CleanupRisk: String, Codable, CaseIterable, Hashable, Sendable {
    case safe
    case warning
    case protected
}

enum CleanupDisposal: String, Codable, CaseIterable, Hashable, Sendable {
    case trash
    case command
    case privileged
    case transform
    case none
}

enum CleanupApplyRoute: String, Codable, CaseIterable, Hashable, Sendable {
    case genericTrash
    case installerTrash
    case projectArtifactTrash
    case developerCacheTrash
    case aiTrash
    case xcodeTrash
    case toolCommand
    case systemPrivileged
    case imageTransform
    case none
}

/// 扫描时和最终执行前都要重新判断的运行态保护。
enum CleanupActivityGuard: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    /// 路径没有稳定的 Bundle ID，但执行边界仍会用一次批量打开文件快照复核。
    case openFile
    case reverseDNSCache
    case browser
    case xcode
    case simulator
    case packageManager
    case ide
    case unsupported
}

/// 清理类别：同一分组中的路径共享风险、处置方式和执行路由。
struct CleanupCategory: Identifiable, Equatable {
    let id: UUID
    var name: String
    var paths: [String]
    var bytes: UInt64
    /// Per-path sizes are preserved from scanner output so partial selection
    /// reports an accurate reclaimable total.
    var pathBytes: [String: UInt64]
    /// Identity captured when the scan produced the path. Apply must recheck
    /// this value before deleting so a replaced path cannot be removed.
    var pathIdentities: [String: String]
    private(set) var selectedPaths: Set<String>
    var expanded: Bool
    var source: CleanupSource
    var risk: CleanupRisk
    var disposal: CleanupDisposal
    var applyRoute: CleanupApplyRoute
    var activityGuard: CleanupActivityGuard
    /// 稳定原因键，由 UI 层自行本地化。
    var reasonKey: String

    init(id: UUID = UUID(),
         name: String,
         paths: [String],
         bytes: UInt64,
         pathBytes: [String: UInt64]? = nil,
         pathIdentities: [String: String]? = nil,
         selected: Bool? = nil,
         expanded: Bool = false,
         source: CleanupSource = .unknown,
         risk: CleanupRisk = .warning,
         disposal: CleanupDisposal = .none,
         applyRoute: CleanupApplyRoute = .none,
         activityGuard: CleanupActivityGuard = .unsupported,
         reasonKey: String = "cleanup.risk.unknown") {
        self.id = id
        self.name = name
        self.paths = paths
        self.bytes = bytes
        if let pathBytes {
            self.pathBytes = pathBytes.filter { paths.contains($0.key) }
        } else if paths.count == 1, let path = paths.first {
            self.pathBytes = [path: bytes]
        } else {
            self.pathBytes = [:]
        }
        self.pathIdentities = pathIdentities ?? paths.reduce(into: [String: String]()) { result, path in
            if let identity = DeletionPlan.identity(at: path) { result[path] = identity }
        }
        let shouldSelect = risk != .protected && (selected ?? (risk == .safe))
        self.selectedPaths = shouldSelect ? Set(paths) : []
        self.expanded = expanded
        self.source = source
        self.risk = risk
        self.disposal = disposal
        self.applyRoute = applyRoute
        self.activityGuard = activityGuard
        self.reasonKey = reasonKey
    }

    var canSelect: Bool { risk != .protected }
    var quickCleanEligible: Bool { risk == .safe && disposal == .trash }
    var selected: Bool {
        get { !selectedPaths.isEmpty }
        set { selectedPaths = newValue && canSelect ? Set(paths) : [] }
    }
    var allSelected: Bool { !paths.isEmpty && selectedPaths.count == paths.count }
    var partiallySelected: Bool { selected && !allSelected }
    var selectedPathCount: Int { selectedPaths.count }
    var selectedPathBytes: UInt64 {
        if allSelected { return bytes }
        return selectedPaths.reduce(0) { $0 &+ (pathBytes[$1] ?? 0) }
    }

    func isPathSelected(_ path: String) -> Bool {
        selectedPaths.contains(path)
    }

    /// Keep the category visible while clearing its current selection. This is
    /// used when runtime ownership is unknown or an app is still running.
    func clearingSelection() -> CleanupCategory {
        var copy = self
        copy.selectedPaths = []
        return copy
    }

    /// Keep the full category total while selecting only paths proven idle.
    func selectingPaths(_ pathsToSelect: some Sequence<String>) -> CleanupCategory {
        var copy = self
        let allowed = Set(pathsToSelect).intersection(copy.paths)
        copy.selectedPaths = copy.canSelect ? allowed : []
        return copy
    }

    mutating func setPathSelected(_ path: String, selected: Bool) {
        guard canSelect, paths.contains(path) else { return }
        if selected {
            selectedPaths.insert(path)
        } else {
            selectedPaths.remove(path)
        }
    }

    mutating func appendPath(_ path: String, bytes pathSize: UInt64) {
        guard !paths.contains(path) else { return }
        paths.append(path)
        pathBytes[path] = pathSize
        if let identity = DeletionPlan.identity(at: path) { pathIdentities[path] = identity }
        bytes &+= pathSize
        if risk == .safe { selectedPaths.insert(path) }
    }

    var selectedSubset: CleanupCategory? {
        guard canSelect else { return nil }
        let selectedPathList = paths.filter(selectedPaths.contains)
        guard !selectedPathList.isEmpty else { return nil }
        var subset = self
        subset.paths = selectedPathList
        subset.pathBytes = pathBytes.filter { selectedPaths.contains($0.key) }
        subset.pathIdentities = pathIdentities.filter { selectedPaths.contains($0.key) }
        subset.bytes = selectedPathBytes
        subset.selectedPaths = Set(selectedPathList)
        return subset
    }

    /// 保留同一类别中的部分路径。运行态保护必须按路径裁剪，不能因为一个
    /// App 正在运行就把同组其他应用的缓存全部隐藏或跳过。
    func retainingPaths(_ keptPaths: [String]) -> CleanupCategory? {
        let kept = Set(keptPaths)
        let ordered = paths.filter(kept.contains)
        guard !ordered.isEmpty else { return nil }

        var subset = self
        subset.paths = ordered
        subset.pathBytes = pathBytes.filter { kept.contains($0.key) }
        subset.pathIdentities = pathIdentities.filter { kept.contains($0.key) }
        subset.bytes = ordered.reduce(0) { $0 &+ (subset.pathBytes[$1] ?? 0) }
        subset.selectedPaths.formIntersection(kept)
        return subset
    }

    var pathsByDescendingSize: [String] {
        paths.sorted { lhs, rhs in
            let lhsBytes = pathBytes[lhs] ?? 0
            let rhsBytes = pathBytes[rhs] ?? 0
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    /// 磁盘清理只接受已明确为可再生垃圾的非空条目。这个收口同时用于
    /// 新扫描和旧缓存恢复，避免历史 Warning / Protected 结果重新出现。
    var safeCleanupCandidate: CleanupCategory? {
        guard risk == .safe, disposal == .trash else { return nil }
        let keptPaths = paths.filter { (pathBytes[$0] ?? 0) > 0 }.sorted { lhs, rhs in
            let lhsBytes = pathBytes[lhs] ?? 0
            let rhsBytes = pathBytes[rhs] ?? 0
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        guard !keptPaths.isEmpty else { return nil }

        var candidate = self
        candidate.paths = keptPaths
        candidate.pathBytes = pathBytes.filter { keptPaths.contains($0.key) }
        candidate.pathIdentities = pathIdentities.filter { keptPaths.contains($0.key) }
        candidate.bytes = keptPaths.reduce(0) { $0 &+ (candidate.pathBytes[$1] ?? 0) }
        guard candidate.bytes > 0 else { return nil }
        candidate.selectedPaths = Set(keptPaths)
        return candidate
    }

    static func safeCleanupCandidates(from categories: [CleanupCategory]) -> [CleanupCategory] {
        categories.compactMap(\.safeCleanupCandidate).sorted(by: sizeDescending)
    }

    static func sizeDescending(_ lhs: CleanupCategory, _ rhs: CleanupCategory) -> Bool {
        if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
        let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        return (lhs.paths.first ?? "").localizedStandardCompare(rhs.paths.first ?? "")
            == .orderedAscending
    }

    static func == (lhs: CleanupCategory, rhs: CleanupCategory) -> Bool {
        lhs.id == rhs.id
    }
}

/// 系统数据页的固定分组：root 拥有的日志、报告与缓存。
enum SystemDataGroupKind: String, CaseIterable, Codable, Sendable {
    case logs, reports, power, caches, updates

    var titleKey: String { "system.group.\(rawValue)" }

    var symbol: String {
        switch self {
        case .logs: return "doc.text"
        case .reports: return "waveform.path.ecg"
        case .power: return "bolt"
        case .caches: return "internaldrive"
        case .updates: return "arrow.down.circle"
        }
    }
}

/// 系统数据页的单行清单项：路径独立勾选，风险徽章独立展示。
/// risk 只有 safe / warning(review)；执行边界仍由特权脚本复核。
struct SystemDataEntry: Identifiable, Equatable, Sendable {
    let id: UUID
    let group: SystemDataGroupKind
    let risk: CleanupRisk
    let name: String
    let detail: String
    let path: String
    let bytes: UInt64
    var selected: Bool
}

/// 当前清理结果所属的家族，决定确认文案与 apply 桥接脚本。
enum CleanupFamily: String {
    case clean, dev, tools, purge, slim, system, ai, xcode
}

/// 官方 GC 命令（owner 命令面板条目）。
struct GcAction: Identifiable, Equatable {
    let id: String
    let command: String
    let bytes: UInt64
}

/// macOS `ps state` 映射。只有首字符 `Z` 代表已经死亡的僵尸进程；
/// `E` 是附加退出标记，不能把 `X` / `T` / `U` 等主状态误判为退出。
enum ProcessLifecycle: String, Equatable {
    case normal
    case exiting
    case zombie

    init(processState state: String) {
        guard let primary = state.first else {
            self = .normal
            return
        }
        if primary == "Z" {
            self = .zombie
        } else if state.dropFirst().contains("E") {
            self = .exiting
        } else {
            self = .normal
        }
    }
}

/// 进程列表行（应用组模式 / 高级 PID 模式 / 原生应用模式共用）。
struct ProcessRow: Identifiable, Equatable, Sendable {
    let pid: Int32
    /// 进程启动身份；与 PID 一起使用，避免确认期间 PID 复用误杀新进程。
    let startIdentity: String
    let name: String
    let detail: String
    let isNativeApp: Bool
    let cpu: Double
    let mem: Double
    /// 内存占用换算成字节（百分比 × 物理内存）。
    let memBytes: UInt64
    let ppid: Int32
    let uid: UInt32
    /// 原始 `ps state`，保留附加标志供界面解释。
    let state: String
    /// 进程已运行秒数；旧 bridge 或原生应用行未知时为 0。
    let elapsed: TimeInterval
    var lifecycle: ProcessLifecycle { ProcessLifecycle(processState: state) }
    var id: Int32 { pid }
    var signalToken: String { "\(pid)|\(startIdentity)" }
    /// 后台异常处理还需绑定父进程和用户，避免快照变化后误处理同 PID。
    var staleCleanupToken: String { "\(pid)|\(startIdentity)|\(ppid)|\(uid)" }

    init(pid: Int32, startIdentity: String, name: String, detail: String,
         isNativeApp: Bool, cpu: Double, mem: Double, memBytes: UInt64,
         ppid: Int32 = 0, uid: UInt32 = UInt32.max, state: String = "",
         elapsed: TimeInterval = 0) {
        self.pid = pid
        self.startIdentity = startIdentity
        self.name = name
        self.detail = detail
        self.isNativeApp = isNativeApp
        self.cpu = cpu
        self.mem = mem
        self.memBytes = memBytes
        self.ppid = ppid
        self.uid = uid
        self.state = state
        self.elapsed = elapsed
    }
}

/// 监听端口行。
struct PortRow: Identifiable, Hashable {
    let port: String
    let pid: Int32
    let startIdentity: String
    let command: String
    let endpoint: String
    var id: String { "\(port)-\(pid)-\(endpoint)" }
    var signalToken: String { "\(pid)|\(startIdentity)" }
}

/// 图片清单条目。
struct ImageItem: Identifiable {
    let bytes: UInt64
    let width: Int
    let height: Int
    let path: String
    var id: String { path }
}

/// 原生应用扫描生成的卸载清单条目。
struct UninstallApp: Identifiable, Codable, Equatable, Sendable {
    let name: String
    let bundleID: String
    let source: String
    let path: String
    let size: String
    /// 扫描应用列表时捕获的文件身份，供预览与执行阶段拒绝路径替换。
    let appIdentity: String
    let infoIdentity: String

    var id: String { "\(path)#\(bundleID)" }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case source
        case path
        case size
        case appIdentity
        case infoIdentity
    }

    init(name: String, bundleID: String, source: String, path: String, size: String,
         appIdentity: String? = nil, infoIdentity: String? = nil) {
        self.name = name
        self.bundleID = bundleID
        self.source = source
        self.path = path
        self.size = size
        self.appIdentity = appIdentity ?? DeletionPlan.identity(at: path) ?? ""
        self.infoIdentity = infoIdentity
            ?? DeletionPlan.identity(at: path + "/Contents/Info.plist") ?? "missing"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decode(String.self, forKey: .name)
        bundleID = try values.decode(String.self, forKey: .bundleID)
        source = try values.decode(String.self, forKey: .source)
        path = try values.decode(String.self, forKey: .path)
        size = try values.decode(String.self, forKey: .size)
        appIdentity = try values.decodeIfPresent(String.self, forKey: .appIdentity)
            ?? DeletionPlan.identity(at: path) ?? ""
        infoIdentity = try values.decodeIfPresent(String.self, forKey: .infoIdentity)
            ?? DeletionPlan.identity(at: path + "/Contents/Info.plist") ?? "missing"
    }
}

/// 卸载预览的单个文件条目。label 是稳定的分类键（app/related/review/manual）。
struct UninstallFile: Identifiable, Codable, Equatable, Sendable {
    let bytes: UInt64
    let label: String
    let path: String

    var id: String { "\(label)\u{1F}\(path)" }
    var needsPrivilege: Bool { label == "system" || label == "diag" }
    var informational: Bool { label == "review" || label == "manual" }
    var isAppBundle: Bool { label == "app" }

    /// Only cache roots accepted by the shared risk policy, plus explicit
    /// sandbox cache folders, are shown as cleanable cache. Containers, WebKit,
    /// preferences and Application Support otherwise remain app data because
    /// they may include sessions or user state.
    var isCache: Bool {
        isCache(homeDirectory: NSHomeDirectory())
    }

    func isCache(homeDirectory: String) -> Bool {
        let normalized = standardizedPath
        guard !CleanupRiskPolicy.isProtectedContent(normalized,
                                                     homeDirectory: homeDirectory) else {
            return false
        }
        if CleanupRiskPolicy.developerCache(path: normalized,
                                            homeDirectory: homeDirectory).risk == .safe {
            return true
        }

        let home = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        return Self.matchesSandboxCache(normalized,
                                        prefix: home + "/Library/Containers/",
                                        suffixes: ["/Data/Library/Caches", "/Data/tmp"])
            || Self.matchesSandboxCache(normalized,
                                        prefix: home + "/Library/Group Containers/",
                                        suffixes: ["/Library/Caches"])
    }

    var standardizedPath: String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func matchesSandboxCache(_ path: String,
                                            prefix: String,
                                            suffixes: [String]) -> Bool {
        guard path.hasPrefix(prefix) else { return false }
        let remainder = String(path.dropFirst(prefix.count))
        guard let separator = remainder.firstIndex(of: "/"), separator != remainder.startIndex else {
            return false
        }
        let suffix = String(remainder[separator...])
        return suffixes.contains { suffix == $0 || suffix.hasPrefix($0 + "/") }
    }

    /// 本地化展示名（slim/unknown 等未知键回退原文）。
    var displayLabel: String {
        let localized = L10n.shared.t("file.\(label)")
        return localized == "file.\(label)" ? label : localized
    }
}

/// One background inventory result. It is safe to show from disk cache because
/// the native apply path still revalidates the app and file identities before
/// performing any side effect.
struct UninstallPlan: Codable, Equatable, Sendable {
    let files: [UninstallFile]
    /// Identities captured with the uninstall preview for final TOCTOU checks.
    let fileIdentities: [String: String]
    let needsAdmin: Bool
    let isBrewCask: Bool
    let caskToken: String
    /// Whether the scan included macOS-protected app container roots.
    /// Apply must reuse the same coverage so its revalidation cannot silently
    /// broaden access or produce a different route.
    let includesProtectedAppData: Bool
    let scannedAt: Date

    /// Derived once at the inventory boundary, never inside a sort comparator
    /// or a SwiftUI body. Do not persist it: old cache files remain compatible
    /// and a restored plan uses the current classification rules.
    let space: UninstallSpaceBreakdown

    private enum CodingKeys: String, CodingKey {
        case files, fileIdentities, needsAdmin, isBrewCask, caskToken, includesProtectedAppData, scannedAt
    }

    init(files: [UninstallFile], fileIdentities: [String: String]? = nil,
         needsAdmin: Bool, isBrewCask: Bool,
         caskToken: String, includesProtectedAppData: Bool, scannedAt: Date) {
        self.files = files
        self.fileIdentities = fileIdentities ?? files.reduce(into: [String: String]()) { result, file in
            if let identity = DeletionPlan.identity(at: file.path) { result[file.path] = identity }
        }
        self.needsAdmin = needsAdmin
        self.isBrewCask = isBrewCask
        self.caskToken = caskToken
        self.includesProtectedAppData = includesProtectedAppData
        self.scannedAt = scannedAt
        self.space = UninstallSpaceBreakdown(files: files)
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(files: try values.decode([UninstallFile].self, forKey: .files),
                  fileIdentities: try values.decodeIfPresent([String: String].self, forKey: .fileIdentities),
                  needsAdmin: try values.decode(Bool.self, forKey: .needsAdmin),
                  isBrewCask: try values.decode(Bool.self, forKey: .isBrewCask),
                  caskToken: try values.decode(String.self, forKey: .caskToken),
                  includesProtectedAppData: try values.decode(Bool.self, forKey: .includesProtectedAppData),
                  scannedAt: try values.decode(Date.self, forKey: .scannedAt))
    }
}

struct UninstallInventoryRecord: Equatable, Sendable {
    let app: UninstallApp
    let plan: UninstallPlan
}

/// 卸载详情中的互斥空间口径。父目录已覆盖子目录时只计算父目录，
/// 用于卸载列表和详情中的可回收空间估算。
struct UninstallSpaceBreakdown: Equatable, Sendable {
    let appBytes: UInt64
    let cacheBytes: UInt64
    let dataBytes: UInt64

    var totalBytes: UInt64 {
        Self.saturatedSum([appBytes, cacheBytes, dataBytes])
    }

    init(files: [UninstallFile], homeDirectory: String = NSHomeDirectory()) {
        let candidates = files
            .filter { !$0.informational }
            .sorted { lhs, rhs in
                let lhsDepth = (lhs.standardizedPath as NSString).pathComponents.count
                let rhsDepth = (rhs.standardizedPath as NSString).pathComponents.count
                if lhsDepth != rhsDepth { return lhsDepth < rhsDepth }
                if lhs.isAppBundle != rhs.isAppBundle { return lhs.isAppBundle }
                return lhs.standardizedPath < rhs.standardizedPath
            }

        var coveredPaths: [String] = []
        var appFiles: [UninstallFile] = []
        var cacheFiles: [UninstallFile] = []
        var dataFiles: [UninstallFile] = []

        for file in candidates {
            let path = file.standardizedPath
            let isCovered = coveredPaths.contains { parent in
                path == parent || path.hasPrefix(parent + "/")
            }
            guard !isCovered else { continue }
            coveredPaths.append(path)

            if file.isAppBundle {
                appFiles.append(file)
            } else if file.isCache(homeDirectory: homeDirectory) {
                cacheFiles.append(file)
            } else {
                dataFiles.append(file)
            }
        }

        appBytes = Self.saturatedSum(appFiles.map(\.bytes))
        cacheBytes = Self.saturatedSum(cacheFiles.map(\.bytes))
        dataBytes = Self.saturatedSum(dataFiles.map(\.bytes))
    }

    private static func saturatedSum(_ values: [UInt64]) -> UInt64 {
        values.reduce(0) { result, value in
            let (sum, overflow) = result.addingReportingOverflow(value)
            return overflow ? .max : sum
        }
    }
}

/// 开发环境条目（runtime=可清理版本，current=使用中，manager=工具本体）。
struct DevEnvEntry: Identifiable, Equatable {
    let bytes: UInt64
    let kind: String
    let name: String
    let path: String
    let relatedBytes: UInt64
    let relatedPath: String?

    var id: String { path }
    var manager: String { name.components(separatedBy: " · ").first ?? name }
    var versionLabel: String {
        name.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
    }
    var isCurrent: Bool { kind == "current" }
    var isManager: Bool { kind == "manager" }
    /// 系统内置运行时（macOS 自带，禁止清理）。
    var isBuiltin: Bool { kind == "builtin" }
    var hasVersionGlobalPackages: Bool {
        manager == "nvm" && relatedBytes > 0 && relatedPath != nil
    }
}

/// `mole analyze --json` 的目录/文件条目。
struct AnalyzeEntry: Identifiable, Codable, Equatable {
    let name: String
    let path: String
    let size: UInt64
    let isDir: Bool
    var insight: Bool?
    var cleanable: Bool?
    var lastAccess: String?

    var id: String { path }

    enum Handling: Int {
        case directCleanup = 0
        case browse = 1
        case appData = 2
        case application = 3
        case systemReadOnly = 4
    }

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case isDir = "is_dir"
        case insight, cleanable
        case lastAccess = "last_access"
    }

    /// 客户端洞察：识别清理规则之外的可疑占用（日志、Source Map、内存快照等）。
    var hintKind: String? {
        let lower = name.lowercased()
        if isDir {
            let artifactDirs = ["node_modules", "target", "build", "dist", "out",
                                ".gradle", ".next", ".nuxt", ".turbo", ".cache",
                                "deriveddata", "cmake-build-debug", "cmake-build-release"]
            if artifactDirs.contains(lower) { return "hint.artifact" }
            if lower == "logs" || lower.hasSuffix(".logs") { return "hint.log" }
            return nil
        }
        if lower.hasSuffix(".memgraph") || lower.hasSuffix(".heapdump")
            || lower.hasSuffix(".alloc") || lower.hasSuffix(".hprof") {
            return "hint.snapshot"
        }
        if lower.hasSuffix(".map") || lower.hasSuffix(".map.gz") || lower.hasSuffix(".js.map") {
            return "hint.map"
        }
        if lower.hasSuffix(".log") || lower.contains(".log.") || lower.hasSuffix(".out") {
            return "hint.log"
        }
        if lower.hasSuffix(".core") || lower.hasSuffix(".dump") || lower.hasSuffix(".crash") {
            return "hint.dump"
        }
        if lower.hasSuffix(".trace") || lower.hasSuffix(".trace.zip") {
            return "hint.trace"
        }
        return nil
    }

    var handling: Handling {
        if isSystemManaged { return .systemReadOnly }
        if isApplicationBundle { return .application }
        if canCleanDirectly { return .directCleanup }
        if isManagedAppData { return .appData }
        return .browse
    }

    /// Direct cleanup is intentionally narrower than "visible in analysis":
    /// ordinary directories are drill-down containers, while files and Mole-
    /// verified regenerable directories can be selected.
    var canCleanDirectly: Bool {
        guard !isSystemManaged, !isApplicationBundle, !isProtectedContainer else { return false }
        if isManagedAppData { return isDir && cleanable == true }
        return isDir ? cleanable == true : true
    }

    var isApplicationBundle: Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalized != "/Applications" else { return false }
        if normalized.lowercased().hasSuffix(".app") { return true }
        guard normalized.hasPrefix("/Applications/") else { return false }
        return normalized.dropFirst("/Applications/".count)
            .split(separator: "/").first?.lowercased().hasSuffix(".app") == true
    }

    var isSystemManaged: Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let roots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/var", "/etc"]
        return roots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
    }

    var isManagedAppData: Bool {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let library = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library").standardizedFileURL.path
        return normalized == library || normalized.hasPrefix(library + "/")
    }

    private var isProtectedContainer: Bool {
        guard isDir else { return false }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let protected = ["/", "/Applications", home, home + "/Library",
                         home + "/Desktop", home + "/Documents", home + "/Downloads"]
        return protected.contains(normalized)
    }

    static func analysisOrder(_ lhs: AnalyzeEntry, _ rhs: AnalyzeEntry) -> Bool {
        if lhs.size != rhs.size { return lhs.size > rhs.size }
        if lhs.handling.rawValue != rhs.handling.rawValue {
            return lhs.handling.rawValue < rhs.handling.rawValue
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}

/// `mole analyze --json` 的完整报告。
struct AnalyzeReport: Codable {
    let path: String
    let overview: Bool
    let entries: [AnalyzeEntry]
    let largeFiles: [LargeFile]?
    let totalSize: UInt64
    let totalFiles: Int?

    struct LargeFile: Codable {
        let name: String
        let path: String
        let size: UInt64
    }

    enum CodingKeys: String, CodingKey {
        case path, overview, entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }
}

/// 磁盘分析中的用户管理 AI 内容。仅来自专用白名单扫描器，默认不选。
struct AnalyzeAIItem: Identifiable, Equatable {
    enum Kind: String {
        case skill
        case linkedSkill = "skill_link"
        case mcpCache = "mcp_cache"
    }

    let bytes: UInt64
    let kind: Kind
    let name: String
    let path: String

    var id: String { path }
    var isLinkedSkill: Bool { kind == .linkedSkill }
}

/// APFS 本地快照条目。
struct SnapshotInfo: Identifiable, Equatable {
    let name: String
    var id: String { name }
}

/// `docker system df` 的一行摘要（原始人读字符串直接透传）。
struct DockerDfRow: Identifiable, Equatable {
    let type: String
    let count: String
    let size: String
    let reclaimable: String

    var id: String { type }
}

/// Shell 配置体检发现项。
struct ShellIssue: Identifiable, Equatable {
    let file: String
    let kind: String   // path-dup / path-dead / orphan
    let detail: String
    let line: Int

    var id: String { "\(file)#\(line)#\(kind)#\(detail)" }
    /// 展示用的短路径（~ 化）与位置。
    var shortFile: String {
        let home = NSHomeDirectory()
        return file.hasPrefix(home) ? "~" + file.dropFirst(home.count) : file
    }
    var location: String { line > 0 ? "\(shortFile):\(line)" : shortFile }
}

/// 系统代理残留条目。
struct ProxyIssue: Identifiable, Equatable {
    let service: String
    let kind: String   // http / https / socks
    let endpoint: String

    var id: String { "\(service)#\(kind)" }
}

struct RunResult {
    let output: String
    let errorOutput: String
    let exitCode: Int32
    let timedOut: Bool

    init(output: String, errorOutput: String = "", exitCode: Int32, timedOut: Bool) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitCode = exitCode
        self.timedOut = timedOut
    }

    var succeeded: Bool { exitCode == 0 && !timedOut }
    /// 失败日志优先展示 stderr；没有 stderr 时回退到普通输出。
    var diagnosticOutput: String { errorOutput.isEmpty ? output : errorOutput }
}

enum ByteFormat {
    static func format(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", value / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.1f MB", value / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", value / 1_000) }
        return "\(bytes) B"
    }

    /// 紧凑短格式（环形图等窄空间用）：18.2G / 742M。
    static func short(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if bytes >= 1_000_000_000 { return String(format: "%.1fG", value / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.0fM", value / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0fK", value / 1_000) }
        return "\(bytes)B"
    }

    /// 内存专用短格式。macOS 的 `hw.memsize` 以字节返回，但硬件容量按
    /// 1024 进制标称；不能复用磁盘清理使用的十进制容量格式，否则 16 GiB
    /// 会被误显示为 17.2G。
    static func memoryShort(_ bytes: UInt64) -> String {
        let kib = UInt64(1_024)
        let mib = kib * 1_024
        let gib = mib * 1_024
        let value = Double(bytes)
        if bytes >= gib {
            let gibibytes = value / Double(gib)
            if abs(gibibytes.rounded() - gibibytes) < 0.05 {
                return String(format: "%.0fG", gibibytes)
            }
            return String(format: "%.1fG", gibibytes)
        }
        if bytes >= mib { return String(format: "%.0fM", value / Double(mib)) }
        if bytes >= kib { return String(format: "%.0fK", value / Double(kib)) }
        return "\(bytes)B"
    }

    /// 解析引擎预览文件中的 "12.5 MB" / "size unknown" 标签。
    static func parse(_ label: String) -> UInt64 {
        let scanner = Scanner(string: label)
        guard let number = scanner.scanDouble() else { return 0 }
        let unit = String(label[scanner.currentIndex...]).uppercased()
        let multiplier: Double
        if unit.contains("TB") { multiplier = 1_000_000_000_000 }
        else if unit.contains("GB") { multiplier = 1_000_000_000 }
        else if unit.contains("MB") { multiplier = 1_000_000 }
        else if unit.contains("KB") { multiplier = 1_000 }
        else { multiplier = 1 }
        return UInt64(max(0, number * multiplier))
    }
}

extension Notification.Name {
    /// 截图完成（screencapture 输出文件就绪），携带图片 URL。
    static let smTakeScreenshot = Notification.Name("SMTakeScreenshot")
    static let smOpenScreenshotEditor = Notification.Name("SMOpenScreenshotEditor")
}
