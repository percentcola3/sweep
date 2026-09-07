import Foundation
import SwiftUI
import AppKit
import Combine
import CryptoKit
import Darwin

/// 全局状态与业务流协调：指标采样、扫描/清理、卸载、开发环境、进程端口、
/// 图片清单、日志与确认弹窗。核心清理、分析、卸载和优化走 NativeCore；
/// 图片、Docker、Simulator 等特色能力继续使用各自桥接。文案统一经 L10n 取当前语言。
@MainActor
final class AppState: ObservableObject {
    struct Confirmation: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let onConfirm: () -> Void
    }

    // MARK: 指标

    @Published var metrics = MetricsSnapshot()
    @Published var networkHistory: [Double] = []
    /// 快捷面板展示的内存占用最高应用组（按内存排序前 5）。
    @Published var topMemoryApps: [ProcessRow] = []
    private var topMemoryInFlight = false
    private var lastTopMemoryRefresh = Date.distantPast

    // MARK: 窗口与导航

    /// 功能页标识：设置中可按需隐藏。
    enum PageKey: String, CaseIterable, Identifiable {
        case cleanup, analyze, uninstall, optimize, system, devenv, processes, ports, images, clipboard
        var id: String { rawValue }
        var titleKey: String { "tab.\(rawValue)" }

        /// 剪贴板页由功能开关直接控制，不参与普通页面显隐配置。
        static var configurableCases: [PageKey] {
            allCases.filter { $0 != .clipboard }
        }
    }

    @Published var selectedTab = 0
    /// 用户隐藏的页面（UserDefaults 持久化）。
    @Published var hiddenPages: Set<String> = []
    @Published var showSettingsSheet = false
    var mainWindowVisible = false

    var visiblePages: [PageKey] {
        var pages = PageKey.configurableCases.filter { !hiddenPages.contains($0.rawValue) }
        if clipboardHistoryEnabled { pages.append(.clipboard) }
        return pages
    }

    /// 跳转到指定功能页（考虑页面被隐藏的情况）。
    func jump(to key: PageKey) {
        if let index = visiblePages.firstIndex(of: key) {
            selectedTab = index
        }
    }

    func setPageVisible(_ key: PageKey, _ visible: Bool) {
        guard key != .clipboard else { return }
        let previousPages = visiblePages
        let selectedPage = previousPages.indices.contains(selectedTab) ? previousPages[selectedTab] : nil
        if visible {
            hiddenPages.remove(key.rawValue)
        } else {
            // 至少保留一个可见页
            guard visiblePages.count > 1 else { return }
            hiddenPages.insert(key.rawValue)
        }
        UserDefaults.standard.set(Array(hiddenPages), forKey: "SMHiddenPages")
        if let selectedPage, let newIndex = visiblePages.firstIndex(of: selectedPage) {
            selectedTab = newIndex
        } else {
            selectedTab = min(selectedTab, max(0, visiblePages.count - 1))
        }
    }

    // MARK: 清理

    @Published var categories: [CleanupCategory] = []
    @Published var family: CleanupFamily = .clean
    @Published var isScanning = false
    @Published var isApplying = false
    @Published var cleanupScanComplete = true
    @Published var statusText: String
    /// 用户手动扫描的目录进度；页面激活不触发扫描。
    @Published var cleanupProgress = CleanupScanProgress()
    @Published var cleanupScanMode: CleanupScanMode = .quick
    @Published var cleanupDeferredPaths: [String] = []
    private var cleanupScanControl: CleanupScanControl?
    private var cleanupProgressGeneration = 0
    var isCleanupScanning: Bool { isScanning }

    // MARK: 系统数据

    /// 系统数据页的独立清单：root 拥有的日志、报告与缓存。
    /// 与通用清理页的 categories/family 完全解耦，避免互相覆盖状态。
    @Published var systemEntries: [SystemDataEntry] = []
    @Published var systemScanning = false
    @Published var systemScanComplete = false
    /// 本次会话通过系统数据页实际回收的字节数（由执行脚本回报）。
    @Published var systemSessionReclaimed: UInt64 = 0

    var systemHasResult: Bool { systemScanComplete || !systemEntries.isEmpty }

    var systemFoundBytes: UInt64 {
        systemEntries.reduce(0) { $0 &+ $1.bytes }
    }

    var systemSelectedCount: Int {
        systemEntries.filter(\.selected).count
    }

    var systemSelectedBytes: UInt64 {
        systemEntries.filter(\.selected).reduce(0) { $0 &+ $1.bytes }
    }

    // MARK: 系统优化

    @Published var optimizeTasks: [NativeCore.OptimizeTask] = NativeCore.shared.initialOptimizeTasks()
    @Published var isOptimizing = false
    @Published var optimizeStatus = ""

    // MARK: 日志

    @Published var logLines: [String] = []
    @Published var logUnread = 0
    @Published var showLogDrawer = false

    // MARK: 进程与端口

    @Published var processRows: [ProcessRow] = []
    @Published var processStatus: String
    @Published var advancedProcesses = false {
        didSet {
            guard oldValue != advancedProcesses else { return }
            if !advancedProcesses { resetAutomaticProcessCleanup() }
            refreshProcesses()
        }
    }
    @Published var portRows: [PortRow] = []
    @Published var portStatus: String
    @Published var runtimeInFlight = false
    private var automaticProcessTracker = RuntimeStore.AutomaticCandidateTracker()
    private var automaticProcessCleanupAttempted = 0
    private var automaticProcessCleanupSucceeded = 0
    private var automaticProcessCleanupTokens: Set<String> = []

    // MARK: 图片

    @Published var images: [ImageItem] = []
    @Published var imageTotal = 0
    @Published var imageStatus: String
    @Published var isScanningImages = false

    // MARK: 应用卸载

    @Published var installedApps: [UninstallApp] = []
    @Published private(set) var uninstallPlans: [String: UninstallPlan] = [:]
    @Published var appListStatus: String
    @Published var isScanningApps = false
    @Published private(set) var isRestoringInstalledApps = true
    @Published var uninstallSearch = ""
    @Published private(set) var filteredApps: [UninstallApp] = []
    @Published private(set) var uninstallQueue = UninstallQueue()
    private let uninstallPresentationQueue = DispatchQueue(
        label: "com.forgesweep.uninstall-presentation", qos: .userInitiated)
    private var isStoppingUninstallQueue = false
    var isPreviewingUninstall: Bool { uninstallQueue.activeJob?.state == .preparing }
    var isUninstalling: Bool { uninstallQueue.activeJob != nil }

    // MARK: 开发环境

    @Published var devEnvEntries: [DevEnvEntry] = []
    @Published var devEnvSelection: Set<String> = []
    @Published var devEnvStatus: String
    @Published var isScanningEnv = false

    // MARK: 包管理 GC（owner 命令，无直接删除）

    @Published var gcActions: [GcAction] = []
    @Published var gcRunningId: String?
    private var gcScanned = false

    // MARK: Docker

    @Published var dockerDfRows: [DockerDfRow] = []
    let simulatorInventory = SimulatorInventoryStore()
    let dockerInventory = DockerInventoryStore()
    @Published var showSimulatorDevices = false
    @Published var showDockerDetails = false

    // MARK: 项目雷达与受限自动化

    let savedScanLocations = SavedScanLocationStore()
    let projectRadar = ProjectRadarStore()
    let projectHibernation = ProjectHibernationService()
    let smartAutomation = AutomationStore()
    @Published var showProjectRadar = false
    @Published var showAutomationSettings = false
    @Published var isSmartAutomationRunning = false

    var automationAuthorizedLocationIDs: Set<UUID> {
        Set(savedScanLocations.locations.compactMap { location in
            autoCleanupRules.contains {
                $0.directory == location.path && $0.isEnabled && $0.isSafetyAuthorized
            } ? location.id : nil
        })
    }

    // MARK: 自动目录清理

    @Published var autoCleanupRules: [AutoCleanupRule] = AutoCleanupRuleStore.load()
    @Published var autoCleanupPreview: AutoCleanupPlan?
    @Published var autoCleanupPreviewRuleID: UUID?
    @Published var isAutoCleanupScanning = false
    @Published var autoCleanupStatus = ""
    @Published var showAutoCleanupSheet = false

    // MARK: 配置体检（Shell rc + 网络配置，只读）

    @Published var shellIssues: [ShellIssue] = []
    @Published var shellAudited = false
    @Published var netProxies: [ProxyIssue] = []
    @Published var netHosts: [String] = []
    @Published var netAudited = false
    @Published var netFixRunning = false
    private var configAuditsStarted = false

    /// Shell 与网络配置体检（只读，每次会话一次）。
    func runConfigAudits(force: Bool = false) {
        if configAuditsStarted && !force { return }
        configAuditsStarted = true
        log(l10n.t("log.shellAudit"))
        Task {
            let shell = await MoleEngine.shared.runBridge("bin/app_shell_audit.sh", timeout: 60)
            shellIssues = Parsers.shellIssues(shell.output)
            shellAudited = true
            let net = await MoleEngine.shared.runBridge("bin/app_net_audit.sh", timeout: 60)
            let parsed = Parsers.netAudit(net.output)
            netProxies = parsed.proxies
            netHosts = parsed.hosts
            netAudited = true
        }
    }

    func openInEditor(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// 关闭某个网络服务上的代理（owner 命令 networksetup，需管理员授权）。
    func disableProxy(_ proxy: ProxyIssue) {
        guard !netFixRunning else { return }
        confirmation = Confirmation(
            title: l10n.tf("audit.fixProxy.title", proxy.kind, proxy.service),
            message: l10n.t("audit.fixProxy.msg"),
            confirmLabel: l10n.t("audit.fixProxy")) { [weak self] in
                guard let self else { return }
                self.netFixRunning = true
                Task {
                    let result = await MoleEngine.shared.runPrivilegedBridge(
                        "bin/app_net_fixproxy.sh",
                        arguments: [proxy.service, proxy.kind], timeout: 120)
                    self.netFixRunning = false
                    self.log(self.l10n.t("log.proxyOff"))
                    self.logFailure(result)
                    let net = await MoleEngine.shared.runBridge("bin/app_net_audit.sh", timeout: 60)
                    let parsed = Parsers.netAudit(net.output)
                    self.netProxies = parsed.proxies
                    self.netHosts = parsed.hosts
                }
            }
    }

    var devEnvManagers: [(manager: String, entries: [DevEnvEntry])] {
        var order: [String] = []
        var buckets: [String: [DevEnvEntry]] = [:]
        for entry in devEnvEntries where !entry.isManager {
            if buckets[entry.manager] == nil { order.append(entry.manager) }
            buckets[entry.manager, default: []].append(entry)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    var devEnvManagerEntries: [DevEnvEntry] {
        devEnvEntries.filter(\.isManager)
    }

    var devEnvSelectedBytes: UInt64 {
        devEnvEntries.filter { devEnvSelection.contains($0.path) }.reduce(0) { $0 + $1.bytes }
    }

    var devEnvSelectedGlobalPackageBytes: UInt64 {
        devEnvEntries.filter { devEnvSelection.contains($0.path) }
            .reduce(0) { $0 + $1.relatedBytes }
    }

    // MARK: 磁盘分析

    @Published var analyzePath: String = NSHomeDirectory()
    @Published var analyzeEntries: [AnalyzeEntry] = []
    @Published var analyzeSelection: Set<String> = []
    @Published var analyzeAIItems: [AnalyzeAIItem] = []
    @Published var analyzeAISelection: Set<String> = []
    @Published var analyzeTotalSize: UInt64 = 0
    @Published var analyzeLargeFiles: [AnalyzeReport.LargeFile] = []
    @Published var isAnalyzing = false
    @Published var analyzeIsOverview = false
    @Published var analyzeStatus: String

    // APFS 快照（本地 Time Machine 快照与可清除空间）
    @Published var purgeableBytes: UInt64 = 0
    @Published var localSnapshots: [SnapshotInfo] = []
    @Published var snapshotsScanned = false
    @Published var isThinning = false

    // 大文件重复检测
    @Published var dupGroups: [[AnalyzeEntry]] = []
    @Published var dupSelection: Set<String> = []
    @Published var isScanningDups = false

    var analyzeSelectedBytes: UInt64 {
        analyzeEntries.filter {
            analyzeSelection.contains($0.path) && $0.canCleanDirectly
        }.reduce(0) { $0 + $1.size }
    }

    var analyzeAISelectedBytes: UInt64 {
        analyzeAIItems.filter { analyzeAISelection.contains($0.path) }
            .reduce(0) { $0 + $1.bytes }
    }

    var analyzeCombinedSelectedBytes: UInt64 {
        analyzeSelectedBytes &+ analyzeAISelectedBytes
    }

    var analyzeCombinedSelectedCount: Int {
        analyzeSelection.count + analyzeAISelection.count
    }

    var dupSelectedPaths: [String] {
        dupGroups.flatMap { $0 }.filter {
            dupSelection.contains($0.path) && $0.canCleanDirectly
        }.map(\.path)
    }

    // MARK: 白名单

    @Published var whitelistEntries: [String] = []
    @Published var showWhitelistSheet = false

    // MARK: 确认弹窗

    @Published var confirmation: Confirmation?
    private var isDispatchingConfirmation = false

    /// Keep the disk worker gated while the alert closes and its accepted
    /// action is dispatched. Otherwise it can race a cleanup confirmation.
    func runConfirmation() {
        guard let accepted = confirmation else { return }
        isDispatchingConfirmation = true
        confirmation = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            accepted.onConfirm()
            self.isDispatchingConfirmation = false
            self.startNextUninstallIfPossible()
        }
    }
    @Published var slimRequest: ((String) -> Void)?

    // MARK: 剪贴板历史与截图（设置中可开关）

    let clipboardManager = ClipboardHistoryManager()
    @Published var clipboardHistoryEnabled: Bool {
        didSet {
            UserDefaults.standard.set(clipboardHistoryEnabled, forKey: "SMClipboardHistory")
            clipboardHistoryEnabled ? clipboardManager.start() : clipboardManager.stop()
            if !clipboardHistoryEnabled {
                selectedTab = min(selectedTab, max(0, visiblePages.count - 1))
            }
        }
    }
    @Published var screenshotHotKeyEnabled: Bool {
        didSet {
            UserDefaults.standard.set(screenshotHotKeyEnabled, forKey: "SMShotHotKey")
            if screenshotHotKeyEnabled {
                screenshotHotKeyRegistrationFailed = !HotKeyCenter.shared.register {
                    NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
                }
            } else {
                HotKeyCenter.shared.unregister()
                screenshotHotKeyRegistrationFailed = false
            }
        }
    }
    @Published private(set) var screenshotHotKeyRegistrationFailed = false

    // MARK: 权限中心

    let permissionCenter = PermissionCenter.shared
    let authorizationCoordinator = AuthorizationCoordinator()
    @Published var showPermissionCenter = false
    private var activeProtectedOperation: ProtectedOperation?

    /// 受保护扫描脚本必须显式收到这个能力标记；脚本默认无标记时拒绝枚举
    /// Desktop、Documents 等 TCC 目录，形成 UI 门禁之外的第二层防护。
    private var fullDiskScanEnvironment: [String: String] {
        guard permissionCenter.fullDiskAccessGranted else { return [:] }
        return ["FORGESWEEP_FULL_DISK_AUTHORIZED": "1"]
    }

    var hasPendingPermissionAction: Bool {
        authorizationCoordinator.pendingOperation != nil
    }

    /// 明确登记可持久化的扫描意图。未授权时只打开权限中心，不执行扫描。
    func requestScanAccess(_ operation: ProtectedOperation) {
        guard authorize(operation, presentingPermissionCenter: true) else { return }
        executeProtectedOperation(operation)
    }

    /// 快捷面板必须对每次点击给出可见反馈。先打开主窗口，再由这里判断
    /// 全局互斥；不能像旧实现那样因任意后台任务直接禁用按钮并静默丢弃。
    func requestQuickOptimizeFromQuickPanel() {
        jump(to: .cleanup)
        guard !isBusy else {
            let message = l10n.t("status.quickOptimizeBusy")
            statusText = message
            log(message)
            return
        }
        requestScanAccess(.quickOptimize)
    }

    func recheckFullDiskAccess() {
        guard permissionCenter.refresh() else {
            permissionCenter.reportDiskAccessNotDetected()
            return
        }
        resumePendingAuthorizedOperation()
    }

    func presentPermissionCenter() {
        permissionCenter.refresh()
        permissionCenter.clearDiskAuthorizationError()
        showSettingsSheet = false
        showPermissionCenter = true
    }

    func completePermissionSetup() {
        guard permissionCenter.refresh() else {
            if hasPendingPermissionAction {
                permissionCenter.reportDiskAccessNotDetected()
            } else {
                showPermissionCenter = false
            }
            return
        }
        resumePendingAuthorizedOperation()
    }

    func cancelPermissionCenter() {
        authorizationCoordinator.clearPending()
        showPermissionCenter = false
    }

    /// 应用从系统设置返回、重新激活或重启时调用。权限确认成功后，持久化操作
    /// 会先被消费再执行，因此多个激活通知也只会恢复一次。
    func refreshAuthorizationAndResume() {
        let granted = permissionCenter.refresh()
        guard granted else {
            if hasPendingPermissionAction { showPermissionCenter = true }
            return
        }
        activateProtectedDiskServices()
        // Permission availability is not a scan request. Only resume an
        // explicit user action that was waiting for authorization.
        guard hasPendingPermissionAction else { return }
        resumePendingAuthorizedOperation()
    }

    @discardableResult
    private func authorize(_ operation: ProtectedOperation,
                           presentingPermissionCenter: Bool) -> Bool {
        if activeProtectedOperation == operation { return true }
        guard permissionCenter.refresh() else {
            if presentingPermissionCenter {
                authorizationCoordinator.storePending(operation)
                presentPermissionCenter()
            }
            return false
        }
        return true
    }

    private func resumePendingAuthorizedOperation() {
        guard permissionCenter.fullDiskAccessGranted else { return }
        activateProtectedDiskServices()
        guard authorizationCoordinator.pendingOperation != nil else {
            showPermissionCenter = false
            return
        }
        // Busy 时保留待执行任务；下一个激活/显式“完成”会继续尝试。
        guard !isBusy else { return }
        guard let operation = authorizationCoordinator.takePending() else { return }
        showPermissionCenter = false
        executeProtectedOperation(operation)
    }

    private func executeProtectedOperation(_ operation: ProtectedOperation) {
        guard permissionCenter.refresh() else {
            authorizationCoordinator.storePending(operation)
            presentPermissionCenter()
            return
        }
        guard !isBusy else { return }

        activeProtectedOperation = operation
        defer { activeProtectedOperation = nil }
        switch operation {
        case .cleanupScan(let force): scanCleanup(force: force)
        case .deepCleanupScan: scanCleanup(force: true, mode: .deep)
        case .quickOptimize: quickOptimize()
        case .optimize: runOptimize()
        case .developerToolsScan: scanDeveloperTools()
        case .aiScan: scanAI()
        case .xcodeScan: scanXcode()
        case .slimScan: scanSlim()
        case .systemScan: scanSystemData()
        case .imageScan: scanImages()
        case .installedAppsScan: scanInstalledApps()
        case .uninstall(let app): previewUninstall(app)
        case .developmentEnvironmentScan: scanDevEnv()
        case .diskOverview(let force): scanDiskOverview(force: force)
        case .diskAnalyze(let path): scanAnalyze(path)
        case .duplicateScan: scanDuplicates()
        case .openProjectRadar: openProjectRadar()
        case .openAutomationSettings: openAutomationSettings()
        case .restoreProject(let receipt): restoreHibernatedProject(receipt)
        case .previewAutoCleanup(let ruleID): previewAutoCleanup(ruleID)
        case .runAutoCleanup(let ruleID): runAutoCleanupNow(ruleID)
        }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var scheduledAutomationRetry: DispatchWorkItem?
    private var reportedScheduledPermissionRequirement = false
    private var uninstallInventoryRefreshWorkItem: DispatchWorkItem?
    private var uninstallInventoryWatchers: [DispatchSourceFileSystemObject] = []
    private var uninstallInventoryWatchedPaths: Set<String> = []
    private var uninstallInventoryGeneration = 0
    private let l10n = L10n.shared

    var isBusy: Bool {
        isBusyExcludingUninstall || uninstallQueue.hasWork
    }

    private var isBusyExcludingUninstall: Bool {
        isScanning || isApplying || isScanningImages
            || isScanningEnv
            || isAnalyzing || isThinning || isScanningDups
            || gcRunningId != nil || netFixRunning || isAutoCleanupScanning
            || isSmartAutomationRunning || projectHibernation.isWorking
            || isOptimizing || systemScanning
            || simulatorInventory.isDeleting || projectRadar.isScanning
    }

    var selectedCount: Int {
        categories.reduce(0) { $0 + $1.selectedPathCount }
    }

    var selectedBytes: UInt64 {
        categories.reduce(0) { $0 &+ $1.selectedPathBytes }
    }

    var quickCleanCount: Int {
        categories.filter(\.quickCleanEligible).reduce(0) { $0 + $1.selectedPathCount }
    }

    var quickCleanBytes: UInt64 {
        categories.filter(\.quickCleanEligible).reduce(0) { $0 &+ $1.selectedPathBytes }
    }

    var reviewCount: Int {
        categories.filter { $0.risk == .warning }.reduce(0) { $0 + $1.paths.count }
    }

    var totalBytes: UInt64 {
        categories.reduce(0) { $0 + $1.bytes }
    }

    init() {
        let knownPages = Set(PageKey.configurableCases.map(\.rawValue))
        var sanitizedHiddenPages = Set(UserDefaults.standard.stringArray(forKey: "SMHiddenPages") ?? [])
            .intersection(knownPages)
        if sanitizedHiddenPages.count == PageKey.configurableCases.count {
            sanitizedHiddenPages.remove(PageKey.cleanup.rawValue)
        }
        hiddenPages = sanitizedHiddenPages
        UserDefaults.standard.set(Array(sanitizedHiddenPages), forKey: "SMHiddenPages")
        clipboardHistoryEnabled = UserDefaults.standard.object(forKey: "SMClipboardHistory") as? Bool ?? false
        screenshotHotKeyEnabled = UserDefaults.standard.object(forKey: "SMShotHotKey") as? Bool ?? true

        statusText = L10n.shared.t("status.ready")
        processStatus = L10n.shared.t("proc.status.apps") // 会在首次刷新时替换为带数量文案
        portStatus = L10n.shared.t("ports.status.none")
        imageStatus = L10n.shared.t("img.status.none")
        appListStatus = L10n.shared.t("uninstall.status.none")
        devEnvStatus = L10n.shared.t("devenv.status.empty")
        analyzeStatus = L10n.shared.t("analyze.status.empty")
        autoCleanupStatus = L10n.shared.t("auto.status.ready")
        optimizeStatus = L10n.shared.t("optimize.status.ready")

        Publishers.CombineLatest3($installedApps, $uninstallPlans, $uninstallSearch)
            .debounce(for: .milliseconds(80), scheduler: uninstallPresentationQueue)
            .map { UninstallListProjection.apps($0.0, plans: $0.1, query: $0.2) }
            .receive(on: DispatchQueue.main)
            .assign(to: &$filteredApps)

        let restoreGeneration = uninstallInventoryGeneration
        Task { [weak self] in
            let cachedInventory = await UninstallInventoryCache.restoreInBackground()
            guard let self else { return }
            if self.uninstallInventoryGeneration == restoreGeneration,
               self.installedApps.isEmpty, !self.isScanningApps, !cachedInventory.isEmpty {
                self.uninstallPlans = Dictionary(cachedInventory.map {
                    ($0.app.id, $0.plan)
                }, uniquingKeysWith: { _, latest in latest })
                self.installedApps = cachedInventory.map(\.app)
                self.appListStatus = self.l10n.tf("uninstall.status.count", self.installedApps.count)
            }
            self.isRestoringInstalledApps = false
            self.scheduleUninstallInventoryRefresh(after: cachedInventory.isEmpty ? 0.4 : 2.0)
        }

        refreshMetrics()
        $selectedTab
            .removeDuplicates()
            .sink { [weak self] tab in
                // Let SwiftUI commit the navigation animation before a tab
                // performs synchronous inventory work (notably process rows).
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.selectedTab == tab else { return }
                    let pages = self.visiblePages
                    guard tab < pages.count else { return }
                    switch pages[tab] {
                    case .cleanup:
                        // Keep the existing result/selection. Scanning starts
                        // only from the user's quick/deep scan actions.
                        break
                    case .analyze:
                        self.scanSnapshots()
                        self.permissionCenter.refresh()
                        if self.permissionCenter.fullDiskAccessGranted {
                            self.scanDiskOverview()
                        }
                    case .uninstall:
                        // The page's cancellable loading task starts data work
                        // only after the navigation/placeholder has appeared.
                        break
                    case .optimize:
                        break
                    case .devenv:
                        self.permissionCenter.refresh()
                        if self.devEnvEntries.isEmpty,
                           self.permissionCenter.fullDiskAccessGranted {
                            self.scanDevEnv()
                        }
                        self.scanGc()
                        self.scanDockerDf()
                        self.runConfigAudits()
                    case .processes: self.refreshProcesses()
                    case .ports: self.refreshPorts()
                    default: break
                    }
                }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAuthorizationAndResume() }
            .store(in: &cancellables)
        // 语言切换：重置易变状态文案，避免出现混合语言。
        L10n.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, !self.isBusy else { return }
                self.statusText = self.l10n.t("status.ready")
                self.processStatus = self.l10n.t("proc.status.none")
                self.portStatus = self.l10n.t("ports.status.none")
                if !self.isScanningImages { self.imageStatus = self.l10n.t("img.status.none") }
                if !self.isScanningApps {
                    self.appListStatus = self.installedApps.isEmpty
                        ? self.l10n.t("uninstall.status.none")
                        : self.l10n.tf("uninstall.status.count", self.installedApps.count)
                }
                if !self.isScanningEnv { self.devEnvStatus = self.l10n.t("devenv.status.empty") }
                if !self.isAutoCleanupScanning {
                    self.autoCleanupStatus = self.l10n.t("auto.status.ready")
                }
                if !self.isOptimizing {
                    self.optimizeStatus = self.l10n.t("optimize.status.ready")
                }
            }
            .store(in: &cancellables)
        savedScanLocations.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        projectRadar.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        projectHibernation.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        simulatorInventory.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        authorizationCoordinator.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        clipboardManager.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // Published changes are delivered on the next run-loop turn, after
        // the busy flags have changed. This wakes pending work without polling
        // or coupling the worker to the lifetime of the uninstall tab.
        objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.startNextUninstallIfPossible() }
            .store(in: &cancellables)
        // 服务启动放在所有存储属性初始化完成之后。
        if clipboardHistoryEnabled { clipboardManager.start() }
        if screenshotHotKeyEnabled {
            screenshotHotKeyRegistrationFailed = !HotKeyCenter.shared.register {
                NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
            }
        }
        // /Applications is safe to watch at launch. ~/.Trash is registered
        // only after Full Disk Access has been verified for this process.
        startUninstallInventoryMonitoring(includeProtectedPaths: false)
        DispatchQueue.main.async { [weak self] in
            self?.refreshAuthorizationAndResume()
        }
    }

    func takeScreenshot() {
        permissionCenter.refresh()
        guard permissionCenter.screenRecordingGranted else {
            presentPermissionCenter()
            return
        }
        NotificationCenter.default.post(name: .smTakeScreenshot, object: nil)
    }

    func requestScreenRecordingAccess() {
        _ = permissionCenter.requestScreenRecordingAccess()
    }

    // MARK: - 指标

    func refreshMetrics() {
        metrics = SystemMetrics.sample()
        networkHistory.append(metrics.networkRxMBps)
        if networkHistory.count > 60 { networkHistory.removeFirst(networkHistory.count - 60) }
    }

    /// 仅在快捷面板可见时周期刷新；打开面板和操作完成后可立即刷新。
    func refreshTopMemoryApps(force: Bool = false) {
        guard !topMemoryInFlight,
              force || Date().timeIntervalSince(lastTopMemoryRefresh) >= 6 else { return }
        lastTopMemoryRefresh = Date()
        topMemoryInFlight = true
        Task {
            let rows: [ProcessRow] = await Task.detached(priority: .utility) { () -> [ProcessRow] in
                guard let text = SystemMetrics.processSnapshotText() else { return [] }
                return RuntimeStore.nativeRows(fromProcessText: text).rows
            }.value
            topMemoryInFlight = false
            topMemoryApps = Array(rows.prefix(5))
        }
    }

    /// 快捷面板强杀与进程页共用相同的确认语义。
    func forceQuitTopApp(_ row: ProcessRow) {
        guard !isBusy else { return }
        // 快捷面板可能是当前唯一窗口，不能依赖挂在主窗口上的 SwiftUI alert。
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = l10n.t("proc.confirm.killGroup.title")
        alert.informativeText = l10n.tf("proc.confirm.kill.msg", row.pid)
        let destructiveButton = alert.addButton(withTitle: l10n.t("proc.kill"))
        destructiveButton.hasDestructiveAction = true
        alert.addButton(withTitle: l10n.t("common.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            let result = await MoleEngine.shared.runRuntime("kill-group", row.signalToken)
            if !result.succeeded {
                log(l10n.t("status.signalFailed"))
            }
            refreshTopMemoryApps(force: true)
        }
    }

    // MARK: - 日志

    func appendLogLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        logLines.append(trimmed)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
        if !showLogDrawer { logUnread += 1 }
    }

    func log(_ text: String) {
        for line in text.components(separatedBy: "\n") {
            appendLogLine(line)
        }
    }

    /// 结构化解析始终只读 stdout；失败诊断单独展示 stderr，避免污染 TSV/JSON。
    private func logFailure(_ result: RunResult, stdoutAlreadyLogged: Bool = false) {
        guard !result.succeeded else { return }
        let diagnostic = result.errorOutput.isEmpty
            ? (stdoutAlreadyLogged ? "" : result.output)
            : result.errorOutput
        if !diagnostic.isEmpty { log(diagnostic) }
    }

    /// 引擎输出回调发生在后台线程，这里负责跳回主线程。
    nonisolated private func streamLog(_ line: String) {
        Task { @MainActor in self.appendLogLine(line) }
    }

    // MARK: - 扫描

    private func beginCleanupProgress(mode: CleanupScanMode = .quick) {
        cleanupProgressGeneration += 1
        cleanupScanMode = mode
        cleanupDeferredPaths = []
        cleanupProgress = CleanupScanProgress(
            phase: l10n.t("cleanup.progress.scanning"),
            completed: 0,
            total: 0,
            currentPath: NSHomeDirectory())
    }

    private func cleanupProgressSink() -> CleanupScanProgressSink {
        let generation = cleanupProgressGeneration
        return CleanupScanProgressSink { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self,
                      self.cleanupProgressGeneration == generation,
                      self.isCleanupScanning else { return }
                guard !self.cleanupProgress.isComplete else { return }
                self.cleanupProgress.currentPath = event.currentPath
                guard event.phase == "native", event.total > 0 else { return }
                self.cleanupProgress.completed = max(self.cleanupProgress.completed, event.completed)
                self.cleanupProgress.total = event.total
                self.cleanupProgress.detailCompleted = self.cleanupProgress.completed
                self.cleanupProgress.detailTotal = event.total
            }
        }
    }

    func cancelCleanupScan() {
        cleanupScanControl?.cancel()
        MoleEngine.shared.cancelAll()
    }

    private func finishCleanupProgress() {
        let total = max(1, cleanupProgress.total)
        cleanupProgress.completed = total
        cleanupProgress.total = total
        cleanupProgress.isComplete = true
        cleanupProgress.detailCompleted = max(cleanupProgress.detailCompleted,
                                              cleanupProgress.detailTotal)
        cleanupProgress.phase = l10n.t("cleanup.progress.done")
        cleanupProgress.currentPath = l10n.t("cleanup.progress.done")
    }

    func scanCleanup(force: Bool = false, mode: CleanupScanMode = .quick) {
        let operation: ProtectedOperation = mode == .deep ? .deepCleanupScan : .cleanupScan(force: force)
        guard authorize(operation, presentingPermissionCenter: true) else {
            return
        }
        guard !isBusy else { return }
        family = .clean
        if mode == .quick, !force, let cached = CleanupCache.restore() {
            beginCleanupProgress()
            isScanning = true
            cleanupScanComplete = false
            statusText = l10n.t("status.scanningCleanup")
            Task {
                let snapshot = await captureRunningApplicationSnapshot()
                categories = finalizedCleanupCategories(cached.categories, snapshot: snapshot)
                cleanupScanComplete = snapshot.isComplete
                if !cleanupScanComplete {
                    for index in categories.indices { categories[index].selected = false }
                }
                finishCleanupProgress()
                isScanning = false
                let minutes = max(1, Int(cached.age / 60))
                statusText = cleanupScanComplete
                    ? l10n.tf("status.cacheRestored", minutes)
                    : l10n.t("log.scanPartial")
                log(l10n.tf("log.cacheUsed", categories.reduce(0) { $0 + $1.paths.count },
                            ByteFormat.format(totalBytes)))
            }
            return
        }
        categories = []
        beginCleanupProgress(mode: mode)
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanningCleanup")
        log(l10n.t("log.buildList"))

        Task {
            let scan = await unifiedCleanupScan(mode: mode)
            let combined = finalizedCleanupCategories(scan.categories,
                                                       snapshot: scan.runningSnapshot)
            categories = combined
            cleanupDeferredPaths = scan.deferredPaths
            cleanupScanComplete = scan.allSucceeded
            if !cleanupScanComplete {
                for index in categories.indices { categories[index].selected = false }
            }
            finishCleanupProgress()
            isScanning = false

            scan.results.filter { !$0.succeeded }.forEach { logFailure($0) }
            if combined.isEmpty {
                statusText = scan.allSucceeded
                    ? l10n.t("status.scanEmpty")
                    : l10n.t("log.scanPartial")
                log(scan.allSucceeded ? l10n.t("log.scanEmpty") : l10n.t("log.scanPartial"))
            } else {
                statusText = scan.allSucceeded
                    ? l10n.tf("status.scanDone", combined.count)
                    : l10n.t("log.scanPartial")
                log(scan.allSucceeded
                    ? l10n.tf("log.scanDone", combined.reduce(0) { $0 + $1.paths.count },
                              ByteFormat.format(totalBytes))
                    : l10n.t("log.scanPartial"))
            }
            // Persist a successful empty result as well as a non-empty one.
            // A manual request may reuse a valid snapshot, including an
            // empty one. The cache stores only static scanner output; runtime
            // protection is still reapplied on every restore/use.
            if mode == .quick && scan.cacheable { CleanupCache.save(scan.categories) }
        }
    }

    func quickOptimize() {
        guard authorize(.quickOptimize, presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        family = .clean
        jump(to: .cleanup)
        // One-click clean only prepares the quick inventory. It never opens a
        // confirmation dialog or starts deleting in the background.
        scanCleanup(force: true, mode: .quick)
    }

    /// Run the system-maintenance catalog through the native implementation.
    /// The user confirms once; each task reports its own result and failures do
    /// not prevent the remaining independent checks from running.
    func runOptimize() {
        guard authorize(.optimize, presentingPermissionCenter: true) else { return }
        guard !isBusy else {
            optimizeStatus = l10n.t("optimize.status.busy")
            return
        }
        confirmation = Confirmation(
            title: l10n.t("optimize.confirm.title"),
            message: l10n.t("optimize.confirm.message"),
            confirmLabel: l10n.t("optimize.run")) { [weak self] in
                self?.performOptimize()
            }
    }

    private func performOptimize() {
        guard !isOptimizing else { return }
        isOptimizing = true
        optimizeStatus = l10n.t("optimize.status.running")
        log(l10n.t("optimize.log.start"))
        let requested = optimizeTasks
        Task { @MainActor [weak self] in
            guard let self else { return }
            let report = await NativeCore.shared.runOptimize(tasks: requested)
            self.optimizeTasks = report.tasks
            self.isOptimizing = false
            let applied = report.tasks.filter { $0.state == .applied }.count
            let failed = report.tasks.filter { $0.state == .failed }.count
            self.optimizeStatus = self.l10n.tf("optimize.status.done", applied, failed)
            self.log(self.l10n.tf("optimize.log.done", applied, failed))
        }
    }

    private struct UnifiedCleanupScan {
        let categories: [CleanupCategory]
        /// Keep filesystem scanners separate from the process snapshot. A
        /// process-table failure must not discard completed cache discovery;
        /// the apply boundary still clears/reevaluates runtime-sensitive paths.
        let sourceResults: [RunResult]
        /// Only fully measured paths enter the result. Coverage gaps are
        /// reported separately and prevent persisting a complete snapshot.
        let requiredSourceResults: [RunResult]
        let runtimeResult: RunResult
        let runningSnapshot: RunningApplicationSnapshot
        var deferredPaths: [String] = []

        var results: [RunResult] { sourceResults + [runtimeResult] }

        var sourceScansSucceeded: Bool {
            requiredSourceResults.allSatisfy(\.succeeded)
        }

        var cacheable: Bool { sourceScansSucceeded && deferredPaths.isEmpty }

        /// 进程表失败只隐藏依赖运行态的路径；它不应让已经完成的 cache/log
        /// 扫描整体变成不可用。执行边界仍会 fail-closed 复核。
        var allSucceeded: Bool { sourceScansSucceeded }
    }

    private func unifiedCleanupScan(mode: CleanupScanMode = .quick) async -> UnifiedCleanupScan {
        guard permissionCenter.refresh() else {
            let denied = RunResult(
                output: "", errorOutput: "Full Disk Access is required for protected scan.",
                exitCode: 77, timedOut: false)
            return UnifiedCleanupScan(
                categories: [], sourceResults: [denied],
                requiredSourceResults: [denied],
                runtimeResult: denied, runningSnapshot: .unavailable)
        }
        let control = CleanupScanControl(mode: mode)
        cleanupScanControl = control
        defer { cleanupScanControl = nil }
        let progress = isCleanupScanning ? cleanupProgressSink() : nil
        async let core = NativeCore.shared.scanCleanup(progress: progress, mode: mode, control: control)
        async let runtimeText = Task.detached(priority: .utility) {
            SystemMetrics.processSnapshotText()
        }.value

        let (coreScan, runtimeOutput) = await (core, runtimeText)
        log(coreScan.diagnostics)
        let runtimeResult = RunResult(
            output: runtimeOutput ?? "",
            errorOutput: runtimeOutput == nil ? "Native process snapshot unavailable." : "",
            exitCode: runtimeOutput == nil ? 1 : 0,
            timedOut: false)
        let coreResult = RunResult(
            output: "", errorOutput: coreScan.error ?? "",
            exitCode: coreScan.succeeded ? 0 : 1, timedOut: false)

        let combined = CleanupCategory.safeCleanupCandidates(from: coreScan.categories)

        let snapshot = RuntimeStore.runningApplicationSnapshot(
            fromProcessText: runtimeResult.output, isComplete: runtimeResult.succeeded)
        return UnifiedCleanupScan(
            categories: combined,
            sourceResults: [coreResult],
            requiredSourceResults: [coreResult],
            runtimeResult: runtimeResult,
            runningSnapshot: snapshot,
            deferredPaths: coreScan.deferredPaths)
    }

    private func captureRunningApplicationSnapshot() async -> RunningApplicationSnapshot {
        let output = await Task.detached(priority: .utility) {
            SystemMetrics.processSnapshotText()
        }.value
        let result = RunResult(
            output: output ?? "",
            errorOutput: output == nil ? "Native process snapshot unavailable." : "",
            exitCode: output == nil ? 1 : 0,
            timedOut: false)
        if !result.succeeded { logFailure(result) }
        return RuntimeStore.runningApplicationSnapshot(
            fromProcessText: result.output, isComplete: result.succeeded)
    }

    private func protectRunningApplications(in source: [CleanupCategory],
                                            snapshot: RunningApplicationSnapshot)
        -> [CleanupCategory] {
        source.compactMap {
            CleanupRiskPolicy.runtimeEligibleSubset($0, running: snapshot)
        }.sorted(by: CleanupCategory.sizeDescending)
    }

    private func finalizedCleanupCategories(_ source: [CleanupCategory],
                                            snapshot: RunningApplicationSnapshot)
        -> [CleanupCategory] {
        let safe = CleanupCategory.safeCleanupCandidates(from: source)
        let runtimeChecked = protectRunningApplications(in: safe, snapshot: snapshot)
        // Do not run safeCleanupCandidates a second time: it reselects every
        // path and would undo the runtime guard's partial selection.
        return runtimeChecked
    }

    /// 通用单脚本扫描（开发工具 / AI 垃圾 / 图片瘦身）。
    private func scanSpecial(_ family: CleanupFamily, script: String,
                             timeout: TimeInterval = 180) {
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        self.family = family
        categories = []
        isScanning = true
        cleanupScanComplete = false
        statusText = l10n.t("status.scanning")
        log(l10n.t("log.scanningSafe"))
        Task {
            async let scanResult = MoleEngine.shared.runBridge(
                script, extraEnvironment: scanEnvironment,
                timeout: timeout, onLine: streamLog)
            async let runtimeText = Task.detached(priority: .utility) {
                SystemMetrics.processSnapshotText()
            }.value
            let (result, runtimeOutput) = await (scanResult, runtimeText)
            let runtime = RunResult(
                output: runtimeOutput ?? "",
                errorOutput: runtimeOutput == nil ? "Native process snapshot unavailable." : "",
                exitCode: runtimeOutput == nil ? 1 : 0,
                timedOut: false)
            isScanning = false
            cleanupScanComplete = result.succeeded && runtime.succeeded
            let snapshot = RuntimeStore.runningApplicationSnapshot(
                fromProcessText: runtime.output, isComplete: runtime.succeeded)
            categories = protectRunningApplications(
                in: Parsers.specialCategories(result.output, family: family),
                snapshot: snapshot)
            if !cleanupScanComplete {
                for index in categories.indices { categories[index].selected = false }
            }
            if categories.isEmpty {
                statusText = cleanupScanComplete
                    ? l10n.t("status.specialEmpty") : l10n.t("log.specialFail")
                log(cleanupScanComplete ? l10n.t("log.specialEmpty") : l10n.t("log.specialFail"))
                logFailure(result)
            } else {
                statusText = cleanupScanComplete
                    ? l10n.tf("status.scanSpecialDone", categories.count)
                    : l10n.t("log.specialFail")
                log(cleanupScanComplete
                    ? l10n.tf("log.specialDone", categories.reduce(0) { $0 + $1.paths.count },
                              ByteFormat.format(totalBytes))
                    : l10n.t("log.specialFail"))
                logFailure(result)
            }
            logFailure(runtime)
        }
    }

    func scanDeveloperTools() {
        guard authorize(.developerToolsScan, presentingPermissionCenter: true) else { return }
        scanSpecial(.tools, script: "bin/app_tool_scan.sh")
    }

    func scanAI() {
        guard authorize(.aiScan, presentingPermissionCenter: true) else { return }
        scanSpecial(.ai, script: "bin/app_ai_scan.sh", timeout: 600)
    }

    func scanXcode() {
        guard authorize(.xcodeScan, presentingPermissionCenter: true) else { return }
        scanSpecial(.xcode, script: "bin/app_xcode_scan.sh", timeout: 300)
    }

    func scanSlim() {
        guard authorize(.slimScan, presentingPermissionCenter: true) else { return }
        scanSpecial(.slim, script: "bin/app_slim_scan.sh")
    }

    func openSlimCleanup() {
        jump(to: .cleanup)
        scanSlim()
    }

    /// 系统数据页扫描：特权预览脚本输出分组 TSV，独立解析为本页清单。
    /// 每次扫描都会请求一次管理员授权；页面激活不会自动触发。
    func scanSystemData() {
        guard authorize(.systemScan, presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        systemScanning = true
        systemEntries = []
        statusText = l10n.t("status.systemScanning")
        log(l10n.t("log.systemScan"))
        Task {
            let result = await MoleEngine.shared.runPrivilegedBridge(
                "bin/app_system_preview.sh",
                arguments: [NSUserName(), NSHomeDirectory()])
            systemScanning = false
            systemScanComplete = result.succeeded
            systemEntries = result.succeeded
                ? Parsers.systemDataEntries(result.output)
                : []
            if systemEntries.isEmpty {
                statusText = l10n.t("status.systemEmpty")
                log(result.succeeded ? l10n.t("log.systemScanEmpty") : l10n.t("log.systemScanAbort"))
                logFailure(result)
            } else {
                statusText = l10n.t("status.systemDone")
                log(l10n.t("log.systemScanDone"))
            }
        }
    }

    func toggleSystemEntry(_ id: UUID) {
        guard !isBusy,
              let index = systemEntries.firstIndex(where: { $0.id == id }) else { return }
        systemEntries[index].selected.toggle()
    }

    /// 一键勾选全部 Safe 项并清掉 Review 项的勾选。
    func selectSafeSystemEntries() {
        guard !isBusy else { return }
        for index in systemEntries.indices {
            systemEntries[index].selected = systemEntries[index].risk == .safe
        }
    }

    func revealSystemEntry(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: path)])
    }

    /// 单行删除：同一特权执行管道，独立确认文案。
    func deleteSystemEntry(_ entry: SystemDataEntry) {
        guard !isBusy else { return }
        confirmation = Confirmation(
            title: l10n.t("confirm.systemSingle.title"),
            message: l10n.t("confirm.systemSingle.msg"),
            confirmLabel: l10n.t("confirm.systemSingle.ok")) { [weak self] in
                self?.performSystemCleanup(paths: [entry.path])
            }
    }

    /// 系统数据页的批量清理入口。
    func applySystemCleanup() {
        guard !isBusy, systemScanComplete else { return }
        let selected = systemEntries.filter(\.selected)
        guard !selected.isEmpty else {
            statusText = l10n.t("cleanup.selectNone")
            return
        }
        confirmation = Confirmation(
            title: l10n.tf("confirm.system.title", selected.count),
            message: l10n.t("confirm.system.msg"),
            confirmLabel: l10n.t("confirm.system.ok")) { [weak self] in
                guard let self else { return }
                self.performSystemCleanup(paths: selected.map(\.path))
            }
    }

    /// 特权执行：NUL 计划 + SHA-256 摘要，成功后按磁盘实况收敛清单，
    /// 不自动重扫（避免再次弹出管理员授权）。
    private func performSystemCleanup(paths: [String]) {
        var selectionData = Data()
        for path in paths {
            selectionData.append(contentsOf: path.utf8)
            selectionData.append(0)
            // The privileged route receives the same object identity that was
            // visible in the preview.  It must reject a replaced log file
            // instead of trusting the pathname.
            let identity = DeletionPlan.identity(at: path) ?? ""
            selectionData.append(contentsOf: identity.utf8)
            selectionData.append(0)
        }
        let selectionDigest = SHA256.hash(data: selectionData)
            .map { String(format: "%02x", $0) }
            .joined()
        let selectionURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sm-system-selection-\(UUID().uuidString).plan")
        do {
            try selectionData.write(to: selectionURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: selectionURL.path)
        } catch {
            try? FileManager.default.removeItem(at: selectionURL)
            statusText = l10n.t("status.systemPartial")
            log(l10n.t("log.systemApplyPartial"))
            log(error.localizedDescription)
            return
        }
        isApplying = true
        statusText = l10n.t("status.systemCleaning")
        log(l10n.t("log.systemApply"))
        Task {
            let result = await MoleEngine.shared.runPrivilegedBridge(
                "bin/app_system_apply.sh",
                arguments: [NSUserName(), NSHomeDirectory(), selectionURL.path,
                            selectionDigest])
            try? FileManager.default.removeItem(at: selectionURL)
            isApplying = false
            if !result.output.isEmpty { log(result.output) }
            logFailure(result, stdoutAlreadyLogged: true)
            let summary = Parsers.systemApplySummary(result.output)
            systemSessionReclaimed &+= summary.removedBytes
            // 只移除磁盘上确实消失的行；被身份/所有权/白名单复核拦下的行
            // 保留在清单里等用户重新审视。
            systemEntries = systemEntries.filter {
                FileManager.default.fileExists(atPath: $0.path)
            }
            statusText = result.succeeded
                ? l10n.t("status.systemApplyDone")
                : l10n.t("status.systemPartial")
            log(result.succeeded
                ? l10n.t("log.systemApplyDone")
                : l10n.t("log.systemApplyPartial"))
        }
    }

    // MARK: - 清理执行

    func applyCleanup() {
        guard !isBusy, cleanupScanComplete else {
            if !cleanupScanComplete { statusText = l10n.t("log.scanPartial") }
            return
        }
        let selectedSubsets = categories.compactMap(\.selectedSubset)
        let selectedCategories = family == .clean
            ? CleanupCategory.safeCleanupCandidates(from: selectedSubsets)
            : selectedSubsets
        guard !selectedCategories.isEmpty else {
            statusText = l10n.t("cleanup.selectNone")
            return
        }
        if family == .slim {
            slimRequest = { [weak self] mode in
                guard let self else { return }
                self.confirmApply(categories: selectedCategories, imageMode: mode)
            }
            return
        }
        confirmApply(categories: selectedCategories, imageMode: nil)
    }

    private func confirmApply(categories selectedCategories: [CleanupCategory],
                              imageMode: String?) {
        let applyFamily = family
        let selectedCount = selectedCategories.reduce(0) { $0 + $1.paths.count }
        let actionTitle: String
        var message: String
        switch applyFamily {
        case .clean:
            // 磁盘清理是永久删除：用独立的不可逆确认文案。
            actionTitle = l10n.t("confirm.cleanupPermanent.ok")
            message = l10n.t("confirm.cleanupPermanent.msg")
        case .tools:
            actionTitle = l10n.t("confirm.apply.tools.ok")
            message = l10n.t("confirm.apply.tools.msg")
        case .slim:
            let replacing = imageMode == "replace"
            actionTitle = replacing
                ? l10n.t("confirm.apply.slimReplace.ok")
                : l10n.t("confirm.apply.slimCopy.ok")
            message = replacing
                ? l10n.t("confirm.apply.slimReplace.msg")
                : l10n.t("confirm.apply.slimCopy.msg")
        case .ai:
            actionTitle = l10n.t("confirm.apply.trash.ok")
            message = l10n.t("confirm.apply.ai.msg")
        case .xcode:
            actionTitle = l10n.t("confirm.apply.trash.ok")
            message = l10n.t("confirm.xcode.msg")
        default:
            actionTitle = l10n.t("confirm.apply.trash.ok")
            message = l10n.t("confirm.apply.trash.msg")
        }
        let warningCount = selectedCategories
            .filter { $0.risk == .warning }
            .reduce(0) { $0 + $1.paths.count }
        if warningCount > 0 {
            message += "\n\n" + l10n.tf("cleanup.warningConfirmation", warningCount)
        }
        confirmation = Confirmation(
            title: applyFamily == .clean
                ? l10n.tf("confirm.cleanupPermanent.title", selectedCount)
                : l10n.tf("confirm.apply.title", selectedCount),
            message: message,
            confirmLabel: actionTitle) { [weak self] in
                self?.performApply(categories: selectedCategories, imageMode: imageMode,
                                   family: applyFamily, mode: .manual)
            }
    }

    /// 执行阶段再次读取进程表，并按每个类别自己的 route 分流。扫描来源不会再
    /// 因为 UI 合并展示而退化成通用删除入口。
    private func performApply(categories requested: [CleanupCategory],
                              imageMode: String?, family applyFamily: CleanupFamily,
                              mode: CleanupExecutionMode) {
        let requestedCount = requested.reduce(0) { $0 + $1.paths.count }
        isApplying = true
        statusText = l10n.tf("status.processing", requestedCount)
        Task {
            let snapshot = await captureRunningApplicationSnapshot()
            var eligible: [CleanupCategory] = []
            for category in requested {
                let assessment = CleanupRiskPolicy.reassess(category, running: snapshot)
                let runtimeSubset = CleanupRiskPolicy.runtimeEligibleSubset(
                    category, running: snapshot)
                if let runtimeSubset,
                   CleanupRiskPolicy.isEligible(runtimeSubset, mode: mode, running: snapshot) {
                    eligible.append(runtimeSubset)
                } else if assessment.risk == .protected,
                          let index = categories.firstIndex(where: { $0.id == category.id }) {
                    categories[index].risk = .protected
                    categories[index].reasonKey = assessment.reasonKey
                    categories[index].selected = false
                }
            }

            let eligibleCount = eligible.reduce(0) { $0 + $1.paths.count }
            var executionResult = CleanupExecutionResult(
                skipped: max(0, requestedCount - eligibleCount))
            // The immutable eligible plan, rather than the still-visible UI
            // selection, is the number this execution will actually submit.
            statusText = l10n.tf("status.processing", eligibleCount)
            guard !eligible.isEmpty else {
                isApplying = false
                reportCleanupResult(executionResult)
                return
            }

            let grouped = Dictionary(grouping: eligible, by: \.applyRoute)
            for route in CleanupApplyRoute.allCases {
                guard let routeCategories = grouped[route], !routeCategories.isEmpty else { continue }
                let routeResult = await executeCleanupRoute(
                    route, categories: routeCategories, imageMode: imageMode, mode: mode,
                    permanently: applyFamily == .clean)
                executionResult.merge(routeResult)
            }

            isApplying = false
            reportCleanupResult(executionResult)
            CleanupCache.invalidate()
            switch applyFamily {
            case .clean:
                // A successful deletion plan already knows exactly which paths
                // disappeared. Do not make the user wait for every optional
                // inventory a second time after every cleanup.
                if executionResult.failed == 0,
                   executionResult.removed == eligibleCount {
                    let removedPaths = Set(eligible.flatMap(\.paths))
                    categories = categories.compactMap { category in
                        category.retainingPaths(
                            category.paths.filter { !removedPaths.contains($0) })
                    }.sorted(by: CleanupCategory.sizeDescending)
                    cleanupScanComplete = true
                } else {
                    cleanupScanComplete = false
                }
            case .slim: scanSlim()
            case .tools: scanDeveloperTools()
            case .ai: scanAI()
            case .xcode: scanXcode()
            default: break
            }
        }
    }

    private func reportCleanupResult(_ result: CleanupExecutionResult) {
        let summary = l10n.tf(
            "cleanup.execution.summary", result.removed, result.skipped, result.failed)
        statusText = summary
        log(summary)
    }

    private func executeCleanupRoute(_ route: CleanupApplyRoute,
                                     categories routeCategories: [CleanupCategory],
                                     imageMode: String?,
                                     mode: CleanupExecutionMode,
                                     permanently: Bool = false) async
        -> CleanupExecutionResult {
        let rawRecords = routeCategories.flatMap(\.paths)
        let records: [String]
        switch route {
        case .genericTrash, .installerTrash, .projectArtifactTrash,
             .developerCacheTrash, .aiTrash, .xcodeTrash:
            records = DeletionPlan.nonOverlappingPaths(rawRecords)
        default:
            records = rawRecords
        }
        let coalescedCount = max(0, rawRecords.count - records.count)
        guard !records.isEmpty, let bridgeName = bridgeName(for: route) else {
            return CleanupExecutionResult(
                skipped: coalescedCount,
                failed: records.count)
        }

        // Core cleanup routes are implemented by NativeCore. Specialized
        // command routes (owner GC, image transforms, and privileged system
        // operations) continue through their dedicated bridges.
        switch route {
        case .genericTrash, .developerCacheTrash, .aiTrash, .xcodeTrash:
            let items = routeCategories.flatMap { category in
                category.paths.compactMap { path -> DeletionPlan.Item? in
                    guard let identity = category.pathIdentities[path], !identity.isEmpty else { return nil }
                    return DeletionPlan.Item(record: path, identity: identity)
                }
            }
            let summary = await Task.detached(priority: .utility) {
                NativeCore.shared.applyCleanup(items: items, permanent: permanently)
            }.value
            if !summary.messages.isEmpty { log(summary.messages.joined(separator: "\n")) }
            let missing = records.count - items.count
            return CleanupExecutionResult(
                removed: summary.removed,
                skipped: summary.skipped + coalescedCount + max(0, missing),
                failed: summary.failed)
        default:
            break
        }

        let stdinData: Data
        switch route {
        case .toolCommand:
            var data = Data()
            for record in records {
                data.append(contentsOf: record.utf8)
                data.append(0)
            }
            stdinData = data
        case .imageTransform:
            stdinData = DeletionPlan(records: records) { record in
                guard let separator = record.firstIndex(of: "|") else { return nil }
                let path = String(record[record.index(after: separator)...])
                return path.hasPrefix("/") ? path : nil
            }.stdinData
        case .genericTrash, .installerTrash, .projectArtifactTrash,
             .developerCacheTrash, .aiTrash, .xcodeTrash:
            let items = routeCategories.flatMap { category in
                category.paths.compactMap { path -> DeletionPlan.Item? in
                    guard let identity = category.pathIdentities[path] else { return nil }
                    return DeletionPlan.Item(record: path, identity: identity)
                }
            }
            stdinData = DeletionPlan(items: items).stdinData
        case .systemPrivileged, .none:
            return CleanupExecutionResult(
                skipped: coalescedCount,
                failed: records.count)
        }

        log(l10n.tf("log.pipeline", records.count,
                    (bridgeName as NSString).lastPathComponent))
        var environment: [String: String] = ["SIMPLEMOLE_EXECUTION_MODE": {
            switch mode {
            case .manual: return "manual"
            case .quickClean: return "quickClean"
            case .automatic: return "automatic"
            }
        }()]
        environment.merge(fullDiskScanEnvironment) { _, authorized in authorized }
        switch route {
        case .genericTrash, .installerTrash, .projectArtifactTrash,
             .developerCacheTrash, .aiTrash, .xcodeTrash:
            if permanently { environment["SIMPLEMOLE_DELETE_MODE"] = "permanent" }
        default:
            break
        }
        if route == .imageTransform { environment["MOLE_IMAGE_MODE"] = imageMode ?? "copy" }
        let result = await MoleEngine.shared.runBridgeWithStdin(
            bridgeName, stdinData: stdinData, extraEnvironment: environment, timeout: 900)
        if !result.output.isEmpty { log(result.output) }
        logFailure(result, stdoutAlreadyLogged: true)
        var summary = CleanupExecutionResult.reconciled(
            bridgeOutput: result.output, expectedCount: records.count)
        summary.skipped += coalescedCount
        return summary
    }

    private func bridgeName(for route: CleanupApplyRoute) -> String? {
        switch route {
        case .genericTrash: return "bin/app_apply.sh"
        case .installerTrash: return "bin/app_installer_apply.sh"
        case .projectArtifactTrash: return "bin/app_purge_apply.sh"
        case .developerCacheTrash: return "bin/app_dev_apply.sh"
        case .aiTrash: return "bin/app_ai_apply.sh"
        case .xcodeTrash: return "bin/app_xcode_apply.sh"
        case .toolCommand: return "bin/app_tool_apply.sh"
        case .imageTransform: return "bin/app_slim_apply.sh"
        case .systemPrivileged, .none: return nil
        }
    }

    // MARK: - 进程与端口

    func refreshRuntimeIfNeeded() {
        guard mainWindowVisible, !runtimeInFlight, !isBusy else { return }
        guard visiblePages.indices.contains(selectedTab) else { return }
        if visiblePages[selectedTab] == .processes { refreshProcesses() }
        else if visiblePages[selectedTab] == .ports { refreshPorts() }
    }

    func refreshProcesses(allowAutomaticCleanup: Bool = true) {
        guard !runtimeInFlight else { return }
        let requestedAdvancedMode = advancedProcesses
        runtimeInFlight = true
        if processRows.isEmpty { processStatus = l10n.t("proc.status.reading") }
        Task {
            let result = await MoleEngine.shared.runRuntime("processes")
            guard requestedAdvancedMode == advancedProcesses else {
                runtimeInFlight = false
                refreshProcesses()
                return
            }
            guard result.succeeded else {
                if requestedAdvancedMode {
                    automaticProcessTracker.breakSequence()
                }
                runtimeInFlight = false
                processStatus = l10n.t("proc.status.readFailed")
                logFailure(result)
                return
            }
            if requestedAdvancedMode {
                let rows = RuntimeStore.rows(fromProcessText: result.output, advanced: true)
                processRows = rows
                // 验证重扫也必须更新 tracker，确保恢复正常或已消失的进程
                // 及时打断旧计数；只禁止这一拍继续执行自动动作。
                let candidates = automaticProcessTracker.candidates(in: rows)
                let selection = allowAutomaticCleanup
                    ? automaticCleanupSelection(fromCandidates: candidates)
                    : (actions: [], attemptedRows: [])
                if !selection.actions.isEmpty {
                    processStatus = l10n.tf("proc.status.autoProcessing", selection.actions.count)
                    await runAutomaticProcessCleanup(selection.actions)
                    return
                }
                runtimeInFlight = false
                updateAdvancedProcessStatus(for: rows)
            } else {
                resetAutomaticProcessCleanup()
                let native = RuntimeStore.nativeRows(fromProcessText: result.output)
                processRows = native.rows
                processStatus = l10n.tf("proc.status.apps", native.total)
                runtimeInFlight = false
            }
        }
    }

    /// 连续采样达到阈值后才自动处理。每轮最多执行四个动作；多个 zombie
    /// 共用同一 UID + PPID 时只通知父进程一次，但会一起标记为已尝试。
    private func automaticCleanupSelection(fromCandidates candidates: [ProcessRow])
        -> (actions: [ProcessRow], attemptedRows: [ProcessRow]) {
        guard !candidates.isEmpty else { return ([], []) }

        var actions: [ProcessRow] = []
        var attemptedRows: [ProcessRow] = []
        var selectedZombieParents: Set<String> = []

        for row in candidates {
            if row.lifecycle == .zombie {
                let parentKey = "\(row.uid):\(row.ppid)"
                if selectedZombieParents.contains(parentKey) {
                    attemptedRows.append(row)
                    continue
                }
                guard actions.count < 4 else { continue }
                selectedZombieParents.insert(parentKey)
                actions.append(row)
                attemptedRows.append(row)
            } else {
                guard actions.count < 4 else { continue }
                actions.append(row)
                attemptedRows.append(row)
            }
        }

        automaticProcessTracker.markAttempted(attemptedRows)
        automaticProcessCleanupTokens.formUnion(attemptedRows.map(\.staleCleanupToken))
        return (actions, attemptedRows)
    }

    private func runAutomaticProcessCleanup(_ rows: [ProcessRow]) async {
        var attempted = 0
        var succeeded = 0
        for row in rows {
            guard advancedProcesses else { break }
            attempted += 1
            let result = await MoleEngine.shared.runRuntime("cleanup-stale", row.staleCleanupToken)
            if result.succeeded {
                succeeded += 1
            } else {
                logFailure(result)
            }
        }

        automaticProcessCleanupAttempted += attempted
        automaticProcessCleanupSucceeded += succeeded
        runtimeInFlight = false
        guard advancedProcesses else {
            resetAutomaticProcessCleanup()
            return
        }
        // 以重扫结果作为最终状态，避免把已变化或未回收的进程误报为成功。
        // 验证重扫不继续取下一批，单轮最多自动处理四个；其余候选交给下次定时刷新。
        refreshProcesses(allowAutomaticCleanup: false)
    }

    private func updateAdvancedProcessStatus(for rows: [ProcessRow]) {
        let abnormalRows = rows.filter { $0.lifecycle != .normal }
        let abnormalCount = abnormalRows.count
        automaticProcessCleanupTokens.formIntersection(abnormalRows.map(\.staleCleanupToken))
        if automaticProcessCleanupAttempted > 0 {
            let succeeded = automaticProcessCleanupSucceeded
            automaticProcessCleanupAttempted = 0
            automaticProcessCleanupSucceeded = 0
            if abnormalCount == 0, succeeded > 0 {
                processStatus = l10n.tf("proc.status.autoCleaned", succeeded)
            } else if abnormalCount == 0 {
                // 处理失败后目标可能自行退出；此时不把自然消失误报成清理成功。
                processStatus = rows.isEmpty
                    ? l10n.t("proc.status.none")
                    : l10n.tf("proc.status.pids", rows.count)
            } else {
                processStatus = l10n.tf("proc.status.abnormalRemaining", abnormalCount)
            }
        } else if !automaticProcessCleanupTokens.isEmpty {
            processStatus = l10n.tf("proc.status.abnormalRemaining", abnormalCount)
        } else if abnormalCount > 0 {
            processStatus = l10n.tf("proc.status.abnormalDetected", abnormalCount)
        } else {
            processStatus = rows.isEmpty
                ? l10n.t("proc.status.none")
                : l10n.tf("proc.status.pids", rows.count)
        }
    }

    private func resetAutomaticProcessCleanup() {
        automaticProcessTracker = RuntimeStore.AutomaticCandidateTracker()
        automaticProcessCleanupAttempted = 0
        automaticProcessCleanupSucceeded = 0
        automaticProcessCleanupTokens.removeAll()
    }

    func refreshPorts() {
        guard !runtimeInFlight else { return }
        runtimeInFlight = true
        portStatus = l10n.t("ports.status.reading")
        Task {
            let result = await MoleEngine.shared.runRuntime("ports")
            runtimeInFlight = false
            portRows = RuntimeStore.portRows(fromText: result.output)
            portStatus = portRows.isEmpty
                ? l10n.t("ports.status.none")
                : l10n.tf("ports.status.count", portRows.count)
        }
    }

    func terminateProcess(_ row: ProcessRow) {
        if row.isNativeApp {
            confirmation = Confirmation(
                title: l10n.tf("proc.confirm.quit.title", row.name),
                message: l10n.t("proc.confirm.quit.msg"),
                confirmLabel: l10n.t("common.quit")) {
                    let application = NSRunningApplication(processIdentifier: row.pid)
                    let identityMatches = application.flatMap(RuntimeStore.nativeStartIdentity(for:))
                        == row.startIdentity
                    let requested = identityMatches && !(application?.isTerminated ?? true)
                        ? (application?.terminate() ?? false)
                        : false
                    Task { @MainActor in
                        self.processStatus = requested
                            ? self.l10n.t("status.quitRequested")
                            : self.l10n.t("status.quitRefused")
                    }
                }
            return
        }
        if row.lifecycle != .normal {
            confirmation = Confirmation(
                title: l10n.t("proc.confirm.cleanupStale.title"),
                message: l10n.t("proc.confirm.cleanupStale.msg"),
                confirmLabel: l10n.t("proc.cleanupStale")) { [weak self] in
                    self?.cleanupStaleProcess(row)
                }
            return
        }
        let mode = advancedProcesses ? "kill-pid" : "kill-group"
        let title = advancedProcesses
            ? l10n.t("proc.confirm.killPid.title")
            : l10n.t("proc.confirm.killGroup.title")
        confirmation = Confirmation(
            title: title,
            message: l10n.tf("proc.confirm.kill.msg", row.pid),
            confirmLabel: l10n.t("proc.kill")) { [weak self] in
                guard let self else { return }
                guard !self.runtimeInFlight else { return }
                self.runtimeInFlight = true
                Task {
                    let result = await MoleEngine.shared.runRuntime(mode, row.signalToken)
                    self.processStatus = result.succeeded
                        ? self.l10n.t("status.signalSent")
                        : self.l10n.t("status.signalFailed")
                    self.runtimeInFlight = false
                    self.refreshProcesses(allowAutomaticCleanup: false)
                }
            }
    }

    private func cleanupStaleProcess(_ row: ProcessRow) {
        guard advancedProcesses, !runtimeInFlight, row.lifecycle != .normal else { return }
        let coveredRows: [ProcessRow]
        if row.lifecycle == .zombie {
            coveredRows = processRows.filter {
                $0.lifecycle == .zombie && $0.uid == row.uid && $0.ppid == row.ppid
            }
        } else {
            coveredRows = [row]
        }
        automaticProcessTracker.markAttempted(coveredRows)
        automaticProcessCleanupTokens.formUnion(coveredRows.map(\.staleCleanupToken))
        runtimeInFlight = true
        processStatus = l10n.tf("proc.status.autoProcessing", 1)
        Task {
            let result = await MoleEngine.shared.runRuntime("cleanup-stale", row.staleCleanupToken)
            automaticProcessCleanupAttempted += 1
            if result.succeeded {
                automaticProcessCleanupSucceeded += 1
            } else {
                logFailure(result)
            }
            runtimeInFlight = false
            guard advancedProcesses else {
                resetAutomaticProcessCleanup()
                return
            }
            refreshProcesses(allowAutomaticCleanup: false)
        }
    }

    func closePort(_ row: PortRow) {
        confirmation = Confirmation(
            title: l10n.tf("ports.confirm.title", row.pid),
            message: l10n.tf("ports.confirm.msg", row.port, row.command),
            confirmLabel: l10n.t("ports.close")) { [weak self] in
                guard let self else { return }
                Task {
                    let result = await MoleEngine.shared.runRuntime("kill-pid", row.signalToken)
                    self.portStatus = result.succeeded
                        ? self.l10n.t("status.signalSent")
                        : self.l10n.t("status.signalFailed")
                    self.refreshPorts()
                }
            }
    }

    // MARK: - 图片

    func scanImages() {
        guard authorize(.imageScan, presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        isScanningImages = true
        imageStatus = l10n.t("img.status.scanning")
        Task {
            let result = await MoleEngine.shared.runBridge(
                "bin/app_image_scan.sh", arguments: [NSHomeDirectory(), "500"],
                extraEnvironment: scanEnvironment, timeout: 120)
            isScanningImages = false
            let items = Parsers.imageItems(result.output)
            imageTotal = items.count
            images = Array(items.prefix(90))
            imageStatus = items.isEmpty
                ? l10n.t("img.status.none")
                : (items.count > images.count
                    ? l10n.tf("img.status.capped", items.count, images.count)
                    : l10n.tf("img.status.found", items.count))
            logFailure(result)
        }
    }

    func revealImage(_ item: ImageItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    // MARK: - 应用卸载

    func uninstallPlan(for app: UninstallApp) -> UninstallPlan? {
        uninstallPlans[app.id]
    }

    private func persistUninstallInventory() {
        let records = installedApps.compactMap { app -> UninstallInventoryRecord? in
            guard let plan = uninstallPlans[app.id] else { return nil }
            return .init(app: app, plan: plan)
        }
        UninstallInventoryCache.saveInBackground(records)
    }

    private nonisolated static func fetchUninstallPlan(for app: UninstallApp) async
        -> (String, UninstallPlan?) {
        let plan = await NativeCore.shared.uninstallPlan(
            for: app, homeDirectory: NSHomeDirectory())
        return (app.id, plan)
    }

    func scanInstalledApps(background: Bool = false) {
        guard authorize(.installedAppsScan,
                        presentingPermissionCenter: !background) else { return }
        guard !isScanningApps, !uninstallQueue.hasWork else { return }
        guard permissionCenter.refresh() else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        let generation = uninstallInventoryGeneration
        isScanningApps = true
        if !background || installedApps.isEmpty {
            appListStatus = l10n.t("uninstall.status.scanning")
        }
        Task {
            let apps = await NativeCore.shared.scanInstalledApps(
                homeDirectory: NSHomeDirectory())
            guard generation == uninstallInventoryGeneration else {
                isScanningApps = false
                scheduleUninstallInventoryRefresh(after: 0.5)
                return
            }
            guard generation == uninstallInventoryGeneration else {
                isScanningApps = false
                scheduleUninstallInventoryRefresh(after: 0.5)
                return
            }
            let previousApps = Dictionary(uniqueKeysWithValues: installedApps.map { ($0.id, $0) })
            let currentApps = Dictionary(apps.map { ($0.id, $0) },
                                         uniquingKeysWith: { _, latest in latest })
            uninstallPlans = uninstallPlans.filter { id, plan in
                guard let previous = previousApps[id],
                      let current = currentApps[id] else { return false }
                return previous.appIdentity == current.appIdentity
                    && previous.infoIdentity == current.infoIdentity
                    && plan.includesProtectedAppData
                    && !plan.fileIdentities.isEmpty
            }
            installedApps = apps
            appListStatus = installedApps.isEmpty
                ? l10n.t("uninstall.status.empty")
                : l10n.tf("uninstall.status.count", installedApps.count)
            persistUninstallInventory()

            let missing = apps.filter { uninstallPlans[$0.id] == nil }
            let batchSize = 4
            for start in stride(from: 0, to: missing.count, by: batchSize) {
                guard generation == uninstallInventoryGeneration else { break }
                let end = min(start + batchSize, missing.count)
                let batch = Array(missing[start..<end])
                let plans = await withTaskGroup(
                    of: (String, UninstallPlan?).self,
                    returning: [(String, UninstallPlan?)].self
                ) { group in
                    for app in batch {
                        group.addTask {
                            await Self.fetchUninstallPlan(
                                for: app)
                        }
                    }
                    var output: [(String, UninstallPlan?)] = []
                    for await plan in group { output.append(plan) }
                    return output
                }
                guard generation == uninstallInventoryGeneration else { break }
                var updatedPlans = uninstallPlans
                for (id, plan) in plans {
                    if let plan { updatedPlans[id] = plan }
                }
                uninstallPlans = updatedPlans
                persistUninstallInventory()
            }
            isScanningApps = false
        }
    }

    func previewUninstall(_ app: UninstallApp) {
        guard !uninstallQueue.containsPendingOrActive(app) else { return }
        guard authorize(.uninstall(app: app), presentingPermissionCenter: true) else { return }
        guard !app.appIdentity.isEmpty else {
            log(l10n.tf("log.uninstallPreviewFail", app.name))
            return
        }
        // Capture a plan only if it belongs to this exact inventory identity.
        // A missing preview is prepared by the FIFO worker after confirmation.
        let cached = installedApps.first(where: { $0.id == app.id }) == app
            ? uninstallPlans[app.id] : nil
        let plan = cached.flatMap {
            $0.includesProtectedAppData && !$0.fileIdentities.isEmpty ? $0 : nil
        }
        // The row's destructive action is already explicit. Do not insert an
        // application-level confirmation between the click and queue entry;
        // the queue keeps the request's identity snapshot and NativeCore
        // performs the final identity and path checks before any side effect.
        guard uninstallQueue.enqueue(app: app, plan: plan) != nil else { return }
        startNextUninstallIfPossible()
    }

    func uninstallJob(for app: UninstallApp) -> UninstallJob? {
        uninstallQueue.jobs.last { $0.app.id == app.id }
    }

    func uninstallQueuePosition(for app: UninstallApp) -> Int? {
        uninstallQueue.jobs.filter { $0.state.isPending }
            .firstIndex { $0.app.id == app.id }.map { $0 + 1 }
    }

    func cancelQueuedUninstall(id: UUID) {
        guard uninstallQueue.cancel(id) else { return }
        startNextUninstallIfPossible()
        if !uninstallQueue.hasWork { scheduleUninstallInventoryRefresh(after: 1) }
    }

    func dismissFinishedUninstalls() { uninstallQueue.dismissFinished() }

    func stopUninstallQueueForTermination() {
        isStoppingUninstallQueue = true
        uninstallInventoryRefreshWorkItem?.cancel()
        for job in uninstallQueue.jobs where job.state.isPending {
            uninstallQueue.cancel(job.id)
        }
    }

    private func startNextUninstallIfPossible() {
        // Preserve mutual exclusion at the disk mutation edge while allowing
        // more confirmed requests to join the queue from any visible row.
        let blocked = isBusyExcludingUninstall || confirmation != nil || isDispatchingConfirmation
        // A no-op mutating access to an @Published value still publishes. Keep
        // these read-only guards outside startNext to avoid a wake-up loop.
        guard !isStoppingUninstallQueue, !blocked,
              uninstallQueue.activeJob == nil, uninstallQueue.hasPendingJobs else { return }
        guard let job = uninstallQueue.startNext(blocked: blocked) else { return }
        // Drop any in-flight read-only inventory result that predates this job.
        uninstallInventoryGeneration += 1
        Task {
            await executeUninstall(job)
            startNextUninstallIfPossible()
            if !uninstallQueue.hasWork { scheduleUninstallInventoryRefresh(after: 1) }
        }
    }

    private func executeUninstall(_ job: UninstallJob) async {
        let target = job.app
        // Queued requests may outlive an authorization change. Do not prompt
        // or retry with broader access from the background worker.
        guard permissionCenter.refresh() else {
            finishUninstall(job, succeeded: false, message: l10n.t("uninstall.queue.permissionLost"))
            return
        }
        var plan = job.plan
        if plan == nil || plan?.fileIdentities.isEmpty == true {
            log(l10n.tf("log.uninstallScan", target.name))
            let (_, fetched) = await Self.fetchUninstallPlan(for: target)
            plan = fetched
        }
        guard let plan, !plan.files.isEmpty, plan.includesProtectedAppData else {
            finishUninstall(job, succeeded: false, message: l10n.tf("log.uninstallPreviewFail", target.name))
            return
        }
        uninstallQueue.markRunning(job.id)
        statusText = l10n.tf("status.uninstalling", target.name)
        log(l10n.tf("log.uninstallApply", target.name))
        let result = await Task.detached(priority: .utility) {
            NativeCore.shared.applyUninstall(target, plan: plan,
                                             homeDirectory: NSHomeDirectory())
        }.value
        if !result.messages.isEmpty { log(result.messages.joined(separator: "\n")) }
        uninstallInventoryGeneration += 1
        if result.succeeded {
            installedApps.removeAll { $0.id == target.id && $0.appIdentity == target.appIdentity }
            uninstallPlans.removeValue(forKey: target.id)
            persistUninstallInventory()
            appListStatus = l10n.tf("uninstall.status.count", installedApps.count)
            finishUninstall(job, succeeded: true, message: l10n.tf("status.uninstalled", target.name))
        } else {
            // A partial uninstall can change the identity. A retry must pass
            // through a fresh user confirmation after inventory refresh.
            uninstallPlans.removeValue(forKey: target.id)
            persistUninstallInventory()
            let detail = l10n.tf("log.uninstallPartial", result.removed, result.failed)
            finishUninstall(job, succeeded: false,
                            message: l10n.tf("status.uninstallPartial", target.name) + "\n" + detail)
        }
    }

    private func finishUninstall(_ job: UninstallJob, succeeded: Bool, message: String) {
        uninstallQueue.finish(job.id, succeeded: succeeded, message: message)
        statusText = message
        log(message)
    }

    /// Watches the roots where app installs and uninstalls become visible.
    /// Directory events are coalesced because Finder/Homebrew may emit several
    /// writes for one operation.
    private func startUninstallInventoryMonitoring(includeProtectedPaths: Bool) {
        var paths = [
            "/Applications",
            NSHomeDirectory().appending("/Applications")
        ]
        if includeProtectedPaths {
            paths.append(NSHomeDirectory().appending("/.Trash"))
        }
        for path in paths where !uninstallInventoryWatchedPaths.contains(path)
            && FileManager.default.fileExists(atPath: path) {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename, .extend, .attrib],
                queue: DispatchQueue.global(qos: .utility))
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in
                    self?.scheduleUninstallInventoryRefresh(after: 1.0)
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            uninstallInventoryWatchers.append(source)
            uninstallInventoryWatchedPaths.insert(path)
        }
    }

    /// Services that enumerate persisted user locations or ~/.Trash are
    /// activated only after the one-time Full Disk Access check succeeds.
    private func activateProtectedDiskServices() {
        guard permissionCenter.fullDiskAccessGranted else { return }
        startUninstallInventoryMonitoring(includeProtectedPaths: true)
        _ = savedScanLocations.refreshAvailability(persist: false)
        projectHibernation.receiptStore.refreshAvailability()
    }

    private func scheduleUninstallInventoryRefresh(after delay: TimeInterval) {
        guard !isStoppingUninstallQueue else { return }
        uninstallInventoryRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.isScanningApps || self.uninstallQueue.hasWork {
                    self.scheduleUninstallInventoryRefresh(after: 1.0)
                } else {
                    self.scanInstalledApps(background: true)
                }
            }
        }
        uninstallInventoryRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - 开发环境

    func scanDevEnv() {
        guard authorize(.developmentEnvironmentScan,
                        presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        isScanningEnv = true
        devEnvStatus = l10n.t("devenv.status.scanning")
        Task {
            let result = await MoleEngine.shared.runBridge(
                "bin/app_env_scan.sh", extraEnvironment: scanEnvironment,
                timeout: 180)
            isScanningEnv = false
            devEnvEntries = Parsers.devEnvEntries(result.output)
            devEnvSelection.removeAll()
            let runtimeCount = devEnvEntries.filter { !$0.isManager }.count
            let managerCount = devEnvEntries.filter(\.isManager).count
            devEnvStatus = devEnvEntries.isEmpty
                ? l10n.t("devenv.status.none")
                : l10n.tf("devenv.status.summary", runtimeCount, managerCount)
            logFailure(result)
        }
    }

    func applyDevEnvCleanup() {
        guard !isBusy else { return }
        let paths = devEnvEntries.filter { devEnvSelection.contains($0.path) }.map(\.path)
        guard !paths.isEmpty else {
            devEnvStatus = l10n.t("devenv.selectFirst")
            return
        }
        let bytes = devEnvSelectedBytes
        let globalPackageBytes = devEnvSelectedGlobalPackageBytes
        let deletionPlan = DeletionPlan(paths: paths)
        confirmation = Confirmation(
            title: l10n.tf("confirm.env.title", paths.count),
            message: globalPackageBytes > 0
                ? l10n.tf("confirm.env.msg.node", paths.count, ByteFormat.format(bytes),
                           ByteFormat.format(globalPackageBytes))
                : l10n.tf("confirm.env.msg", paths.count, ByteFormat.format(bytes)),
            confirmLabel: l10n.t("confirm.apply.trash.ok")) { [weak self] in
                guard let self else { return }
                self.isApplying = true
                self.statusText = self.l10n.t("status.envCleaning")
                self.log(self.l10n.tf("log.envClean", paths.count))
                Task {
                    let result = await MoleEngine.shared.runBridgeWithStdin(
                        "bin/app_apply.sh", stdinData: deletionPlan.stdinData, timeout: 900)
                    self.isApplying = false
                    if !result.output.isEmpty { self.log(result.output) }
                    self.logFailure(result, stdoutAlreadyLogged: true)
                    let summary = Parsers.applySummary(result.output)
                    let fullySucceeded = result.succeeded && summary.failed == 0
                    self.statusText = fullySucceeded
                        ? self.l10n.tf("status.envDone", summary.removed)
                        : self.l10n.tf("status.envPartial", summary.failed)
                    self.log(fullySucceeded
                        ? self.l10n.tf("log.envDone", summary.removed)
                        : self.l10n.tf("log.envPartial", summary.removed, summary.failed))
                    self.scanDevEnv()
                    // 环境删除可能让 PATH 条目/初始化块失效：重跑体检引导用户处理。
                    self.runConfigAudits(force: true)
                    self.log(self.l10n.t("log.envRcHint"))
                }
            }
    }

    // MARK: - 包管理 GC（owner 命令）

    /// 列出本机可用的官方 GC 命令（只读扫描，每次会话最多一次）。
    func scanGc() {
        if gcScanned || gcRunningId != nil { return }
        gcScanned = true
        Task {
            let result = await MoleEngine.shared.runBridge("bin/app_gc_scan.sh", timeout: 60)
            gcActions = result.output.components(separatedBy: "\n").compactMap { line in
                let parts = line.components(separatedBy: "\t")
                guard parts.count >= 2, !parts[0].isEmpty else { return nil }
                return GcAction(id: parts[0], command: parts[1],
                                bytes: parts.count > 2 ? UInt64(parts[2]) ?? 0 : 0)
            }
        }
    }

    /// 运行一个白名单内的官方 GC 命令，输出逐行流入日志抽屉。
    func runGc(_ action: GcAction) {
        guard !isBusy else { return }
        confirmation = Confirmation(
            title: l10n.tf("gc.confirm.title", action.id),
            message: l10n.tf("gc.confirm.msg", action.command),
            confirmLabel: l10n.t("gc.run")) { [weak self] in
                guard let self else { return }
                self.gcRunningId = action.id
                self.statusText = self.l10n.tf("log.gcRun", action.command)
                self.log(self.l10n.tf("log.gcRun", action.command))
                Task {
                    let result = await MoleEngine.shared.runBridge(
                        "bin/app_gc_run.sh", arguments: [action.id],
                        timeout: 1200, onLine: self.streamLog)
                    self.gcRunningId = nil
                    self.statusText = result.succeeded
                        ? self.l10n.t("gc.finished")
                        : self.l10n.t("gc.failed")
                    self.log(result.succeeded
                        ? self.l10n.t("gc.finished")
                        : self.l10n.t("gc.failed"))
                    self.gcScanned = false
                    self.scanGc()
                }
            }
    }

    // MARK: - 磁盘分析

    func addSavedScanLocation() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = l10n.t("savedLocation.pick")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let location = try savedScanLocations.add(path: url.path)
            analyzePath = location.path
            analyzeStatus = l10n.tf("savedLocation.added", location.displayName)
        } catch {
            analyzeStatus = error.localizedDescription
            log(error.localizedDescription)
        }
    }

    func openProjectRadar() {
        guard authorize(.openProjectRadar, presentingPermissionCenter: true) else { return }
        guard permissionCenter.fullDiskAccessGranted else { return }
        savedScanLocations.refreshAvailability()
        showProjectRadar = true
        if !isBusy {
            projectRadar.scan(
                locations: savedScanLocations.locations,
                fullDiskAccessGranted: permissionCenter.fullDiskAccessGranted)
        }
    }

    func openAutomationSettings() {
        guard authorize(.openAutomationSettings, presentingPermissionCenter: true) else { return }
        guard permissionCenter.fullDiskAccessGranted else { return }
        savedScanLocations.refreshAvailability()
        showAutomationSettings = true
        if !isBusy {
            projectRadar.scan(
                locations: savedScanLocations.locations,
                fullDiskAccessGranted: permissionCenter.fullDiskAccessGranted)
        }
    }

    func restoreHibernatedProject(_ receipt: ProjectHibernationReceipt) {
        guard authorize(.restoreProject(receipt: receipt),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, !projectHibernation.isWorking else { return }
        let granted = permissionCenter.fullDiskAccessGranted
        guard granted else { return }
        Task {
            _ = await projectHibernation.restore(
                receipt, fullDiskAccessGranted: granted)
            projectRadar.scan(
                locations: savedScanLocations.locations,
                fullDiskAccessGranted: granted)
        }
    }

    /// 原生概览会并发分析 Home、用户 Library、Applications 与系统 Library。
    /// 客户端再按可操作性排序，系统与应用结果始终靠后。
    func scanDiskOverview(force: Bool = false) {
        guard authorize(.diskOverview(force: force),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        if !force, analyzeIsOverview, !analyzeEntries.isEmpty { return }
        startAnalyze(displayPath: "/", overview: true)
    }

    /// 分析指定目录（nil = 当前 analyzePath）。引擎并发扫描 + 大小排序。
    func scanAnalyze(_ path: String? = nil) {
        guard authorize(.diskAnalyze(path: path),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        if path == nil, analyzeIsOverview {
            scanDiskOverview(force: true)
            return
        }
        if let path { analyzePath = path }
        let target = analyzePath
        startAnalyze(displayPath: target, overview: false)
    }

    private func startAnalyze(displayPath: String, overview: Bool) {
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        analyzePath = displayPath
        analyzeIsOverview = overview
        isAnalyzing = true
        analyzeSelection.removeAll()
        analyzeAISelection.removeAll()
        if !overview { analyzeAIItems = [] }
        dupGroups = []
        dupSelection.removeAll()
        analyzeStatus = l10n.t("analyze.scanning")
        log(l10n.tf("log.analyzeScan", overview ? l10n.t("analyze.scope.full") : displayPath))
        Task {
            let analysisResult = await NativeCore.shared.scanAnalyze(
                path: displayPath, overview: overview)
            async let aiInventoryResult = scanAnalyzeAIInventory(
                enabled: overview, environment: scanEnvironment)
            let inventoryResult = await aiInventoryResult
            isAnalyzing = false
            analyzeAIItems = overview && inventoryResult.succeeded
                ? Parsers.analyzeAIItems(inventoryResult.output) : []
            if overview && !inventoryResult.succeeded { logFailure(inventoryResult) }
            let report = analysisResult
            analyzeIsOverview = report.overview
            analyzePath = report.path
            analyzeEntries = Array(report.entries
                .filter { $0.size > 0 }
                .sorted(by: AnalyzeEntry.analysisOrder)
                .prefix(10))
            analyzeTotalSize = report.totalSize
            analyzeLargeFiles = Array((report.largeFiles ?? [])
                .filter { $0.size > 0 }
                .sorted {
                    if $0.size != $1.size { return $0.size > $1.size }
                    return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                .prefix(10))
            analyzeStatus = l10n.tf("analyze.status.summary",
                                    analyzeEntries.count + analyzeAIItems.count,
                                    ByteFormat.format(analyzeTotalSize))
        }
    }

    private func scanAnalyzeAIInventory(enabled: Bool,
                                        environment: [String: String]) async -> RunResult {
        guard enabled else {
            return RunResult(output: "", exitCode: 0, timedOut: false)
        }
        return await MoleEngine.shared.runBridge(
            "bin/app_analyze_ai_inventory.sh",
            extraEnvironment: environment, timeout: 180)
    }

    // MARK: APFS 快照

    /// 读取可清除空间与本地快照列表（只读，幂等）。
    func scanSnapshots(force: Bool = false) {
        if snapshotsScanned && !force { return }
        snapshotsScanned = true
        Task {
            let result = await MoleEngine.shared.runBridge("bin/app_snapshots_scan.sh", timeout: 60)
            let info = Parsers.snapshotInfo(result.output)
            purgeableBytes = info.purgeable
            localSnapshots = info.names.map { SnapshotInfo(name: $0) }
            logFailure(result)
        }
    }

    /// 请求 Time Machine 归还本地快照空间（owner 命令，需管理员授权）。
    func thinSnapshots() {
        guard !isBusy else { return }
        confirmation = Confirmation(
            title: l10n.t("analyze.thin.confirm.title"),
            message: l10n.t("analyze.thin.confirm.msg"),
            confirmLabel: l10n.t("analyze.thin")) { [weak self] in
                guard let self else { return }
                self.isThinning = true
                self.log(self.l10n.t("log.thinSnapshots"))
                Task {
                    let result = await MoleEngine.shared.runPrivilegedBridge(
                        "bin/app_snapshots_thin.sh", arguments: [], timeout: 300)
                    self.isThinning = false
                    if result.succeeded {
                        let names = result.output.components(separatedBy: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }
                            .filter { !$0.isEmpty }
                        self.localSnapshots = names.map { SnapshotInfo(name: $0) }
                        self.log(self.l10n.t("gc.finished"))
                    } else {
                        self.log(self.l10n.t("gc.failed"))
                        self.logFailure(result)
                    }
                    self.scanSnapshots(force: true)
                }
            }
    }

    // MARK: Docker 摘要

    func scanDockerDf() {
        Task {
            let result = await MoleEngine.shared.runBridge("bin/app_docker_df.sh", timeout: 60)
            dockerDfRows = Parsers.dockerDfRows(result.output)
            logFailure(result)
        }
    }

    // MARK: 大文件重复检测

    /// 对当前目录分析结果中的大文件做内容指纹聚类。
    func scanDuplicates() {
        guard authorize(.duplicateScan, presentingPermissionCenter: true) else { return }
        guard !isBusy else { return }
        let scanEnvironment = fullDiskScanEnvironment
        guard scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1" else { return }
        let paths = analyzeLargeFiles.map(\.path)
        guard !paths.isEmpty else {
            log(l10n.t("log.dupNeedScan"))
            return
        }
        isScanningDups = true
        dupGroups = []
        dupSelection.removeAll()
        log(l10n.tf("log.dupScan", paths.count))
        Task {
            var stdinData = Data()
            for path in paths {
                stdinData.append(contentsOf: Array(path.utf8))
                stdinData.append(0)
            }
            let result = await MoleEngine.shared.runBridgeWithStdin(
                "bin/app_dup_scan.sh", stdinData: stdinData,
                extraEnvironment: scanEnvironment, timeout: 1800)
            isScanningDups = false
            dupGroups = Parsers.duplicateGroups(result.output)
            if dupGroups.isEmpty {
                if result.succeeded { log(l10n.t("analyze.dup.empty")) }
                else { logFailure(result) }
            } else {
                let count = dupGroups.reduce(0) { $0 + $1.count }
                log(l10n.tf("log.dupFound", dupGroups.count, count))
            }
        }
    }

    func toggleDupSelection(_ entry: AnalyzeEntry) {
        guard entry.canCleanDirectly else { return }
        if dupSelection.contains(entry.path) {
            dupSelection.remove(entry.path)
        } else {
            dupSelection.insert(entry.path)
        }
    }

    /// 删除勾选的重复副本（经 app_apply.sh 安全管道，废纸篓可恢复）。
    func deleteDuplicates() {
        guard !isBusy else { return }
        let paths = dupSelectedPaths
        guard !paths.isEmpty else { return }
        let bytes = dupGroups.flatMap { $0 }
            .filter { dupSelection.contains($0.path) }
            .reduce(UInt64(0)) { $0 + $1.size }
        let deletionPlan = DeletionPlan(paths: paths)
        confirmation = Confirmation(
            title: l10n.tf("analyze.confirm.title", paths.count),
            message: l10n.tf("analyze.confirm.msg", ByteFormat.format(bytes)),
            confirmLabel: l10n.t("analyze.dupDelete")) { [weak self] in
                guard let self else { return }
                self.isApplying = true
                self.statusText = self.l10n.tf("status.processing", paths.count)
                self.log(self.l10n.tf("log.pipeline", paths.count, "app_apply.sh"))
                Task {
                    let result = await MoleEngine.shared.runBridgeWithStdin(
                        "bin/app_apply.sh", stdinData: deletionPlan.stdinData, timeout: 900)
                    self.isApplying = false
                    if !result.output.isEmpty { self.log(result.output) }
                    self.logFailure(result, stdoutAlreadyLogged: true)
                    let summary = Parsers.applySummary(result.output)
                    self.statusText = (result.succeeded && summary.failed == 0)
                        ? self.l10n.tf("status.cleanupDone", summary.removed)
                        : self.l10n.tf("status.cleanupPartial", summary.removed, summary.failed)
                    self.dupGroups = []
                    self.dupSelection.removeAll()
                }
            }
    }

    /// 返回上级目录（根目录不再上跳）。
    func analyzeGoUp() {
        guard !isAnalyzing else { return }
        if analyzeIsOverview { return }
        if [NSHomeDirectory(), "/Applications", "/Library"].contains(analyzePath) {
            scanDiskOverview(force: true)
            return
        }
        var components = (analyzePath as NSString).pathComponents
        guard components.count > 1 else { return }
        components.removeLast()
        let parent = NSString.path(withComponents: components) 
        if parent == "" || parent == "/" {
            scanDiskOverview(force: true)
        } else {
            scanAnalyze(parent)
        }
    }

    /// NSOpenPanel 选择任意目录分析。
    func chooseAnalyzeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = l10n.t("analyze.pick")
        if panel.runModal() == .OK, let url = panel.url {
            scanAnalyze(url.path)
        }
    }

    func toggleAnalyzeSelection(_ entry: AnalyzeEntry) {
        guard entry.canCleanDirectly else { return }
        if analyzeSelection.contains(entry.path) {
            analyzeSelection.remove(entry.path)
        } else {
            analyzeSelection.insert(entry.path)
        }
    }

    func toggleAnalyzeAISelection(_ item: AnalyzeAIItem) {
        if analyzeAISelection.contains(item.path) {
            analyzeAISelection.remove(item.path)
        } else {
            analyzeAISelection.insert(item.path)
        }
    }

    func revealAnalyzeEntry(_ entry: AnalyzeEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
    }

    func openAnalyzeEntry(_ entry: AnalyzeEntry) {
        if entry.isApplicationBundle {
            uninstallSearch = URL(fileURLWithPath: entry.path).deletingPathExtension().lastPathComponent
            jump(to: .uninstall)
            if installedApps.isEmpty { scanInstalledApps() }
        } else if entry.isDir {
            scanAnalyze(entry.path)
        } else {
            revealAnalyzeEntry(entry)
        }
    }

    func applyAnalyzeCleanup() {
        guard !isBusy else { return }
        let paths = analyzeEntries.filter {
            analyzeSelection.contains($0.path) && $0.canCleanDirectly
        }.map(\.path)
        let aiPaths = analyzeAIItems.filter {
            analyzeAISelection.contains($0.path)
        }.map(\.path)
        guard !paths.isEmpty || !aiPaths.isEmpty else { return }
        let deletionPlan = DeletionPlan(paths: paths)
        let aiDeletionPlan = DeletionPlan(paths: aiPaths)
        let selectedCount = deletionPlan.items.count + aiDeletionPlan.items.count
        confirmation = Confirmation(
            title: l10n.tf("analyze.confirm.title", selectedCount),
            message: l10n.tf("analyze.confirm.msg", ByteFormat.format(analyzeCombinedSelectedBytes)),
            confirmLabel: l10n.t("confirm.apply.trash.ok")) { [weak self] in
                guard let self else { return }
                self.isApplying = true
                self.statusText = self.l10n.tf("status.processing", selectedCount)
                self.log(self.l10n.tf("log.pipeline", selectedCount, "app_apply.sh"))
                Task {
                    var removed = 0
                    var skipped = 0
                    var failed = 0
                    var allSucceeded = true
                    if !deletionPlan.items.isEmpty {
                        let allowedRoot = self.analyzeIsOverview ? NSHomeDirectory() : self.analyzePath
                        let summary = await Task.detached(priority: .utility) {
                            NativeCore.shared.applyCleanup(
                                items: deletionPlan.items, permanent: false,
                                allowedRoots: [allowedRoot])
                        }.value
                        if !summary.messages.isEmpty {
                            self.log(summary.messages.joined(separator: "\n"))
                        }
                        removed += summary.removed
                        skipped += summary.skipped
                        failed += summary.failed
                        allSucceeded = allSucceeded && summary.failed == 0 && summary.skipped == 0
                    }
                    if !aiDeletionPlan.items.isEmpty {
                        let result = await MoleEngine.shared.runBridgeWithStdin(
                            "bin/app_analyze_ai_apply.sh",
                            stdinData: aiDeletionPlan.stdinData,
                            extraEnvironment: self.fullDiskScanEnvironment,
                            timeout: 900)
                        if !result.output.isEmpty { self.log(result.output) }
                        self.logFailure(result, stdoutAlreadyLogged: true)
                        let summary = Parsers.applySummary(result.output)
                        removed += summary.removed
                        failed += summary.failed
                        allSucceeded = allSucceeded && result.succeeded
                    }
                    self.isApplying = false
                    self.statusText = (allSucceeded && failed == 0)
                        ? self.l10n.tf("status.cleanupDone", removed)
                        : self.l10n.tf("status.cleanupPartial", removed, failed)
                    self.log((allSucceeded && failed == 0)
                        ? self.l10n.tf("log.cleanupDone", removed)
                        : self.l10n.tf("log.cleanupPartial", removed, failed)
                              + (skipped > 0 ? " (\(skipped) skipped)" : ""))
                    if self.analyzeIsOverview {
                        self.scanDiskOverview(force: true)
                    } else {
                        self.scanAnalyze()
                    }
                }
            }
    }

    // MARK: - 自动目录清理

    private static let autoCleanupLastCheckKey = "SMAutoCleanupLastCheck"
    private static let autoCleanupMinimumInterval: TimeInterval = 6 * 60 * 60

    /// 通过系统目录选择器添加规则。新规则默认关闭，要求用户预览后显式启用。
    func addAutoCleanupRule() {
        guard !isBusy else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.message = l10n.t("auto.pick.message")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let directory = try AutoCleanupPlanner.validatedRoot(url)
            guard !autoCleanupRules.contains(where: { $0.directory == directory }) else {
                autoCleanupStatus = l10n.t("auto.status.duplicate")
                return
            }
            let rule = AutoCleanupRule(
                directory: directory,
                policy: .sizeLimit,
                sizeLimitBytes: 5_000_000_000,
                retentionDays: 30,
                isEnabled: false,
                isRegenerable: false,
                lastRunAt: nil,
                lastReclaimedBytes: 0)
            autoCleanupRules.append(rule)
            persistAutoCleanupRules()
            autoCleanupStatus = l10n.t("auto.status.added")
            previewAutoCleanup(rule.id)
        } catch {
            autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
            log(autoCleanupStatus)
        }
    }

    func updateAutoCleanupRule(_ updated: AutoCleanupRule) {
        guard !isBusy else { return }
        guard let index = autoCleanupRules.firstIndex(where: { $0.id == updated.id }) else { return }
        let previous = autoCleanupRules[index]
        var normalized = updated
        normalized.sizeLimitBytes = min(
            AutoCleanupRule.maximumSizeLimitBytes,
            max(AutoCleanupRule.minimumSizeLimitBytes, normalized.sizeLimitBytes))
        normalized.retentionDays = min(3650, max(1, normalized.retentionDays))
        if normalized.isRegenerable {
            if !previous.isRegenerable || previous.directory != normalized.directory {
                normalized.authorizedRootIdentity = AutoCleanupRule.rootIdentity(
                    at: normalized.directory)
            } else {
                normalized.authorizedRootIdentity = previous.authorizedRootIdentity
            }
            if let authorized = normalized.authorizedRootIdentity,
               AutoCleanupRule.rootIdentity(at: normalized.directory) == authorized {
                normalized.safetyVersion = AutoCleanupRule.currentSafetyVersion
            } else {
                normalized.isRegenerable = false
                normalized.isEnabled = false
                normalized.authorizedRootIdentity = nil
                autoCleanupStatus = l10n.t("auto.status.authorizationRequired")
            }
        } else {
            normalized.isEnabled = false
            normalized.authorizedRootIdentity = nil
        }
        if normalized.isEnabled && !normalized.isSafetyAuthorized {
            normalized.isEnabled = false
            autoCleanupStatus = l10n.t("auto.status.authorizationRequired")
        }
        let scheduleChanged = normalized.isEnabled && (
            !previous.isEnabled
                || previous.policy != normalized.policy
                || previous.sizeLimitBytes != normalized.sizeLimitBytes
                || previous.retentionDays != normalized.retentionDays)
        autoCleanupRules[index] = normalized
        if autoCleanupPreviewRuleID == normalized.id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        persistAutoCleanupRules()
        if scheduleChanged {
            UserDefaults.standard.removeObject(forKey: Self.autoCleanupLastCheckKey)
        }
    }

    func removeAutoCleanupRule(_ id: UUID) {
        guard !isBusy else { return }
        autoCleanupRules.removeAll { $0.id == id }
        if autoCleanupPreviewRuleID == id {
            autoCleanupPreview = nil
            autoCleanupPreviewRuleID = nil
        }
        persistAutoCleanupRules()
    }

    func previewAutoCleanup(_ id: UUID) {
        guard authorize(.previewAutoCleanup(ruleID: id),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, let rule = autoCleanupRules.first(where: { $0.id == id }) else { return }
        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: rule, protecting: protectedAutoCleanupDirectories(excluding: id))
                autoCleanupPreview = plan
                autoCleanupPreviewRuleID = id
                autoCleanupStatus = plan.candidates.isEmpty
                    ? l10n.t("auto.status.empty")
                    : l10n.tf("auto.status.preview", plan.candidates.count,
                              ByteFormat.format(plan.reclaimableBytes))
            } catch {
                autoCleanupPreview = nil
                autoCleanupPreviewRuleID = nil
                autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
                log(autoCleanupStatus)
            }
            isAutoCleanupScanning = false
        }
    }

    /// 手动执行仍需二次确认；确认后会重新规划，避免使用过期预览。
    func runAutoCleanupNow(_ id: UUID) {
        guard authorize(.runAutoCleanup(ruleID: id),
                        presentingPermissionCenter: true) else { return }
        guard !isBusy, let rule = autoCleanupRules.first(where: { $0.id == id }) else { return }
        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: rule, protecting: protectedAutoCleanupDirectories(excluding: id))
                autoCleanupPreview = plan
                autoCleanupPreviewRuleID = id
                isAutoCleanupScanning = false
                guard !plan.candidates.isEmpty else {
                    autoCleanupStatus = l10n.t("auto.status.empty")
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = l10n.t("auto.confirm.title")
                alert.informativeText = l10n.tf(
                    "auto.confirm.message", plan.candidates.count,
                    ByteFormat.format(plan.reclaimableBytes))
                alert.addButton(withTitle: l10n.t("confirm.apply.trash.ok"))
                alert.addButton(withTitle: l10n.t("common.cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                isAutoCleanupScanning = true
                let result = await applyAutoCleanup(rule: rule, plan: plan)
                isAutoCleanupScanning = false
                autoCleanupStatus = result.failed == 0
                    ? l10n.tf("auto.status.done", result.removed,
                              ByteFormat.format(result.reclaimedBytes))
                    : l10n.tf("auto.status.partial", result.removed, result.failed)
            } catch {
                isAutoCleanupScanning = false
                autoCleanupStatus = l10n.tf("auto.status.invalid", error.localizedDescription)
                log(autoCleanupStatus)
            }
        }
    }

    /// 启动后与每小时定时器都会调用；这里把实际目录扫描限频为每六小时一次。
    func runScheduledAutoCleanup(force: Bool = false) {
        let hasScheduledWork = autoCleanupRules.contains {
            $0.isEnabled && $0.isSafetyAuthorized
        } || smartAutomation.triggers.contains { $0.isEnabled && $0.isValid }
        guard hasScheduledWork else {
            cancelAutomationRetry()
            return
        }

        // Background work must never trigger macOS Desktop/Documents/Downloads
        // consent dialogs. Automated scans require the same one-time Full Disk
        // Access grant as manual protected scans, but skip silently instead of
        // presenting the permission center when the grant is absent.
        permissionCenter.refresh()
        guard permissionCenter.fullDiskAccessGranted else {
            cancelAutomationRetry()
            autoCleanupStatus = l10n.t("auto.status.diskPermissionRequired")
            if !reportedScheduledPermissionRequirement {
                log(l10n.t("auto.log.diskPermissionRequired"))
                reportedScheduledPermissionRequirement = true
            }
            return
        }
        reportedScheduledPermissionRequirement = false

        guard !isBusy else {
            scheduleAutomationRetry()
            return
        }
        cancelAutomationRetry()
        let rules = autoCleanupRules.filter { $0.isEnabled && $0.isSafetyAuthorized }
        guard !rules.isEmpty else {
            runScheduledSmartTriggers()
            return
        }
        let defaults = UserDefaults.standard
        let lastCheck = defaults.object(forKey: Self.autoCleanupLastCheckKey) as? Date
        if !force, let lastCheck,
           Date().timeIntervalSince(lastCheck) < Self.autoCleanupMinimumInterval {
            runScheduledSmartTriggers()
            return
        }
        defaults.set(Date(), forKey: Self.autoCleanupLastCheckKey)

        isAutoCleanupScanning = true
        autoCleanupStatus = l10n.t("auto.status.scanning")
        Task {
            var removed = 0
            var reclaimed: UInt64 = 0
            var failures = 0
            for snapshot in rules {
                guard let current = autoCleanupRules.first(where: { $0.id == snapshot.id }),
                      current.isEnabled, current.isSafetyAuthorized else { continue }
                do {
                    let plan = try await AutoCleanupPlanner.plan(
                        for: current,
                        protecting: protectedAutoCleanupDirectories(excluding: current.id))
                    guard !plan.candidates.isEmpty else { continue }
                    let result = await applyAutoCleanup(rule: current, plan: plan)
                    removed += result.removed
                    reclaimed &+= result.reclaimedBytes
                    failures += result.failed
                } catch {
                    failures += 1
                    log(l10n.tf("auto.log.ruleFailed", current.directory, error.localizedDescription))
                }
            }
            isAutoCleanupScanning = false
            if failures > 0 {
                // 临时权限或文件竞争失败时，让下一次小时调度重试，而不是静默等待六小时。
                defaults.removeObject(forKey: Self.autoCleanupLastCheckKey)
            }
            autoCleanupStatus = failures == 0
                ? l10n.tf("auto.status.done", removed, ByteFormat.format(reclaimed))
                : l10n.tf("auto.status.partial", removed, failures)
            runScheduledSmartTriggers()
        }
    }

    /// 固定类型的智能触发器调度。规则只能指向三个内建动作，持久化模型没有
    /// script/command/arguments 字段；每个动作仍要通过对应的 Safe 执行闸门。
    func runScheduledSmartTriggers() {
        guard !isBusy else {
            scheduleAutomationRetry()
            return
        }
        cancelAutomationRetry()
        let rules = smartAutomation.triggers.filter { $0.isEnabled && $0.isValid }
        guard !rules.isEmpty else { return }

        isSmartAutomationRunning = true
        Task {
            let context = await makeSmartTriggerContext(for: rules)
            let due = SmartTriggerEvaluator.dueRules(rules, context: context)
            for snapshot in due {
                guard let current = currentSmartTrigger(matching: snapshot),
                      SmartTriggerEvaluator.evaluate(current, context: context).shouldRun else {
                    continue
                }
                if await executeSmartTrigger(current) {
                    if !smartAutomation.markFired(id: current.id),
                       let error = smartAutomation.lastError {
                        log(error)
                    }
                    log(l10n.tf("automation.log.fired", current.name))
                } else {
                    log(l10n.tf("automation.log.refused", current.name))
                }
            }
            isSmartAutomationRunning = false
        }
    }

    private func makeSmartTriggerContext(for rules: [SmartTriggerRule]) async
        -> SmartTriggerContext {
        // Availability is runtime state, not deletion authority. Refresh it for
        // every scheduler pass so a remounted saved location becomes eligible
        // without requiring the user to open a settings window first.
        _ = savedScanLocations.refreshAvailability(persist: false)
        var projectActivity: [String: Date] = [:]
        if rules.contains(where: { $0.scope.kind == .project }) {
            let hasFreshSnapshot: Bool
            if projectRadar.isScanning {
                hasFreshSnapshot = false
            } else {
                hasFreshSnapshot = await projectRadar.reload(
                    locations: savedScanLocations.locations,
                    fullDiskAccessGranted: permissionCenter.fullDiskAccessGranted)
            }
            if hasFreshSnapshot {
                for project in projectRadar.snapshot.projects
                    where ProjectHibernation.supportsRecoverableTrash(for: project.rootPath) {
                    projectActivity[project.id] = project.lastActivityAt
                }
            }
        }

        var locationBytes: [String: UInt64] = [:]
        var locationOldest: [String: Date] = [:]
        for location in savedScanLocations.locations where location.availability == .available {
            let locationRules = rules.filter {
                $0.action == .cleanSavedLocationSafe
                    && $0.scope.targetID == location.id.uuidString
            }
            guard !locationRules.isEmpty,
                  let authorizationRule = authorizedDirectoryRule(for: location) else { continue }

            // The threshold configured by the Smart Trigger is authoritative.
            // The matching directory rule only provides the user's explicit
            // regenerable-content authorization and the fixed Trash boundary.
            var contextRule = authorizationRule
            if let minimumRetention = locationRules.compactMap({ trigger -> Int? in
                guard trigger.condition.kind == .savedLocationRetention else { return nil }
                return trigger.condition.days
            }).min() {
                contextRule.policy = .retentionDays
                contextRule.retentionDays = minimumRetention
            } else {
                contextRule.policy = .sizeLimit
                contextRule.sizeLimitBytes = AutoCleanupRule.maximumSizeLimitBytes
            }
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: contextRule,
                    protecting: protectedAutoCleanupDirectories(excluding: contextRule.id))
                locationBytes[location.id.uuidString] = plan.totalBytes
                if let oldest = plan.candidates.map(\.modifiedAt).min() {
                    locationOldest[location.id.uuidString] = oldest
                }
            } catch {
                log(l10n.tf("auto.log.ruleFailed", location.path, error.localizedDescription))
            }
        }
        return SmartTriggerContext(now: Date(),
                                   projectLastActivity: projectActivity,
                                   savedLocationBytes: locationBytes,
                                   savedLocationOldestItem: locationOldest)
    }

    private func executeSmartTrigger(_ rule: SmartTriggerRule) async -> Bool {
        guard currentSmartTrigger(matching: rule) != nil else { return false }
        switch rule.action {
        case .quickCleanSafe:
            let scan = await unifiedCleanupScan()
            guard scan.allSucceeded else {
                scan.results.forEach { logFailure($0) }
                return false
            }
            // 扫描结束到真正执行之间应用可能刚好启动。自动化在删除前重新读取
            // 一次完整运行态，并从静态扫描结果重新判定，避免使用过期快照。
            let freshSnapshot = await captureRunningApplicationSnapshot()
            guard freshSnapshot.isComplete else { return false }
            let safeCategories = protectRunningApplications(
                in: scan.categories, snapshot: freshSnapshot).filter {
                    CleanupRiskPolicy.isEligible(
                        $0, mode: .automatic, running: freshSnapshot)
                }
            guard currentSmartTrigger(matching: rule) != nil else { return false }
            guard !safeCategories.isEmpty else { return true }
            var failed = 0
            let grouped = Dictionary(grouping: safeCategories, by: \.applyRoute)
            for route in CleanupApplyRoute.allCases {
                guard currentSmartTrigger(matching: rule) != nil else { return false }
                guard let categories = grouped[route] else { continue }
                let result = await executeCleanupRoute(route, categories: categories,
                                                       imageMode: nil, mode: .automatic)
                failed += result.failed
            }
            CleanupCache.invalidate()
            return failed == 0

        case .cleanSavedLocationSafe:
            guard let targetID = rule.scope.targetID,
                  let location = savedScanLocations.locations.first(where: {
                      $0.id.uuidString == targetID && $0.availability == .available
                  }),
                  let authorizationRule = authorizedDirectoryRule(for: location),
                  let effectiveRule = directoryRule(
                      for: rule, authorizedBy: authorizationRule) else { return false }
            do {
                let plan = try await AutoCleanupPlanner.plan(
                    for: effectiveRule,
                    protecting: protectedAutoCleanupDirectories(excluding: effectiveRule.id))
                guard currentSmartTrigger(matching: rule) != nil,
                      let currentAuthorization = currentAuthorizedDirectoryRule(
                          matching: authorizationRule, location: location),
                      let currentEffectiveRule = directoryRule(
                          for: rule, authorizedBy: currentAuthorization),
                      currentEffectiveRule == effectiveRule else { return false }
                guard !plan.candidates.isEmpty else { return true }
                let result = await applyAutoCleanup(rule: currentEffectiveRule, plan: plan)
                return result.failed == 0
            } catch {
                log(l10n.tf("auto.log.ruleFailed", location.path, error.localizedDescription))
                return false
            }

        case .hibernateProjectSafeArtifacts:
            guard let projectID = rule.scope.targetID,
                  await projectRadar.reload(
                    locations: savedScanLocations.locations,
                    fullDiskAccessGranted: permissionCenter.fullDiskAccessGranted),
                  let project = projectRadar.snapshot.projects.first(where: { $0.id == projectID }),
                  ProjectHibernation.supportsRecoverableTrash(for: project.rootPath),
                  let currentRule = currentSmartTrigger(matching: rule)
            else { return false }
            let freshContext = SmartTriggerContext(
                now: Date(),
                projectLastActivity: [project.id: project.lastActivityAt])
            guard SmartTriggerEvaluator.evaluate(
                currentRule, context: freshContext).shouldRun else { return false }
            let maximumActivityAt: Date?
            if currentRule.condition.kind == .projectInactive,
               let days = currentRule.condition.days {
                maximumActivityAt = Calendar.current.date(
                    byAdding: .day, value: -days, to: freshContext.now)
            } else {
                maximumActivityAt = nil
            }
            guard let receipt = await projectHibernation.hibernate(
                project: project,
                mode: .automatic,
                fullDiskAccessGranted: permissionCenter.fullDiskAccessGranted,
                maximumProjectActivityAt: maximumActivityAt,
                shouldProceed: { [weak self] in
                    self?.currentSmartTrigger(matching: currentRule) != nil
                }) else { return false }
            return receipt.state == .hibernated
        }
    }

    private func currentSmartTrigger(matching snapshot: SmartTriggerRule) -> SmartTriggerRule? {
        guard let current = smartAutomation.triggers.first(where: { $0.id == snapshot.id }),
              current.isEnabled, current.isValid, current == snapshot else { return nil }
        return current
    }

    private func scheduleAutomationRetry() {
        guard scheduledAutomationRetry == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.scheduledAutomationRetry = nil
                self.runScheduledAutoCleanup()
            }
        }
        scheduledAutomationRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5 * 60, execute: work)
    }

    private func cancelAutomationRetry() {
        scheduledAutomationRetry?.cancel()
        scheduledAutomationRetry = nil
    }

    private func authorizedDirectoryRule(for location: SavedScanLocation) -> AutoCleanupRule? {
        autoCleanupRules.first {
            $0.directory == location.path && $0.isEnabled && $0.isSafetyAuthorized
        }
    }

    private func currentAuthorizedDirectoryRule(
        matching snapshot: AutoCleanupRule,
        location: SavedScanLocation
    ) -> AutoCleanupRule? {
        guard let current = autoCleanupRules.first(where: { $0.id == snapshot.id }),
              current == snapshot,
              current.directory == location.path,
              current.isEnabled,
              current.isSafetyAuthorized else { return nil }
        return current
    }

    private func directoryRule(for trigger: SmartTriggerRule,
                               authorizedBy rule: AutoCleanupRule) -> AutoCleanupRule? {
        var effective = rule
        switch trigger.condition.kind {
        case .savedLocationSizeLimit:
            guard let bytes = trigger.condition.bytes else { return nil }
            effective.policy = .sizeLimit
            effective.sizeLimitBytes = bytes
        case .savedLocationRetention:
            guard let days = trigger.condition.days else { return nil }
            effective.policy = .retentionDays
            effective.retentionDays = days
        case .dailySchedule, .weeklySchedule:
            break
        case .projectInactive:
            return nil
        }
        return effective
    }

    private func applyAutoCleanup(rule: AutoCleanupRule, plan: AutoCleanupPlan) async
        -> (removed: Int, failed: Int, reclaimedBytes: UInt64) {
        guard rule.isSafetyAuthorized,
              let authorizedRootIdentity = rule.authorizedRootIdentity,
              plan.candidates.allSatisfy(\.automaticEligible) else {
            return (0, max(1, plan.candidates.count), 0)
        }
        var stdinData = Data()
        var planned: [AutoCleanupCandidate] = []
        var preparationFailures = 0
        for candidate in plan.candidates {
            guard !candidate.identity.isEmpty else {
                preparationFailures += 1
                continue
            }
            let plannedLatestMtime = String(
                Int64(candidate.modifiedAt.timeIntervalSince1970.rounded(.down)))
            for field in [plan.root, authorizedRootIdentity,
                          candidate.path, candidate.identity,
                          plannedLatestMtime,
                          AutoCleanupRule.safetyToken] {
                stdinData.append(contentsOf: field.utf8)
                stdinData.append(0)
            }
            planned.append(candidate)
        }
        guard !planned.isEmpty else {
            return (0, max(1, preparationFailures), 0)
        }

        autoCleanupStatus = l10n.tf("auto.status.cleaning", planned.count)
        log(l10n.tf("auto.log.cleaning", planned.count, rule.directory))
        let result = await MoleEngine.shared.runBridgeWithStdin(
            "bin/app_auto_apply.sh", stdinData: stdinData, timeout: 900)
        if !result.output.isEmpty { log(result.output) }
        logFailure(result, stdoutAlreadyLogged: true)
        let summary = Parsers.applySummary(result.output)
        let processFailure = result.succeeded || summary.failed > 0 ? 0 : 1
        let failed = preparationFailures + summary.failed + processFailure
        let reclaimed = failed == 0 && summary.removed == planned.count
            ? planned.reduce(0) { $0 &+ $1.bytes }
            : 0
        if let index = autoCleanupRules.firstIndex(where: { $0.id == rule.id }) {
            autoCleanupRules[index].lastRunAt = Date()
            autoCleanupRules[index].lastReclaimedBytes = reclaimed
            persistAutoCleanupRules()
        }
        CleanupCache.invalidate()
        return (summary.removed, failed, reclaimed)
    }

    private func persistAutoCleanupRules() {
        AutoCleanupRuleStore.save(autoCleanupRules)
    }

    private func protectedAutoCleanupDirectories(excluding id: UUID) -> [String] {
        Array(autoCleanupRules.lazy.filter { $0.id != id }.map(\.directory))
    }

    // MARK: - 白名单

    private static var whitelistFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory().appending("/.config/mole/whitelist"))
    }

    func loadWhitelist() {
        whitelistEntries = Self.readWhitelistEntries()
    }

    private static func readWhitelistEntries() -> [String] {
        guard let content = try? String(contentsOf: whitelistFileURL, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func addWhitelistEntry(_ rawPath: String) {
        let path = rawPath.trimmingCharacters(in: .whitespaces)
        guard path.hasPrefix("/"), !path.contains("..") else {
            log(l10n.tf("log.wlInvalid", path))
            return
        }
        guard !whitelistEntries.contains(path) else { return }
        whitelistEntries.append(path)
        saveWhitelist()
    }

    func removeWhitelistEntry(_ path: String) {
        whitelistEntries.removeAll { $0 == path }
        saveWhitelist()
    }

    func saveWhitelist() {
        let header = """
        # ForgeSweep whitelist (shared by native clean / purge / bridge cleanup)
        # One absolute path or glob per line; built-in engine safety always applies.

        """
        let content = header + whitelistEntries.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(
            at: Self.whitelistFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? content.write(to: Self.whitelistFileURL, atomically: true, encoding: .utf8)
        CleanupCache.invalidate()
        log(l10n.tf("log.wlSaved", whitelistEntries.count))
    }
}
