import Foundation

private struct RiskTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct CleanupRiskPolicyTests {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw RiskTestFailure(description: "missing fixture root")
        }
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
        let policyHome = "/Users/simplemole-risk-test"
        try testDefaults()
        try testCoreClassification(home: policyHome)
        try testSourceMappings(home: policyHome)
        try testRuntimeReassessment(home: policyHome)
        try testRecommendedTrash(fixture: fixture)
        try testPathSelection()
        try testAnalyzeEntrySafety()
        try testAnalyzeAIItems()
        try testDevEnvRelatedPackages()
        try testAutomationProtection(home: policyHome)
        try testCacheRoundTrip(fixture: fixture)
        try testSystemDataParsing()
    }

    private static func expect(_ condition: @autoclosure () -> Bool,
                               _ message: String) throws {
        guard condition() else { throw RiskTestFailure(description: message) }
    }

    private static func testDefaults() throws {
        let unknown = CleanupCategory(name: "Unknown", paths: ["/tmp/item"], bytes: 1)
        try expect(unknown.risk == .warning, "unknown category was not Warning")
        try expect(!unknown.selected, "unknown category was selected by default")

        let protected = CleanupCategory(name: "Protected", paths: ["/tmp/item"], bytes: 1,
                                        selected: true, risk: .protected)
        try expect(!protected.selected && !protected.canSelect,
                   "Protected category accepted its requested default selection")
    }

    private static func testCoreClassification(home: String) throws {
        let safePath = home + "/Library/Caches/com.example.tool/cache.db"
        let warningPath = home + "/Library/Preferences/com.example.tool.plist"
        let diagnosticPath = home + "/Library/DiagnosticReports/Tool.crash"
        let sessionPath = home + "/.codex/sessions/2026/session.jsonl"
        let safe = CleanupRiskPolicy.core(section: "User essentials", path: safePath,
                                          homeDirectory: home)
        let warning = CleanupRiskPolicy.core(section: "User essentials", path: warningPath,
                                             homeDirectory: home)
        let diagnostic = CleanupRiskPolicy.core(section: "Diagnostic reports", path: diagnosticPath,
                                                homeDirectory: home)
        let protected = CleanupRiskPolicy.core(section: "Developer tools", path: sessionPath,
                                               homeDirectory: home)
        try expect(safe.risk == .safe && safe.activityGuard == .reverseDNSCache,
                   "explicit reverse-DNS cache was not Safe")
        try expect(warning.risk == .warning, "unknown preference was not Warning")
        try expect(diagnostic.risk == .safe && diagnostic.activityGuard == .openFile,
                   "diagnostic report was not admitted through the open-file guard")
        try expect(protected.risk == .protected, "Codex session was not Protected")

        let genericCache = CleanupRiskPolicy.core(
            section: "User essentials", path: home + "/Library/Caches/Yarn/archive",
            homeDirectory: home)
        let containerCache = CleanupRiskPolicy.core(
            section: "App caches",
            path: home + "/Library/Containers/com.example.tool/Data/Library/Caches/cache.db",
            homeDirectory: home)
        let supportCache = CleanupRiskPolicy.core(
            section: "Application Support",
            path: home + "/Library/Application Support/Example/Code Cache/js/index",
            homeDirectory: home)
        let loginData = CleanupRiskPolicy.core(
            section: "Browsers",
            path: home + "/Library/Application Support/Google/Chrome/Default/Login Data",
            homeDirectory: home)
        try expect(genericCache.risk == .safe,
                   "macOS cache root was not admitted as rebuildable")
        try expect(containerCache.risk == .safe &&
                   containerCache.activityGuard == .reverseDNSCache,
                   "container-owned cache did not retain its Bundle guard")
        try expect(supportCache.risk == .safe && supportCache.activityGuard == .openFile,
                   "explicit Application Support cache subtree was not Safe")
        try expect(loginData.risk == .warning,
                   "browser login database was incorrectly marked Safe")

        let parserHome = NSHomeDirectory()
        let parserSafePath = parserHome + "/Library/Caches/com.example.tool/cache.db"
        let parserWarningPath = parserHome + "/Library/Preferences/com.example.tool.plist"
        let preview = """
        === User essentials ===
        \(parserSafePath)  # 2 MB
        \(parserWarningPath)  # 1 KB
        """
        let categories = Parsers.previewCategories(preview)
        try expect(categories.count == 2, "mixed core section was not split by risk")
        try expect(Set(categories.map(\.risk)) == Set([.safe, .warning]),
                   "split core section lost risk values")
        try expect(categories.first(where: { $0.risk == .safe })?.selected == true,
                   "Safe core category was not selected by default")
        try expect(categories.first(where: { $0.risk == .warning })?.selected == false,
                   "Warning core category was selected by default")
    }

    private static func testSourceMappings(home: String) throws {
        let installerPath = home + "/Downloads/Tool.dmg"
        let rawInstaller = "12\tInstaller\t\(installerPath)"
        let installer = try unwrap(Parsers.installerCategory(rawInstaller), "installer category")
        try expect(installer.source == .installer && installer.risk == .warning &&
                   installer.disposal == .trash && installer.applyRoute == .installerTrash,
                   "installer mapping is not Warning/Trash/installer route")

        let leftoverPath = home + "/Library/Application Support/GhostApp"
        let leftover = try unwrap(
            Parsers.orphanedAppCategories("4096\tGhostApp\tcom.example.ghost\t\(leftoverPath)").first,
            "app leftover category")
        try expect(leftover.source == .appLeftover && leftover.risk == .warning &&
                   leftover.disposal == .trash && leftover.applyRoute == .genericTrash &&
                   leftover.selected == false,
                   "app leftovers were not manual-only Warning/Trash")
        let leftoverCache = CleanupRiskPolicy.appLeftover(
            path: home + "/Library/Caches/com.example.ghost",
            bundleIdentifier: "com.example.ghost", homeDirectory: home)
        try expect(leftoverCache.risk == .safe && leftoverCache.source == .appLeftover &&
                   leftoverCache.applyRoute == .genericTrash,
                   "exact bundle-owned orphan cache was not Safe")
        let leftoverSupportCache = CleanupRiskPolicy.appLeftover(
            path: home + "/Library/Application Support/GhostApp/Code Cache",
            bundleIdentifier: "com.example.ghost", homeDirectory: home)
        try expect(leftoverSupportCache.risk == .safe &&
                   leftoverSupportCache.activityGuard == .openFile,
                   "rebuildable Application Support cache was not Safe")
        for userStatePath in [
            home + "/Library/HTTPStorages/com.example.ghost.binarycookies",
            home + "/Library/Saved Application State/com.example.ghost.savedState"
        ] {
            try expect(CleanupRiskPolicy.appLeftover(
                path: userStatePath, bundleIdentifier: "com.example.ghost",
                homeDirectory: home).risk == .warning,
                "orphan login/session state was incorrectly marked Safe")
        }

        let projectPath = home + "/Code/App/node_modules"
        let project = try unwrap(Parsers.specialCategories("42\t\(projectPath)", family: .purge).first,
                                 "project category")
        try expect(project.source == .projectArtifact && project.risk == .warning &&
                   project.applyRoute == .projectArtifactTrash,
                   "project mapping is not Warning/project route")

        let npmPath = NSHomeDirectory() + "/.npm"
        let developer = try unwrap(
            Parsers.specialCategories("42\tnpm cache\t\(npmPath)", family: .dev).first,
            "developer category")
        try expect(developer.source == .developerCache && developer.risk == .safe &&
                   developer.activityGuard == .openFile &&
                   developer.applyRoute == .developerCacheTrash,
                   "explicit developer cache did not receive its guarded Safe route")

        let session = try unwrap(
            Parsers.specialCategories("1\tsession\tCodex sessions\t\(home)/.codex/sessions",
                                      family: .ai).first, "AI session")
        let model = try unwrap(
            Parsers.specialCategories("1\tmodel\tModels\t\(home)/.ollama/models",
                                      family: .ai).first, "AI model")
        let geminiTemp = CleanupRiskPolicy.ai(
            kind: "cache", path: home + "/.gemini/tmp", homeDirectory: home)
        let codexCache = CleanupRiskPolicy.ai(
            kind: "cache", path: home + "/Library/Caches/Codex/Default/Cache",
            homeDirectory: home)
        let codexProfile = CleanupRiskPolicy.ai(
            kind: "cache", path: home + "/Library/Caches/Codex", homeDirectory: home)
        try expect(session.source == .aiSession && session.risk == .warning && !session.selected,
                   "AI session was not manual-only Warning")
        try expect(model.source == .aiModel && model.risk == .protected &&
                   model.disposal == .none && !model.selected,
                   "AI model was not Protected")
        try expect(geminiTemp.risk == .protected && geminiTemp.disposal == .none,
                   "Gemini temporary state disagrees with the protected-content boundary")
        try expect(codexCache.source == .aiCache && codexCache.risk == .safe &&
                   codexCache.applyRoute == .aiTrash,
                   "Codex desktop cache did not receive the guarded Safe route")
        try expect(codexProfile.risk == .warning && codexProfile.disposal == .trash,
                   "Codex profile parent was incorrectly made blanket-cleanable")

        // Electron AI clients expose only their rebuildable Chromium leaves to
        // the automatic route.  Keep each app-support parent review-only so a
        // catalog typo cannot turn settings or credentials into a delete.
        let aiCacheLeaves = [
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
            home + "/.cache/opencode"
        ]
        for path in aiCacheLeaves {
            let descriptor = CleanupRiskPolicy.ai(kind: "cache", path: path,
                                                  homeDirectory: home)
            try expect(descriptor.source == .aiCache && descriptor.risk == .safe &&
                       descriptor.applyRoute == .aiTrash,
                       "AI cache leaf was not admitted through the guarded Safe route: \(path)")
        }
        for parent in [
            home + "/Library/Application Support/Antigravity",
            home + "/Library/Application Support/Filo",
            home + "/Library/Application Support/Claude",
            home + "/Library/Application Support/Qoder"
        ] {
            try expect(CleanupRiskPolicy.ai(kind: "cache", path: parent,
                                            homeDirectory: home).risk == .warning,
                       "AI app-support parent was incorrectly made blanket-cleanable: \(parent)")
        }

        let xcodeHome = NSHomeDirectory()
        let derived = try unwrap(
            Parsers.specialCategories("1\tclean\tDerivedData\t\(xcodeHome)/Library/Developer/Xcode/DerivedData",
                                      family: .xcode).first, "DerivedData")
        let archive = try unwrap(
            Parsers.specialCategories("1\tkeep\tArchives\t\(xcodeHome)/Library/Developer/Xcode/Archives",
                                      family: .xcode).first, "Xcode archive")
        try expect(derived.risk == .safe && derived.activityGuard == .xcode &&
                   derived.applyRoute == .xcodeTrash,
                   "DerivedData was not guarded Safe")
        try expect(archive.source == .xcodeArchive && archive.risk == .protected &&
                   archive.applyRoute == .none,
                   "Xcode Archives were not Protected")

        let systemPreview = "=== System ===\n/Library/Logs/example.log  # 1 KB\n"
        let system = try unwrap(
            Parsers.filteredPreviewCategories(systemPreview, allowedPrefixes: ["/Library/Logs/"]).first,
            "system category")
        try expect(system.risk == .warning && system.disposal == .privileged &&
                   system.applyRoute == .systemPrivileged,
                   "system mapping is not Warning/privileged")

        try expect(CleanupRiskPolicy.developerCache(path: "relative/cache",
                                                    homeDirectory: home).risk == .protected,
                   "relative developer path did not fail closed")
        try expect(CleanupRiskPolicy.ai(kind: "session", path: "relative/session",
                                        homeDirectory: home).risk == .protected,
                   "relative AI path did not fail closed")
        try expect(CleanupRiskPolicy.xcode(kind: "clean",
                                           path: "relative/DerivedData").risk == .protected,
                   "relative Xcode path did not fail closed")
        try expect(CleanupRiskPolicy.xcode(kind: "clean", path: "/tmp/DerivedData",
                                           homeDirectory: home).risk == .warning,
                   "lookalike Xcode cache outside its exact root was marked Safe")
    }

    private static func testRuntimeReassessment(home: String) throws {
        let path = home + "/Library/Caches/com.example.tool/data"
        let policy = CleanupRiskPolicy.core(section: "App caches", path: path,
                                            homeDirectory: home)
        let category = CleanupCategory(name: "Cache", paths: [path], bytes: 1,
                                       source: policy.source, risk: policy.risk,
                                       disposal: policy.disposal, applyRoute: policy.applyRoute,
                                       activityGuard: policy.activityGuard, reasonKey: policy.reasonKey)
        let idle = RunningApplicationSnapshot(bundleIdentifiers: [], processNames: [])
        let running = RunningApplicationSnapshot(bundleIdentifiers: ["com.example.tool"])
        try expect(CleanupRiskPolicy.reassess(category, running: idle,
                                              homeDirectory: home).risk == .safe,
                   "idle guarded cache did not remain Safe")
        try expect(CleanupRiskPolicy.reassess(category, running: running,
                                              homeDirectory: home).risk == .protected,
                   "running cache owner was not Protected")
        try expect(CleanupRiskPolicy.reassess(category, running: .unavailable,
                                              homeDirectory: home).risk == .protected,
                   "unknown process state did not fail closed")
        try expect(CleanupRiskPolicy.isEligible(category, mode: .quickClean, running: idle,
                                                homeDirectory: home),
                   "Safe Trash category was rejected by Quick Clean")

        let idlePath = home + "/Library/Caches/com.example.idle/data"
        let mixed = CleanupCategory(
            name: "App caches", paths: [path, idlePath], bytes: 3,
            pathBytes: [path: 1, idlePath: 2], source: .core, risk: .safe,
            disposal: .trash, applyRoute: .genericTrash,
            activityGuard: .reverseDNSCache,
            reasonKey: "cleanup.risk.rebuildableCache")
        let mixedSubset = try unwrap(CleanupRiskPolicy.runtimeEligibleSubset(
            mixed, running: running, homeDirectory: home), "mixed runtime subset")
        try expect(mixedSubset.paths == [path, idlePath] && mixedSubset.bytes == 3 &&
                   mixedSubset.selectedPathCount == 1 &&
                   mixedSubset.isPathSelected(idlePath),
                   "one running app suppressed unrelated cache selection")
        try expect(CleanupRiskPolicy.isEligible(mixedSubset, mode: .quickClean,
                                                running: running, homeDirectory: home),
                   "idle subset was rejected because a visible sibling is running")
        let unknownSubset = try unwrap(CleanupRiskPolicy.runtimeEligibleSubset(
            mixed, running: .unavailable, homeDirectory: home), "incomplete runtime subset")
        try expect(unknownSubset.paths == mixed.paths && !unknownSubset.selected,
                   "incomplete runtime inventory did not clear selection while preserving totals")

        let browser = CleanupCategory(
            name: "Browsers", paths: [home + "/Library/Caches/Google/Chrome"], bytes: 5,
            source: .core, risk: .safe, disposal: .trash, applyRoute: .genericTrash,
            activityGuard: .browser, reasonKey: "cleanup.risk.rebuildableCache")
        let browserRunning = try unwrap(CleanupRiskPolicy.runtimeEligibleSubset(
            browser, running: RunningApplicationSnapshot(processNames: ["Google Chrome"]),
            homeDirectory: home), "running browser subset")
        try expect(browserRunning.paths == browser.paths && !browserRunning.selected,
                   "running browser cache disappeared instead of staying visible")

        let warning = CleanupCategory(name: "Installer", paths: [home + "/Downloads/a.dmg"], bytes: 1,
                                      source: .installer, risk: .warning, disposal: .trash,
                                      applyRoute: .installerTrash, activityGuard: .unsupported,
                                      reasonKey: "cleanup.risk.installer")
        try expect(!CleanupRiskPolicy.isEligible(warning, mode: .quickClean, running: idle,
                                                 homeDirectory: home),
                   "Quick Clean accepted Warning")
        try expect(!CleanupRiskPolicy.isEligible(warning, mode: .manual, running: idle,
                                                 homeDirectory: home),
                   "manual cleanup accepted a Warning filesystem deletion")
        let command = CleanupCategory(name: "Owner command", paths: ["brew cleanup"], bytes: 1,
                                      source: .tool, risk: .warning, disposal: .command,
                                      applyRoute: .toolCommand, activityGuard: .unsupported,
                                      reasonKey: "cleanup.risk.ownerCommand")
        try expect(CleanupRiskPolicy.isEligible(command, mode: .manual, running: idle,
                                                homeDirectory: home),
                   "manual owner command was rejected with filesystem warnings")
    }

    private static func testRecommendedTrash(fixture: URL) throws {
        let home = fixture.appendingPathComponent("trash-home", isDirectory: true)
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let old = trash.appendingPathComponent("old-recording.mov")
        let recent = trash.appendingPathComponent("recent.txt")
        let oldApp = trash.appendingPathComponent("Old.app", isDirectory: true)
        try Data("old".utf8).write(to: old)
        try Data("recent".utf8).write(to: recent)
        try FileManager.default.createDirectory(at: oldApp, withIntermediateDirectories: true)

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let oldDate = now.addingTimeInterval(-45 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: oldDate],
                                              ofItemAtPath: oldApp.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-86_400)],
                                              ofItemAtPath: recent.path)

        let preview = """
        === User essentials ===
        \(old.path)  # 4 KB
        \(recent.path)  # 4 KB
        \(oldApp.path)  # 4 KB
        """
        let categories = Parsers.previewCategories(
            preview, homeDirectory: home.path, now: now, trashMinimumAgeDays: 30)
        let safe = CleanupCategory.safeCleanupCandidates(from: categories)
        try expect(safe.count == 1 &&
                   safe[0].paths == [old.standardizedFileURL.path] && safe[0].bytes > 0,
                   "recommended Trash policy did not keep only the old ordinary item: \(safe.map { ($0.name, $0.paths, $0.bytes) })")
    }

    private static func testAutomationProtection(home: String) throws {
        for path in [
            home + "/.codex/sessions",
            home + "/.claude/projects/active",
            home + "/.ollama/models",
            home + "/Library/Containers/com.docker.docker/Data"
        ] {
            try expect(CleanupRiskPolicy.isForbiddenAutomationPath(path, homeDirectory: home),
                       "automation accepted protected root: \(path)")
        }
        try expect(!CleanupRiskPolicy.isForbiddenAutomationPath(home + "/Caches/Rebuildable",
                                                                homeDirectory: home),
                   "automation rejected unrelated custom root")
        try expect(CleanupRiskPolicy.isForbiddenAutomationPath("relative/cache",
                                                               homeDirectory: home),
                   "automation accepted a relative path")
    }

    private static func testPathSelection() throws {
        let first = "/tmp/cache-a"
        let second = "/tmp/cache-b"
        var category = CleanupCategory(
            name: "Caches", paths: [first, second], bytes: 5,
            pathBytes: [first: 2, second: 3], source: .core, risk: .safe,
            disposal: .trash, applyRoute: .genericTrash, activityGuard: .none,
            reasonKey: "cleanup.risk.rebuildableCache")
        try expect(category.allSelected && category.selectedPathCount == 2 &&
                   category.selectedPathBytes == 5,
                   "Safe category did not select all child paths by default")
        try expect(category.pathsByDescendingSize == [second, first],
                   "child paths were not sorted by descending size")
        category.setPathSelected(first, selected: false)
        try expect(category.partiallySelected && category.selectedPathCount == 1 &&
                   category.selectedPathBytes == 3,
                   "child selection did not update parent count and bytes")
        let subset = try unwrap(category.selectedSubset, "selected category subset")
        try expect(subset.paths == [second] && subset.bytes == 3,
                   "cleanup subset retained an unselected child path")
        category.selected = false
        try expect(category.selectedSubset == nil && category.selectedPathCount == 0,
                   "parent deselection did not clear child selections")

        let smaller = CleanupCategory(name: "A", paths: ["/tmp/small"], bytes: 4)
        let larger = CleanupCategory(name: "B", paths: ["/tmp/large"], bytes: 9)
        try expect([smaller, larger].sorted(by: CleanupCategory.sizeDescending).map(\.bytes)
                   == [9, 4], "cleanup categories were not sorted by descending size")

        let zero = "/tmp/zero"
        let safeWithZero = CleanupCategory(
            name: "Safe", paths: [first, zero, second], bytes: 5,
            pathBytes: [first: 2, zero: 0, second: 3], source: .core, risk: .safe,
            disposal: .trash, applyRoute: .genericTrash, activityGuard: .none,
            reasonKey: "cleanup.risk.rebuildableCache")
        let warning = CleanupCategory(
            name: "node_modules", paths: ["/tmp/node_modules"], bytes: 999,
            pathBytes: ["/tmp/node_modules": 999], source: .projectArtifact,
            risk: .warning, disposal: .trash, applyRoute: .projectArtifactTrash,
            activityGuard: .unsupported, reasonKey: "cleanup.risk.projectArtifact")
        let candidates = CleanupCategory.safeCleanupCandidates(from: [warning, safeWithZero])
        try expect(candidates.count == 1 && candidates[0].paths == [second, first]
                   && candidates[0].bytes == 5,
                   "cleanup candidate filter kept Warning/0B or lost size ordering")
    }

    private static func testAnalyzeEntrySafety() throws {
        let home = NSHomeDirectory()
        func entry(_ path: String, size: UInt64, isDir: Bool,
                   cleanable: Bool? = nil) -> AnalyzeEntry {
            AnalyzeEntry(name: URL(fileURLWithPath: path).lastPathComponent,
                         path: path, size: size, isDir: isDir,
                         insight: nil, cleanable: cleanable, lastAccess: nil)
        }

        let userFile = entry(home + "/Downloads/archive.zip", size: 1, isDir: false)
        let userFolder = entry(home + "/Movies", size: 700, isDir: true)
        let artifact = entry(home + "/Code/App/node_modules", size: 2,
                             isDir: true, cleanable: true)
        let appData = entry(home + "/Library/Application Support/App/data.db",
                            size: 800, isDir: false)
        let application = entry("/Applications/Example.app", size: 900, isDir: true)
        let system = entry("/Library/Application Support/System/data.db",
                           size: 1_000, isDir: false)

        try expect(userFile.canCleanDirectly && userFile.handling == .directCleanup,
                   "ordinary user file was not directly selectable")
        try expect(!userFolder.canCleanDirectly && userFolder.handling == .browse,
                   "ordinary directory was deletable instead of drill-down only")
        try expect(artifact.canCleanDirectly && artifact.handling == .directCleanup,
                   "engine-verified regenerable directory was not selectable")
        try expect(!appData.canCleanDirectly && appData.handling == .appData,
                   "ordinary app data was directly selectable")
        try expect(!application.canCleanDirectly && application.handling == .application,
                   "application bundle bypassed the uninstaller route")
        try expect(!system.canCleanDirectly && system.handling == .systemReadOnly,
                   "system content was directly selectable")

        let ordered = [system, application, appData, userFolder, userFile]
            .sorted(by: AnalyzeEntry.analysisOrder)
        try expect(ordered.map(\.handling) == [
            .systemReadOnly, .application, .appData, .browse, .directCleanup
        ], "disk analysis was not sorted by descending size")
    }

    private static func testAnalyzeAIItems() throws {
        let text = """
        12\tskill\tCodex · small\t/Users/test/.codex/skills/small
        4096\tmcp_cache\tnpx MCP cache\t/Users/test/.npm/_npx/abc
        24\tskill_link\tAgents · shared\t/Users/test/.agents/skills/shared
        0\tskill\tEmpty\t/Users/test/.codex/skills/empty
        999\tunknown\tUnknown\t/Users/test/unknown
        2\tskill\tDuplicate\t/Users/test/.codex/skills/small
        """
        let items = Parsers.analyzeAIItems(text)
        try expect(items.map(\.bytes) == [4_096, 24, 12],
                   "AI inventory did not filter invalid/0B rows or sort by size")
        try expect(items.map(\.kind) == [.mcpCache, .linkedSkill, .skill],
                   "AI inventory kinds were not preserved")
        try expect(Set(items.map(\.path)).count == items.count,
                   "AI inventory did not deduplicate physical selections by path")
    }

    private static func testDevEnvRelatedPackages() throws {
        let path = NSHomeDirectory() + "/.nvm/versions/node/v20.1.0"
        let modules = path + "/lib/node_modules"
        let rows = Parsers.devEnvEntries("4096\truntime\tnvm · v20.1.0\t\(path)\t3072\t\(modules)")
        let entry = try unwrap(rows.first, "nvm runtime with global packages")
        try expect(entry.bytes == 4_096 && entry.relatedBytes == 3_072 &&
                   entry.relatedPath == modules && entry.hasVersionGlobalPackages,
                   "nvm global package breakdown was not preserved")

        let legacy = Parsers.devEnvEntries("4096\truntime\tnvm · v18.0.0\t\(path)")
        try expect(legacy.first?.relatedBytes == 0 && legacy.first?.relatedPath == nil,
                   "legacy dev environment rows did not remain compatible")
    }

    private static func testCacheRoundTrip(fixture: URL) throws {
        try expect(ByteFormat.format(1_000_000_000) == "1.00 GB"
                   && ByteFormat.parse("1 GB") == 1_000_000_000,
                   "GB display and threshold bytes used different units")
        let path = fixture.appendingPathComponent("Library/Caches/com.example.tool/cache.bin")
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: path)
        let category = CleanupCategory(name: "Cache", paths: [path.path], bytes: 5,
                                       source: .core, risk: .safe, disposal: .trash,
                                       applyRoute: .genericTrash, activityGuard: .reverseDNSCache,
                                       reasonKey: "cleanup.risk.rebuildableCache")
        let cacheURL = fixture.appendingPathComponent("cleanup-cache.json")
        CleanupCache.save([category], to: cacheURL)
        let restored = try unwrap(CleanupCache.restore(from: cacheURL)?.categories.first,
                                  "cache round trip")
        try expect(restored.source == category.source && restored.risk == category.risk &&
                   restored.disposal == category.disposal &&
                   restored.applyRoute == category.applyRoute &&
                   restored.activityGuard == category.activityGuard &&
                   restored.reasonKey == category.reasonKey,
                   "cache lost risk metadata")

        // An empty, successful scan is a real result. It must be persisted so
        // Quick Clean can report a healthy machine without replaying the full
        // filesystem walk on every invocation.
        let emptyCacheURL = fixture.appendingPathComponent("cleanup-cache-empty.json")
        CleanupCache.save([], to: emptyCacheURL)
        let emptyRestored = CleanupCache.restore(from: emptyCacheURL)
        try expect(emptyRestored != nil && emptyRestored?.categories.isEmpty == true,
                   "empty cleanup result was not persisted")

        var json = try String(contentsOf: cacheURL, encoding: .utf8)
        // 把任意版本号降级为 10：测试不应与 CleanupCache.version 常量漂移耦合。
        if let marker = json.range(of: "\"version\":"),
           let comma = json[marker.upperBound...].firstIndex(of: ",") {
            json.replaceSubrange(marker.upperBound..<comma, with: "10")
        }
        try Data(json.utf8).write(to: cacheURL, options: .atomic)
        try expect(CleanupCache.restore(from: cacheURL) == nil,
                   "old cache version was restored without risk metadata")
    }

    private static func testSystemDataParsing() throws {
        let text = [
            "entry\t2048\tlogs\tsafe\tsystem.log\t21d · /Library/Logs\t/Library/Logs/system.log",
            "entry\t4096\tcaches\tsafe\tcom.example.cache\t34d · /Library/Caches\t/Library/Caches/com.example.cache",
            "entry\t8192\tupdates\treview\t90252\t40d · /Library/Updates\t/Library/Updates/90252",
            // 协议外的行必须整行丢弃：未知分组、未知风险、相对路径、零字节、列数不足。
            "entry\t1024\tbogus\tsafe\tx\ty\t/not/absolute/actually",
            "entry\t1024\tlogs\tprotected\tx\ty\t/Library/Logs/x.log",
            "entry\t0\tlogs\tsafe\tzero\tz\t/Library/Logs/zero.log",
            "entry\t1024\tlogs\tsafe\tshort\t/Library/Logs/short.log",
            "garbage line",
        ].joined(separator: "\n")
        let entries = Parsers.systemDataEntries(text)
        try expect(entries.count == 3, "valid system rows were dropped or invalid rows accepted")
        try expect(entries[0].group == .logs && entries[0].risk == .safe
                   && entries[0].bytes == 2048 && entries[0].name == "system.log",
                   "log row was parsed incorrectly")
        try expect(entries[2].group == .updates && entries[2].risk == .warning,
                   "update row did not keep its review risk")
        try expect(entries.allSatisfy { ($0.path as NSString).isAbsolutePath },
                   "non-absolute system path was accepted")
        // Safe 行默认勾选，Review 行默认不勾选。
        try expect(entries[0].selected && entries[1].selected && !entries[2].selected,
                   "default selection did not follow the risk badge")
        // 同一路径重复时保留容量最大的一条。
        let duplicate = "entry\t512\tlogs\tsafe\tdup\td\t/Library/Logs/dup.log\n"
            + "entry\t1024\tlogs\tsafe\tdup\td\t/Library/Logs/dup.log\n"
        let deduped = Parsers.systemDataEntries(duplicate)
        try expect(deduped.count == 1 && deduped[0].bytes == 1024,
                   "duplicate system path did not keep the largest measurement")

        let summary = Parsers.systemApplySummary(
            "removed=2\nskipped=1\nfailed=0\nremoved_bytes=6144\n")
        try expect(summary.removed == 2 && summary.failed == 0 && summary.removedBytes == 6144,
                   "system apply summary was parsed incorrectly")
        try expect(Parsers.systemDataEntries("").isEmpty,
                   "empty system preview produced entries")
    }

    private static func unwrap<T>(_ value: T?, _ name: String) throws -> T {
        guard let value else { throw RiskTestFailure(description: "missing \(name)") }
        return value
    }
}
