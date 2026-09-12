import Foundation

/// 由调用方一次性采集的运行应用快照。风险策略只读这个值，不自行启动进程或访问 UI。
struct RunningApplicationSnapshot: Equatable, Sendable {
    let bundleIdentifiers: Set<String>
    let processNames: Set<String>
    /// 进程表不可读时必须为 false；不完整不能被当作“没有运行”。
    let isComplete: Bool

    init(bundleIdentifiers: some Sequence<String> = [],
         processNames: some Sequence<String> = [],
         isComplete: Bool = true) {
        self.bundleIdentifiers = Set(bundleIdentifiers.map(Self.normalize))
        self.processNames = Set(processNames.map(Self.normalize))
        self.isComplete = isComplete
    }

    static let unavailable = RunningApplicationSnapshot(isComplete: false)

    func contains(bundleIdentifier: String) -> Bool {
        bundleIdentifiers.contains(Self.normalize(bundleIdentifier))
    }

    func contains(processName: String) -> Bool {
        processNames.contains(Self.normalize(processName))
    }

    private static func normalize(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct CleanupPolicyDescriptor: Equatable, Sendable {
    let source: CleanupSource
    let risk: CleanupRisk
    let disposal: CleanupDisposal
    let applyRoute: CleanupApplyRoute
    let activityGuard: CleanupActivityGuard
    let reasonKey: String
}

struct CleanupRiskAssessment: Equatable, Sendable {
    let risk: CleanupRisk
    let reasonKey: String
}

enum CleanupExecutionMode: Sendable {
    case manual
    case quickClean
    case automatic
}

/// 保守的共享风险策略：未识别内容一律 Warning，Safe 只来自显式可再生缓存规则。
enum CleanupRiskPolicy {
    private static let protectedAbsoluteRoots = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
        "/private", "/var", "/etc", "/dev"
    ]
    static func core(section: String,
                     path: String,
                     homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else { return protectedUnknown(source: .core) }
        let normalized = normalize(path)

        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)

        if let knowledgeDescriptor = appCacheKnowledgeDescriptor(normalized, home: home) {
            return knowledgeDescriptor
        }

        let trashRoot = home + "/.Trash"
        if isDirectChild(normalized, of: trashRoot) {
            // `Parsers` promotes ordinary top-level Trash entries for the
            // cleanup page (age gate 0). Direct callers that do not make that
            // promotion stay Warning by default.
            return warningDescriptor(source: .core, route: .genericTrash,
                                     reasonKey: "cleanup.risk.unknown")
        }

        if isExplicitDeveloperCachePath(normalized, home: home) {
            return developerCache(path: normalized, homeDirectory: homeDirectory)
        }
        let aiDescriptor = ai(kind: "cache", path: normalized,
                              homeDirectory: homeDirectory)
        if aiDescriptor.risk == .safe { return aiDescriptor }
        // These cache-named parents are actually browser profiles. If their
        // rebuildable leaves are absent, never fall back to cleaning cookies
        // and local storage through the broad Library/Caches rule.
        let profileRoots = [home + "/Library/Caches/Codex", home + "/.cache/chrome-devtools-mcp"]
        if profileRoots.contains(where: { normalized == $0 || isStrictDescendant(normalized, of: $0) }) {
            return protectedDescriptor(source: .aiCache, reasonKey: "cleanup.risk.protectedContent")
        }
        if isExplicitXcodeCachePath(normalized, home: home) {
            return xcode(kind: "clean", path: normalized,
                         homeDirectory: homeDirectory)
        }

        let cachePrefix = home + "/Library/Caches/"
        if normalized.hasPrefix(cachePrefix) {
            let remainder = String(normalized.dropFirst(cachePrefix.count))
            let owner = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            let guardKind: CleanupActivityGuard
            if isValidReverseDNSOwner(owner) {
                guardKind = .reverseDNSCache
            } else if isBrowserCacheOwner(owner) {
                guardKind = .browser
            } else {
                // The macOS Caches contract makes the data rebuildable. The
                // final sink still checks one shared open-file snapshot.
                guardKind = .openFile
            }
            return .init(source: .core, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash, activityGuard: guardKind,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        if let owner = containerCacheOwner(normalized, home: home) {
            return .init(source: .core, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash,
                         activityGuard: isValidReverseDNSOwner(owner)
                            ? .reverseDNSCache : .openFile,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        if isApplicationSupportCachePath(normalized, home: home) {
            let guardKind: CleanupActivityGuard = isBrowserPath(normalized, section: section)
                ? .browser : .openFile
            return .init(source: .core, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash, activityGuard: guardKind,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        let logPrefix = home + "/Library/Logs/"
        if normalized.hasPrefix(logPrefix) {
            return .init(source: .core, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.rebuildableCache")
        }

        let diagnosticPrefix = home + "/Library/DiagnosticReports/"
        if normalized.hasPrefix(diagnosticPrefix) {
            return .init(source: .core, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.diagnosticReport")
        }

        let lowerSection = section.lowercased()
        let reason = lowerSection.contains("backup") ? "cleanup.risk.backup" :
            lowerSection.contains("project") ? "cleanup.risk.projectArtifact" :
            lowerSection.contains("leftover") ? "cleanup.risk.appLeftover" :
            "cleanup.risk.unknown"
        return warningDescriptor(source: .core, route: .genericTrash, reasonKey: reason)
    }

    static func installer() -> CleanupPolicyDescriptor {
        warningDescriptor(source: .installer, route: .installerTrash,
                          reasonKey: "cleanup.risk.installer")
    }

    static func recommendedTrash() -> CleanupPolicyDescriptor {
        .init(source: .core, risk: .safe, disposal: .trash,
              applyRoute: .genericTrash, activityGuard: .openFile,
              reasonKey: "cleanup.risk.rebuildableCache")
    }

    /// A trashed application with no live bundle match is strong ownership
    /// evidence. Only exact bundle-owned cache/log locations are safe for the
    /// cleanup page; preferences, containers and application support remain
    /// manual analysis data.
    static func appLeftover(path: String,
                            bundleIdentifier: String,
                            homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: .appLeftover)
        }
        let normalized = normalize(path)
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .appLeftover,
                                       reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)
        guard isValidReverseDNSOwner(bundleIdentifier) else {
            return warningDescriptor(source: .appLeftover, route: .genericTrash,
                                     reasonKey: "cleanup.risk.appLeftover")
        }
        let safeDirectoryRoots = [
            home + "/Library/Caches/" + bundleIdentifier,
            home + "/Library/Logs/" + bundleIdentifier,
            home + "/Library/Caches/com.apple.nsurlsessiond/Downloads/" + bundleIdentifier
        ]
        if safeDirectoryRoots.contains(where: {
            normalized == $0 || isStrictDescendant(normalized, of: $0)
        }) {
            return .init(source: .appLeftover, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash, activityGuard: .none,
                         reasonKey: "cleanup.risk.appLeftover")
        }
        // Application Support is a mixed tree. The orphan bridge splits out
        // explicit cache/log leaves (Cache, Code Cache, GPUCache, Crashpad
        // completed, etc.); only those leaves are safe, while the surrounding
        // app data remains a review-only Warning.
        if isApplicationSupportCachePath(normalized, home: home) {
            return .init(source: .appLeftover, risk: .safe, disposal: .trash,
                         applyRoute: .genericTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.appLeftover")
        }
        return warningDescriptor(source: .appLeftover, route: .genericTrash,
                                 reasonKey: "cleanup.risk.appLeftover")
    }

    static func projectArtifact(risk: CleanupRisk = .warning,
                                runtimeReasonKey: String? = nil) -> CleanupPolicyDescriptor {
        if let runtimeReasonKey {
            return protectedDescriptor(source: .projectArtifact,
                                       reasonKey: runtimeReasonKey)
        }
        switch risk {
        case .safe:
            return .init(source: .projectArtifact, risk: .safe, disposal: .trash,
                         applyRoute: .projectArtifactTrash, activityGuard: .none,
                         reasonKey: "cleanup.risk.rebuildableDeveloperCache")
        case .warning:
            return warningDescriptor(source: .projectArtifact, route: .projectArtifactTrash,
                                     reasonKey: "cleanup.risk.projectArtifact")
        case .protected:
            return protectedDescriptor(source: .projectArtifact,
                                       reasonKey: "cleanup.risk.protectedContent")
        }
    }

    static func developerCache(path: String,
                               homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: .developerCache)
        }
        let normalized = normalize(path)
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .developerCache,
                                       reasonKey: "cleanup.risk.protectedContent")
        }

        let home = normalize(homeDirectory)
        let explicitSafeRoots = developerCacheRoots(home: home)
        if explicitSafeRoots.contains(where: { normalized == $0 || isStrictDescendant(normalized, of: $0) }) {
            return .init(source: .developerCache, risk: .safe, disposal: .trash,
                         // Shared package caches can be touched by arbitrary
                         // build processes.  A process-name guard would hide
                         // all caches behind unrelated `node`/`python`/`java`
                         // services, so the bridge uses one lsof snapshot for
                         // the selected subtree and fails closed when it is
                         // unavailable.
                         applyRoute: .developerCacheTrash, activityGuard: .openFile,
                         reasonKey: "cleanup.risk.rebuildableDeveloperCache")
        }

        let reverseDNSCachePrefix = home + "/Library/Caches/"
        if normalized.hasPrefix(reverseDNSCachePrefix) {
            let remainder = String(normalized.dropFirst(reverseDNSCachePrefix.count))
            let owner = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            if isValidReverseDNSOwner(owner) {
                return .init(source: .developerCache, risk: .safe, disposal: .trash,
                             applyRoute: .developerCacheTrash, activityGuard: .reverseDNSCache,
                             reasonKey: "cleanup.risk.rebuildableDeveloperCache")
            }
        }

        return warningDescriptor(source: .developerCache, route: .developerCacheTrash,
                                 reasonKey: "cleanup.risk.unverifiedDeveloperCache")
    }

    static func ai(kind: String,
                   path: String,
                   homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        let normalizedKind = kind.lowercased()
        let source: CleanupSource = normalizedKind == "session" ? .aiSession :
            (normalizedKind == "model" || normalizedKind == "keep" ? .aiModel : .aiCache)
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: source)
        }
        let normalized = normalize(path)
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: source, reasonKey: "cleanup.risk.protectedContent")
        }
        switch normalizedKind {
        case "model", "keep":
            return protectedDescriptor(source: .aiModel, reasonKey: "cleanup.risk.model")
        case "session":
            return warningDescriptor(source: .aiSession, route: .aiTrash,
                                     reasonKey: "cleanup.risk.userSession")
        case "cache":
            if aiCacheRoots(homeDirectory: homeDirectory).contains(where: {
                normalized == $0 || isStrictDescendant(normalized, of: $0)
            }) {
                return .init(source: .aiCache, risk: .safe, disposal: .trash,
                             applyRoute: .aiTrash, activityGuard: .ide,
                             reasonKey: "cleanup.risk.rebuildableCache")
            }
            return warningDescriptor(source: .aiCache, route: .aiTrash,
                                     reasonKey: "cleanup.risk.unverifiedCache")
        default:
            return warningDescriptor(source: .aiCache, route: .aiTrash,
                                     reasonKey: "cleanup.risk.unknown")
        }
    }

    /// Discovery and deletion classification share the same audited leaves.
    static func aiCacheRoots(homeDirectory: String = NSHomeDirectory()) -> [String] {
        let home = normalize(homeDirectory)
        return [
                home + "/.claude/statsig",
                // Codex Desktop keeps a rebuildable Chromium/electron cache
                // under Library/Caches.  Its settings, auth and session data
                // live elsewhere (Application Support / ~/.codex) and remain
                // outside this allowlist.
                // Keep this in lockstep with vendor/mole's audited Codex
                // Desktop catalog. The profile parent also contains durable
                // browser state and must never be blanket-cleaned.
                home + "/Library/Caches/Codex/Default/Cache",
                home + "/Library/Caches/Codex/Default/Code Cache",
                home + "/Library/Caches/Codex/Default/Partitions/codex-browser-app/Cache",
                home + "/Library/Caches/Codex/Default/Partitions/codex-browser-app/Code Cache",
                home + "/Library/Caches/Codex/codex-browser-app/Cache",
                home + "/Library/Caches/Codex/codex-browser-app/Code Cache",
                home + "/Library/Application Support/Code/Cache",
                home + "/Library/Application Support/Code/Code Cache",
                home + "/Library/Application Support/Code/GPUCache",
                home + "/Library/Application Support/Code/CachedData",
                home + "/Library/Application Support/Code/logs",
                home + "/Library/Application Support/Code/CachedExtensionVSIXs",
                home + "/Library/Application Support/Cursor/Cache",
                home + "/Library/Application Support/Cursor/Code Cache",
                home + "/Library/Application Support/Cursor/GPUCache",
                home + "/Library/Application Support/Cursor/CachedData",
                home + "/Library/Application Support/Cursor/logs",
                home + "/Library/Application Support/Cursor/CachedExtensionVSIXs",
                // Electron AI clients. Keep this list at cache leaves rather
                // than app-support parents: preferences, credentials,
                // extensions and project state are durable user data.
                home + "/Library/Application Support/Antigravity/Cache",
                home + "/Library/Application Support/Antigravity/Code Cache",
                home + "/Library/Application Support/Antigravity/GPUCache",
                home + "/Library/Application Support/Antigravity/DawnGraphiteCache",
                home + "/Library/Application Support/Antigravity/DawnWebGPUCache",
                home + "/Library/Application Support/Filo/production/Cache",
                home + "/Library/Application Support/Filo/production/Code Cache",
                home + "/Library/Application Support/Filo/production/GPUCache",
                home + "/Library/Application Support/Filo/production/DawnGraphiteCache",
                home + "/Library/Application Support/Filo/production/DawnWebGPUCache",
                home + "/Library/Application Support/Claude/Cache",
                home + "/Library/Application Support/Claude/Code Cache",
                home + "/Library/Application Support/Claude/GPUCache",
                home + "/Library/Application Support/Claude/DawnGraphiteCache",
                home + "/Library/Application Support/Claude/DawnWebGPUCache",
                home + "/Library/Application Support/Claude/sentry",
                home + "/Library/Application Support/Qoder/Cache",
                home + "/Library/Application Support/Qoder/CachedData",
                home + "/Library/Application Support/Qoder/CachedExtensionVSIXs",
                home + "/Library/Application Support/Qoder/Code Cache",
                home + "/Library/Application Support/Qoder/GPUCache",
                home + "/Library/Application Support/Qoder/DawnGraphiteCache",
                home + "/Library/Application Support/Qoder/DawnWebGPUCache",
                home + "/Library/Application Support/Qoder/logs",
                home + "/.cache/prisma",
                // OpenCode keeps durable project/session state under
                // ~/.local/share/opencode/project; only its XDG cache root is
                // included here.
                home + "/.cache/opencode",
                home + "/Library/Caches/ms-playwright",
                home + "/Library/Caches/Cypress",
                home + "/.cache/puppeteer",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/Cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/Code Cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/GPUCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnGraphiteCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnWebGPUCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/DawnCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/GrShaderCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/GraphiteDawnCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/GraphiteDawnCache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/component_crx_cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/extensions_crx_cache",
                home + "/.cache/chrome-devtools-mcp/chrome-profile/Default/Service Worker/CacheStorage",
                home + "/Library/Caches/electron",
                home + "/Library/Caches/electron-builder"
        ]
    }

    static func xcode(kind: String,
                      path: String,
                      homeDirectory: String = NSHomeDirectory()) -> CleanupPolicyDescriptor {
        let normalizedKind = kind.lowercased()
        let source: CleanupSource = normalizedKind == "keep" ? .xcodeArchive : .xcodeCache
        guard (path as NSString).isAbsolutePath else {
            return protectedUnknown(source: source)
        }
        let normalized = normalize(path)
        let home = normalize(homeDirectory)
        let archiveRoot = home + "/Library/Developer/Xcode/Archives"
        if normalizedKind == "keep" || normalized == archiveRoot ||
            isStrictDescendant(normalized, of: archiveRoot) {
            return protectedDescriptor(source: .xcodeArchive, reasonKey: "cleanup.risk.archive")
        }
        if isProtectedContent(normalized, homeDirectory: homeDirectory) {
            return protectedDescriptor(source: .xcodeCache,
                                       reasonKey: "cleanup.risk.protectedContent")
        }
        let simulatorCacheRoot = home + "/Library/Developer/CoreSimulator/Caches"
        let safeRoots = [
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/Xcode/SourcePackages",
            home + "/Library/Caches/com.apple.dt.Xcode",
            simulatorCacheRoot
        ]
        if safeRoots.contains(where: {
            normalized == $0 || isStrictDescendant(normalized, of: $0)
        }) {
            let guardKind: CleanupActivityGuard =
                normalized == simulatorCacheRoot || isStrictDescendant(normalized, of: simulatorCacheRoot)
                ? .simulator : .xcode
            return .init(source: .xcodeCache, risk: .safe, disposal: .trash,
                         applyRoute: .xcodeTrash, activityGuard: guardKind,
                         reasonKey: "cleanup.risk.rebuildableDeveloperCache")
        }
        return warningDescriptor(source: .xcodeCache, route: .xcodeTrash,
                                 reasonKey: "cleanup.risk.deviceSupport")
    }

    // MARK: - 缓存地图（macOS 应用缓存知识库）
    //
    // 每条规则来自实际清理审计：是什么、能否重建、删除前提、连带禁区。
    // 地图上没有的路径保持默认 Warning——查清楚之前不动。

    /// Chromium 系浏览器的 profile 根（Application Support 下相对路径）。
    /// ChromeDebug 是自动化调试用独立 user-data-dir，整个目录可重建。
    private static let browserProfileRelativeRoots = [
        "Google/Chrome",
        "Google/ChromeDebug",
        "Microsoft Edge",
        "BraveSoftware/Brave-Browser",
        "Arc/User Data"
    ]

    /// 浏览器 profile 内的持久用户数据：登录态、站点数据库、偏好、书签。
    /// 与 Service Worker 同级共存，误删等于丢登录态。
    private static let durableBrowserComponents: Set<String> = [
        "indexeddb", "local storage", "login data", "login data for account",
        "cookies", "cookies-journal", "preferences", "secure preferences",
        "bookmarks", "bookmarks.bak", "web data", "sessions", "databases"
    ]

    private static let telegramGroupRootName = "6N38VWS5BX.ru.keepcoder.Telegram"
    private static let larkShellRelativeRoot = "LarkShell"

    /// 缓存地图裁决：命中返回描述符，未命中返回 nil 走通用规则。
    /// 顺序即优先级：禁区先于可清项。
    static func appCacheKnowledgeDescriptor(_ path: String, home: String) -> CleanupPolicyDescriptor? {
        let appSupport = home + "/Library/Application Support/"
        let groupContainers = home + "/Library/Group Containers/"

        // --- Telegram：只有 account-*/postbox/media 是可再生媒体缓存。
        // postbox/db 是本地消息数据库，其余目录同样是聊天数据。
        let telegramPrefix = groupContainers + telegramGroupRootName + "/"
        if path == groupContainers + telegramGroupRootName
            || path.hasPrefix(telegramPrefix) {
            let components = path == groupContainers + telegramGroupRootName
                ? [] : splitComponents(String(path.dropFirst(telegramPrefix.count)))
            if components.count == 3,
               components[0].hasPrefix("account-"),
               components[1] == "postbox",
               components[2] == "media" {
                return .init(source: .core, risk: .safe, disposal: .trash,
                              applyRoute: .genericTrash, activityGuard: .messenger,
                              reasonKey: "cleanup.risk.messengerCache")
            }
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.durableIMData")
        }

        // --- 飞书：只认 aha/users/<id>/profile_explorer（文档预览缓存）。
        // sdk_storage/database 是消息数据，profile_main 里有登录态。
        let larkPrefix = appSupport + larkShellRelativeRoot + "/"
        if path == appSupport + larkShellRelativeRoot || path.hasPrefix(larkPrefix) {
            let components = path == appSupport + larkShellRelativeRoot
                ? [] : splitComponents(String(path.dropFirst(larkPrefix.count)))
            if components.count == 4,
               components[0] == "aha",
               components[1] == "users",
               components[3] == "profile_explorer" {
                return .init(source: .core, risk: .safe, disposal: .trash,
                              applyRoute: .genericTrash, activityGuard: .messenger,
                              reasonKey: "cleanup.risk.messengerCache")
            }
            return protectedDescriptor(source: .core, reasonKey: "cleanup.risk.durableIMData")
        }

        // --- Chromium 系浏览器 profile。
        for relative in browserProfileRelativeRoots {
            let root = appSupport + relative
            guard path == root || isStrictDescendant(path, of: root) else { continue }
            let components = splitComponents(String(path.dropFirst(appSupport.count)))
            // 调试用独立 profile 整体可再生（下次调试启动自动重建）。
            if relative == "Google/ChromeDebug" {
                return .init(source: .core, risk: .safe, disposal: .trash,
                              applyRoute: .genericTrash, activityGuard: .browser,
                              reasonKey: "cleanup.risk.rebuildableCache")
            }
            // 持久用户数据（IndexedDB/Login Data/Cookies/Preferences…）。
            if components.dropFirst().contains(where: {
                durableBrowserComponents.contains($0)
            }) {
                return protectedDescriptor(source: .core,
                                           reasonKey: "cleanup.risk.durableIMData")
            }
            // Service Worker 目录整体可再生（含 ScriptCache/CacheStorage）。
            if components.dropFirst().contains("service worker") {
                return .init(source: .core, risk: .safe, disposal: .trash,
                              applyRoute: .genericTrash, activityGuard: .browser,
                              reasonKey: "cleanup.risk.rebuildableCache")
            }
            // 其余部分（Cache/Code Cache 等）交给通用 Application Support
            // 缓存叶子规则裁决。
            return nil
        }
        return nil
    }

    private static func splitComponents(_ value: String) -> [String] {
        value.split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
    }

    static func system() -> CleanupPolicyDescriptor {
        .init(source: .system, risk: .warning, disposal: .privileged,
              applyRoute: .systemPrivileged, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.system")
    }

    static func tool() -> CleanupPolicyDescriptor {
        .init(source: .tool, risk: .warning, disposal: .command,
              applyRoute: .toolCommand, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.ownerCommand")
    }

    static func slim() -> CleanupPolicyDescriptor {
        .init(source: .slim, risk: .warning, disposal: .transform,
              applyRoute: .imageTransform, activityGuard: .unsupported,
              reasonKey: "cleanup.risk.transform")
    }

    /// 应用执行前使用新快照重判。风险只会保持或升高，不会在旧扫描上降级。
    static func reassess(_ category: CleanupCategory,
                         running snapshot: RunningApplicationSnapshot,
                         homeDirectory: String = NSHomeDirectory()) -> CleanupRiskAssessment {
        guard category.risk == .safe else {
            return .init(risk: category.risk, reasonKey: category.reasonKey)
        }
        guard category.activityGuard != .unsupported else {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runtimeUnsupported")
        }
        guard category.activityGuard != .none else {
            return .init(risk: .safe, reasonKey: category.reasonKey)
        }
        guard snapshot.isComplete else {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runtimeUnknown")
        }
        if ownerIsRunning(for: category, snapshot: snapshot, homeDirectory: homeDirectory) {
            return .init(risk: .protected, reasonKey: "cleanup.risk.runningApplication")
        }
        return .init(risk: .safe, reasonKey: category.reasonKey)
    }

    /// 运行态保护按路径裁剪。分类和总容量始终保留在结果中；当前运行的
    /// 应用只会清空对应选择，避免把数 GB 的缓存从页面中隐藏。
    static func runtimeEligibleSubset(
        _ category: CleanupCategory,
        running snapshot: RunningApplicationSnapshot,
        homeDirectory: String = NSHomeDirectory()
    ) -> CleanupCategory? {
        guard category.risk == .safe else { return category }
        switch category.activityGuard {
        case .none, .openFile, .packageManager:
            // `.packageManager` is retained for decoding older cached
            // snapshots.  New scans use `.openFile`; treating the legacy
            // value the same way prevents a generic runtime process from
            // hiding every developer cache.  The apply bridge remains the
            // authoritative open-file check.
            return category
        case .unsupported:
            return nil
        case .reverseDNSCache:
            guard snapshot.isComplete else { return category.clearingSelection() }
            let selectable = category.paths.filter { path in
                pathOwnerRunning(path, snapshot: snapshot,
                                 homeDirectory: homeDirectory) == false
            }
            return category.selectingPaths(selectable)
        case .browser, .xcode, .simulator, .ide, .messenger:
            guard snapshot.isComplete else { return category.clearingSelection() }
            guard !ownerIsRunning(for: category, snapshot: snapshot,
                                  homeDirectory: homeDirectory) else {
                return category.clearingSelection()
            }
            return category
        }
    }

    static func isEligible(_ category: CleanupCategory,
                           mode: CleanupExecutionMode,
                           running snapshot: RunningApplicationSnapshot,
                           homeDirectory: String = NSHomeDirectory()) -> Bool {
        let assessment = reassess(category, running: snapshot, homeDirectory: homeDirectory)
        switch mode {
        case .manual:
            switch category.disposal {
            case .trash:
                return assessment.risk == .safe
            case .command, .privileged, .transform:
                return assessment.risk != .protected
            case .none:
                return false
            }
        case .quickClean, .automatic:
            return assessment.risk == .safe && category.disposal == .trash
        }
    }

    /// 自动目录不得与模型、用户会话、Docker 数据或系统根目录重叠。
    static func isForbiddenAutomationPath(_ path: String,
                                          homeDirectory: String = NSHomeDirectory()) -> Bool {
        guard (path as NSString).isAbsolutePath else { return true }
        let normalized = normalize(path)
        let protectedRoots = protectedContentRoots(homeDirectory: homeDirectory) + protectedAbsoluteRoots
        return protectedRoots.contains { pathsOverlap(normalized, normalize($0)) }
    }

    /// Sensitive content is protected by structure wherever it appears, not
    /// only at its conventional location under the current home directory.
    static func isSensitiveAutomationPath(_ rawPath: String) -> Bool {
        let path = normalize(rawPath)
        let lower = path.lowercased()
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        let sensitiveComponents: Set<String> = [
            ".git", "models", "sessions", "conversations", "userdata",
            "user data", "docker", "vms"
        ]
        if components.contains(where: sensitiveComponents.contains) { return true }
        let protectedFragments = [
            "/.codex/sessions", "/.codex/log", "/.codex/auth.json",
            "/.codex/history.jsonl", "/.claude/projects", "/.claude/todos",
            "/.claude/shell-snapshots", "/.gemini/",
            "/.local/share/opencode/project",
            "/library/application support/codex", "/.ollama/models",
            "/.cache/huggingface", "/.cache/lm-studio/models", "/.cache/torch",
            "/library/containers/com.docker", "/library/group containers/group.com.docker",
            "/.docker/contexts", "/.docker/config.json"
        ]
        if protectedFragments.contains(where: {
            lower == String($0.dropLast($0.hasSuffix("/") ? 1 : 0)) || lower.contains($0)
        }) {
            return true
        }
        let leaf = URL(fileURLWithPath: lower).lastPathComponent
        if ["pytorch_model.bin", "adapter_model.bin", "model.bin"].contains(leaf) {
            return true
        }
        let protectedExtensions = [
            "gguf", "safetensors", "ckpt", "mlmodel", "mlmodelc",
            "pt", "pth", "onnx", "tflite"
        ]
        return protectedExtensions.contains(URL(fileURLWithPath: lower).pathExtension)
    }

    private static func ownerIsRunning(for category: CleanupCategory,
                                       snapshot: RunningApplicationSnapshot,
                                       homeDirectory: String) -> Bool {
        switch category.activityGuard {
        case .none, .openFile, .unsupported:
            return false
        case .reverseDNSCache:
            // A runtime-filtered category may keep protected siblings visible
            // while selecting only idle paths. Reassess the submitted subset,
            // not every path that remains on screen.
            let pathsToCheck = category.paths.filter(category.isPathSelected)
            return pathsToCheck.contains { path in
                pathOwnerRunning(path, snapshot: snapshot,
                                 homeDirectory: homeDirectory) != false
            }
        case .browser:
            return snapshotMatches(snapshot,
                                   bundles: ["com.google.Chrome", "org.mozilla.firefox",
                                             "com.microsoft.edgemac", "company.thebrowser.Browser",
                                             "com.brave.Browser"],
                                   processes: ["Google Chrome", "Firefox", "Microsoft Edge",
                                               "Arc", "Brave Browser"])
        case .messenger:
            // Telegram / 飞书 / 微信运行期间，其媒体与文档缓存一律保护：
            // 边写边删既损坏缓存，也可能干扰消息库。
            return snapshotMatches(snapshot,
                                   bundles: ["ru.keepcoder.Telegram", "com.electron.lark",
                                             "com.ss.lark", "com.tencent.xinWeChat"],
                                   processes: ["Telegram", "Lark", "LarkHelper", "Feishu",
                                               "飞书", "WeChat", "微信"])
        case .xcode:
            return snapshotMatches(snapshot, bundles: ["com.apple.dt.Xcode"],
                                   processes: ["Xcode", "xcodebuild", "swift-frontend", "SourceKitService"])
        case .simulator:
            return snapshotMatches(snapshot, bundles: ["com.apple.iphonesimulator"],
                                   processes: ["Simulator", "CoreSimulatorService", "simctl"])
        case .packageManager:
            // Legacy cached categories used this guard.  Do not infer cache
            // ownership from a generic runtime process; the final bridge
            // checks whether the selected subtree is actually open.
            return false
        case .ide:
            return snapshotMatches(snapshot,
                                   bundles: ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"],
                                   processes: ["Code", "Cursor", "Electron", "Antigravity",
                                               "Filo", "Claude", "Qoder"])
        }
    }

    private static func snapshotMatches(_ snapshot: RunningApplicationSnapshot,
                                        bundles: [String],
                                        processes: [String]) -> Bool {
        bundles.contains(where: snapshot.contains(bundleIdentifier:)) ||
            processes.contains(where: snapshot.contains(processName:))
    }

    private static func pathOwnerRunning(
        _ path: String,
        snapshot: RunningApplicationSnapshot,
        homeDirectory: String
    ) -> Bool? {
        guard let owner = cacheOwner(for: normalize(path), home: normalize(homeDirectory)) else {
            return nil
        }
        let leaf = owner.split(separator: ".").last.map(String.init) ?? owner
        return snapshot.contains(bundleIdentifier: owner) || snapshot.contains(processName: leaf)
    }

    static func isProtectedContent(_ path: String, homeDirectory: String) -> Bool {
        if protectedAbsoluteRoots.contains(where: { path == $0 || isStrictDescendant(path, of: $0) }) {
            return true
        }
        return protectedContentRoots(homeDirectory: homeDirectory).contains {
            path == $0 || isStrictDescendant(path, of: $0)
        }
    }

    private static func protectedContentRoots(homeDirectory: String) -> [String] {
        let home = normalize(homeDirectory)
        return [
            home + "/.codex/sessions",
            home + "/.codex/log",
            home + "/.claude/projects",
            home + "/.claude/shell-snapshots",
            home + "/.claude/todos",
            home + "/.local/share/opencode/project",
            home + "/.gemini/tmp",
            home + "/.ollama/models",
            home + "/.cache/huggingface",
            home + "/.cache/lm-studio/models",
            home + "/.cache/torch",
            home + "/Library/Application Support/Codex",
            home + "/Library/Containers/com.docker.docker",
            home + "/Library/Group Containers/group.com.docker",
            home + "/.docker",
            // 缓存地图禁止清单：钥匙串任何情况下都不动。
            home + "/Library/Keychains"
        ]
    }

    private static func developerCacheRoots(home: String) -> [String] {
        [
            home + "/.npm/_cacache",
            home + "/.npm/_logs",
            home + "/.swiftpm/cache",
            home + "/.cache/node/corepack",
            home + "/Library/Caches/org.carthage.CarthageKit",
            home + "/.bun/install/cache",
            home + "/Library/Caches/pnpm",
            home + "/.yarn/cache",
            home + "/Library/Caches/Yarn",
            home + "/.m2/repository",
            home + "/.gradle/caches",
            home + "/.gradle/daemon",
            home + "/Library/Caches/go-build",
            home + "/go/pkg/mod",
            home + "/.cargo/registry/cache",
            home + "/.cargo/git/db",
            home + "/.nuget/packages",
            home + "/Library/Caches/NuGet",
            home + "/Library/Caches/pip",
            home + "/.cache/pip",
            home + "/Library/Caches/pypoetry",
            home + "/.cache/uv",
            home + "/.composer/cache",
            home + "/Library/Caches/composer",
            home + "/.pub-cache",
            home + "/.cache/bazel",
            home + "/.cache/zig",
            home + "/Library/Caches/org.swift.swiftpm",
            home + "/Library/Caches/Homebrew/downloads",
            home + "/Library/Caches/node-gyp",
            home + "/Library/Caches/typescript",
            home + "/.hex/cache",
            home + "/.tnpm/_cacache",
            home + "/.tnpm/_logs",
            home + "/.cache/poetry",
            home + "/.cache/ruff",
            home + "/.cache/mypy",
            home + "/.pytest_cache",
            home + "/.jupyter/runtime",
            home + "/.rbenv/cache",
            home + "/.gem/specs",
            home + "/.bundle/cache",
            home + "/.cpan/build",
            home + "/.kube/cache",
            home + "/.aws/cli/cache",
            home + "/.config/gcloud/logs",
            home + "/.azure/logs",
            home + "/.cache/typescript",
            home + "/.cache/electron",
            home + "/.cache/node-gyp",
            home + "/.node-gyp",
            home + "/.turbo/cache",
            home + "/.vite/cache",
            home + "/.cache/vite",
            home + "/.cache/webpack",
            home + "/.parcel-cache",
            home + "/.cache/eslint",
            home + "/.cache/prettier",
            home + "/.android/build-cache",
            home + "/.android/cache",
            home + "/.cache/swift-package-manager",
            home + "/.expo/expo-go",
            home + "/.expo/android-apk-cache",
            home + "/.expo/ios-simulator-app-cache",
            home + "/.expo/native-modules-cache",
            home + "/.expo/schema-cache",
            home + "/.expo/template-cache",
            home + "/.expo/versions-cache",
            home + "/Library/Logs/JetBrains"
        ]
    }

    private static func isExplicitDeveloperCachePath(_ path: String, home: String) -> Bool {
        developerCacheRoots(home: home).contains {
            path == $0 || isStrictDescendant(path, of: $0)
        }
    }

    private static func isExplicitXcodeCachePath(_ path: String, home: String) -> Bool {
        let roots = [
            home + "/Library/Developer/Xcode/DerivedData",
            home + "/Library/Developer/Xcode/SourcePackages",
            home + "/Library/Caches/com.apple.dt.Xcode",
            home + "/Library/Developer/CoreSimulator/Caches"
        ]
        return roots.contains { path == $0 || isStrictDescendant(path, of: $0) }
    }

    private static func cacheOwner(for path: String, home: String) -> String? {
        let directPrefix = home + "/Library/Caches/"
        if path.hasPrefix(directPrefix) {
            let remainder = String(path.dropFirst(directPrefix.count))
            let owner = remainder.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return isValidReverseDNSOwner(owner) ? owner : nil
        }
        return containerCacheOwner(path, home: home)
    }

    private static func containerCacheOwner(_ path: String, home: String) -> String? {
        let prefix = home + "/Library/Containers/"
        guard path.hasPrefix(prefix) else { return nil }
        let remainder = String(path.dropFirst(prefix.count))
        let components = remainder.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.count >= 5,
              components[1] == "Data", components[2] == "Library",
              components[3] == "Caches" || components[3] == "Logs" else { return nil }
        return components[0]
    }

    private static func isApplicationSupportCachePath(_ path: String, home: String) -> Bool {
        let prefix = home + "/Library/Application Support/"
        guard path.hasPrefix(prefix) else { return false }
        let components = String(path.dropFirst(prefix.count))
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.lowercased() }
        guard components.count >= 2 else { return false }
        let cacheComponents: Set<String> = [
            "cache", "caches", "code cache", "gpucache", "dawncache",
            "graphitedawncache", "grshadercache", "shadercache", "cacheddata",
            "cachedextensionvsixs", "blob_storage", "logs"
        ]
        if components.dropFirst().contains(where: cacheComponents.contains) { return true }
        for index in 1 ..< components.count {
            if components[index] == "cachestorage",
               components[index - 1] == "service worker" { return true }
            if components[index] == "completed",
               components[index - 1] == "crashpad" { return true }
        }
        return false
    }

    private static func isBrowserPath(_ path: String, section: String) -> Bool {
        if section.lowercased().contains("browser") { return true }
        let lower = path.lowercased()
        return lower.contains("/google/chrome/") || lower.contains("/mozilla/firefox/")
            || lower.contains("/microsoft edge/") || lower.contains("/arc/")
    }

    private static func isBrowserCacheOwner(_ owner: String) -> Bool {
        ["Google", "Mozilla", "Firefox", "Chrome", "Microsoft Edge", "Arc"]
            .contains { owner.caseInsensitiveCompare($0) == .orderedSame }
    }

    private static func warningDescriptor(source: CleanupSource,
                                          route: CleanupApplyRoute,
                                          reasonKey: String) -> CleanupPolicyDescriptor {
        .init(source: source, risk: .warning, disposal: .trash,
              applyRoute: route, activityGuard: .unsupported, reasonKey: reasonKey)
    }

    private static func protectedDescriptor(source: CleanupSource,
                                            reasonKey: String) -> CleanupPolicyDescriptor {
        .init(source: source, risk: .protected, disposal: .none,
              applyRoute: .none, activityGuard: .unsupported, reasonKey: reasonKey)
    }

    private static func protectedUnknown(source: CleanupSource) -> CleanupPolicyDescriptor {
        protectedDescriptor(source: source, reasonKey: "cleanup.risk.invalidPath")
    }

    private static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// Keep the same intentionally narrow ASCII grammar as the final shell
    /// guard. A dotted but malformed cache owner is Warning, never Safe.
    private static func isValidReverseDNSOwner(_ owner: String) -> Bool {
        guard owner.contains("."),
              !owner.hasPrefix("."),
              !owner.hasSuffix("."),
              !owner.contains("..") else { return false }
        return owner.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func isStrictDescendant(_ path: String, of root: String) -> Bool {
        path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func isDirectChild(_ path: String, of root: String) -> Bool {
        guard isStrictDescendant(path, of: root) else { return false }
        let remainder = path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1)
        return !remainder.isEmpty && !remainder.contains("/")
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || isStrictDescendant(lhs, of: rhs) || isStrictDescendant(rhs, of: lhs)
    }
}
