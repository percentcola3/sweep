import Foundation
import Darwin

enum TestFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String {
        switch self { case .failed(let message): return message }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw TestFailure.failed(message) }
}

func nul(_ fields: [String]) -> Data {
    var data = Data()
    for field in fields {
        data.append(contentsOf: field.utf8)
        data.append(0)
    }
    return data
}

func identity(_ path: String) throws -> String {
    var value = stat()
    guard lstat(path, &value) == 0 else { throw TestFailure.failed("missing identity: \(path)") }
    return "\(value.st_dev):\(value.st_ino):\(value.st_mtimespec.tv_sec)"
}

@main
struct ProjectAutomationTests {
    @MainActor
    static func main() throws {
        var passed = 0
        func pass(_ name: String) { passed += 1; print("PASS: \(name)") }

        let safe = AutomationItem(path: "/tmp/project/.next",
                                  identity: "1:2:3",
                                  bytes: 100,
                                  risk: .safe,
                                  disposition: .trash,
                                  source: .projectArtifact,
                                  requiresPrivilege: false,
                                  runtimeState: .idle)
        try expect(AutomationPolicy.canAutomate(safe), "strict Safe item should automate")
        try expect(!AutomationPolicy.canAutomate(AutomationItem(
            path: safe.path, identity: safe.identity, bytes: safe.bytes,
            risk: .warning, disposition: .trash, source: .projectArtifact,
            requiresPrivilege: false, runtimeState: .idle)), "Warning must not automate")
        for source in [AutomationSource.docker, .system, .aiModel, .aiSession,
                       .userSession, .userData, .ownerCommand] {
            let item = AutomationItem(path: safe.path, identity: safe.identity, bytes: 1,
                                      risk: .safe, disposition: .trash, source: source,
                                      requiresPrivilege: false, runtimeState: .idle)
            try expect(!AutomationPolicy.canAutomate(item), "forbidden source \(source) automated")
        }
        try expect(!AutomationPolicy.canAutomate(AutomationItem(
            path: "/tmp/project/.git/objects", identity: "1:2:3", bytes: 1,
            risk: .safe, disposition: .trash, source: .projectArtifact,
            requiresPrivilege: false, runtimeState: .idle)), ".git automated")
        try expect(!AutomationPolicy.canAutomate(AutomationItem(
            path: safe.path, identity: safe.identity, bytes: 1, risk: .safe,
            disposition: .trash, source: .projectArtifact,
            requiresPrivilege: false, runtimeState: .active)), "active item automated")
        try expect(!AutomationPolicy.canAutomate(AutomationItem(
            path: safe.path, identity: safe.identity, bytes: 1, risk: .safe,
            disposition: .trash, source: .projectArtifact,
            requiresPrivilege: false, runtimeState: .unknown)), "unknown activity automated")
        pass("central automation policy denies risk, runtime, and forbidden domains")

        try expect(!SmartTriggerCondition.savedLocationSizeLimit(bytes: 1).isValid,
                   "size below 0.1 GB accepted")
        try expect(SmartTriggerCondition.savedLocationSizeLimit(
            bytes: SmartTriggerCondition.minimumSizeLimitBytes).isValid,
            "0.1 GB lower bound rejected")
        try expect(!SmartTriggerCondition.savedLocationSizeLimit(
            bytes: SmartTriggerCondition.maximumSizeLimitBytes + 1).isValid,
            "size above 1024 GB accepted")
        let encodedCondition = try JSONEncoder().encode(
            SmartTriggerCondition.projectInactive(days: 30))
        try expect(!String(decoding: encodedCondition, as: UTF8.self).contains("command"),
                   "condition persisted command text")
        pass("typed trigger schema enforces bounds and stores no command")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let scheduled = SmartTriggerRule(name: "daily", isEnabled: true,
                                         condition: .daily(hour: 0),
                                         action: .quickCleanSafe, scope: .allSafe,
                                         armedAt: now.addingTimeInterval(-86_400))
        try expect(SmartTriggerEvaluator.evaluate(
            scheduled, context: .init(now: now), calendar: calendar).shouldRun,
            "due daily schedule did not run")
        var cooling = scheduled
        cooling.lastFiredAt = now.addingTimeInterval(-60)
        try expect(SmartTriggerEvaluator.evaluate(
            cooling, context: .init(now: now), calendar: calendar).skipReason == .cooldown,
            "cooldown not enforced")
        let projectRule = SmartTriggerRule(name: "inactive", isEnabled: true,
                                           condition: .projectInactive(days: 10),
                                           action: .hibernateProjectSafeArtifacts,
                                           scope: .project("root-id"))
        let inactiveContext = SmartTriggerContext(
            now: now, projectLastActivity: ["root-id": now.addingTimeInterval(-11 * 86_400)])
        try expect(SmartTriggerEvaluator.evaluate(
            projectRule, context: inactiveContext, calendar: calendar).shouldRun,
            "inactive project did not trigger")
        try expect(SmartTriggerEvaluator.evaluate(
            projectRule, context: .init(now: now), calendar: calendar).skipReason == .targetUnavailable,
            "missing project target did not fail closed")
        pass("trigger evaluator is deterministic, cooldown-aware, and target-safe")

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-mole-automation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let savedFile = temp.appendingPathComponent("saved.json")
        let savedStore = SavedScanLocationStore(fileURL: savedFile)
        let missingPath = temp.appendingPathComponent("missing").path
        let saved = try savedStore.add(path: missingPath)
        try expect(saved.availability == .unavailable, "missing location marked available")
        let reloadedLocations = SavedScanLocationStore.load(from: savedFile)
        try expect(reloadedLocations.count == 1 &&
                   reloadedLocations[0].availability == .unavailable,
                   "missing saved location was dropped")
        let existingPath = temp.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: existingPath,
                                                withIntermediateDirectories: true)
        let existing = try savedStore.add(path: existingPath.path)
        try expect(existing.availability == .available,
                   "newly user-selected location was not checked")
        let startupStore = SavedScanLocationStore(fileURL: savedFile)
        try expect(startupStore.locations.first(where: { $0.path == existingPath.path })?.availability
                   == .unavailable,
                   "saved location was probed during startup load")
        _ = startupStore.refreshAvailability(persist: false)
        try expect(startupStore.locations.first(where: { $0.path == existingPath.path })?.availability
                   == .available,
                   "explicit saved-location refresh did not probe availability")
        let corruptSavedFile = temp.appendingPathComponent("saved-corrupt.json")
        try Data("not-json".utf8).write(to: corruptSavedFile)
        let corruptSavedStore = SavedScanLocationStore(fileURL: corruptSavedFile)
        try expect(corruptSavedStore.locations.isEmpty && corruptSavedStore.lastError != nil,
                   "corrupt saved-location data was silently treated as empty")
        let persistenceBlocker = temp.appendingPathComponent("persistence-blocker")
        try Data("block".utf8).write(to: persistenceBlocker)
        let failingSavedStore = SavedScanLocationStore(
            fileURL: persistenceBlocker.appendingPathComponent("saved.json"))
        var savedMutationThrew = false
        do {
            _ = try failingSavedStore.add(path: missingPath + "-other")
        } catch {
            savedMutationThrew = true
        }
        try expect(savedMutationThrew && failingSavedStore.locations.isEmpty
                   && failingSavedStore.lastError != nil,
                   "saved-location persistence failure was hidden or published")
        pass("saved scan locations persist separately and retain unavailable paths")

        let automationFile = temp.appendingPathComponent("automation.json")
        let automationStore = AutomationStore(fileURL: automationFile)
        automationStore.add(SmartTriggerRule(name: "review", isEnabled: true,
                                             condition: .daily(hour: 3),
                                             action: .quickCleanSafe, scope: .allSafe))
        try expect(automationStore.triggers.count == 1 &&
                   !automationStore.triggers[0].isEnabled,
                   "new automation was enabled without review")
        let armedAt = calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 15, hour: 2, minute: 0))!
        let firstSchedule = calendar.date(from: DateComponents(
            year: 2027, month: 1, day: 15, hour: 3, minute: 0))!
        automationStore.setEnabled(true, id: automationStore.triggers[0].id, at: armedAt)
        try expect(automationStore.triggers[0].isEnabled, "valid reviewed trigger could not enable")
        try expect(automationStore.triggers[0].armedAt == armedAt,
                   "enable baseline was not captured")
        let armedRule = automationStore.triggers[0]
        try expect(SmartTriggerEvaluator.evaluate(
            armedRule, context: .init(now: armedAt), calendar: calendar).skipReason
                == .scheduleNotDue,
            "enabling at 02:00 backfilled the previous daily schedule")
        try expect(SmartTriggerEvaluator.evaluate(
            armedRule, context: .init(now: firstSchedule), calendar: calendar).shouldRun,
            "03:00 first normal schedule was postponed")
        try expect(SmartTriggerEvaluator.evaluate(
            armedRule, context: .init(now: firstSchedule.addingTimeInterval(37 * 60)),
            calendar: calendar).shouldRun,
            "03:xx did not consume the first normal schedule")

        // ISO-8601 persistence drops fractional seconds. The stored baseline must
        // round upward so enabling just after 03:00 cannot become 03:00 on reload.
        let justAfterSchedule = firstSchedule.addingTimeInterval(0.25)
        automationStore.setEnabled(true, id: armedRule.id, at: justAfterSchedule)
        let rearmedRule = automationStore.triggers[0]
        try expect(rearmedRule.armedAt == firstSchedule.addingTimeInterval(1),
                   "subsecond enable baseline was rounded backward")
        let reloadedRearmedRule = try requireRule(AutomationStore.load(from: automationFile).first,
                                                 "reloaded re-armed rule")
        try expect(SmartTriggerEvaluator.evaluate(
            reloadedRearmedRule,
            context: .init(now: firstSchedule.addingTimeInterval(37 * 60)),
            calendar: calendar).skipReason == .scheduleNotDue,
            "reload backfilled a schedule from before the enable instant")
        let persistedText = String(decoding: try Data(contentsOf: automationFile), as: UTF8.self)
        try expect(!persistedText.lowercased().contains("script") &&
                   !persistedText.lowercased().contains("command"),
                   "automation persistence contains executable text")

        // schema v1 rules had no armedAt. Keep them enabled but re-arm from migration
        // time, then persist the baseline so relaunches do not keep postponing it.
        let legacyFile = temp.appendingPathComponent("automation-legacy.json")
        try AutomationStore.save([armedRule], to: legacyFile)
        var legacyPayload = try requireJSONObject(at: legacyFile)
        var legacyTriggers = legacyPayload["triggers"] as? [[String: Any]] ?? []
        try expect(legacyTriggers.count == 1, "legacy fixture lost its rule")
        legacyTriggers[0].removeValue(forKey: "armedAt")
        legacyPayload["triggers"] = legacyTriggers
        try JSONSerialization.data(withJSONObject: legacyPayload, options: [.sortedKeys])
            .write(to: legacyFile, options: .atomic)
        let migrationTime = armedAt.addingTimeInterval(30 * 60)
        let migratedStore = AutomationStore(fileURL: legacyFile, now: migrationTime)
        try expect(migratedStore.triggers.first?.isEnabled == true &&
                   migratedStore.triggers.first?.armedAt == migrationTime,
                   "legacy enabled rule was not conservatively re-armed")
        try expect(AutomationStore.load(from: legacyFile).first?.armedAt == migrationTime,
                   "migrated enable baseline was not persisted")
        let corruptAutomationFile = temp.appendingPathComponent("automation-corrupt.json")
        try Data("not-json".utf8).write(to: corruptAutomationFile)
        let corruptAutomationStore = AutomationStore(fileURL: corruptAutomationFile)
        try expect(corruptAutomationStore.triggers.isEmpty
                   && corruptAutomationStore.lastError != nil,
                   "corrupt automation data was silently treated as empty")
        let failingAutomationStore = AutomationStore(
            fileURL: persistenceBlocker.appendingPathComponent("automation.json"))
        try expect(!failingAutomationStore.add(scheduled)
                   && failingAutomationStore.triggers.isEmpty
                   && failingAutomationStore.lastError != nil,
                   "failed automation mutation was published")

        let cooldownFile = temp.appendingPathComponent("cooldown.json")
        let cooldownStore = AutomationStore(fileURL: cooldownFile)
        try expect(cooldownStore.add(scheduled), "cooldown test rule was not stored")
        let cooldownID = cooldownStore.triggers[0].id
        try expect(cooldownStore.setEnabled(true, id: cooldownID, at: armedAt),
                   "cooldown test rule was not enabled")
        try FileManager.default.removeItem(at: cooldownFile)
        try FileManager.default.createDirectory(at: cooldownFile,
                                                withIntermediateDirectories: false)
        try expect(!cooldownStore.markFired(id: cooldownID, at: now)
                   && cooldownStore.triggers[0].lastFiredAt == now
                   && cooldownStore.lastError != nil,
                   "persistence failure allowed an in-process trigger refire")
        pass("automation store is separate, review-gated, and non-executable")

        let root = "/tmp/project"
        let radarData = nul([
            "location", "/tmp", "available",
            "location", "/missing", "unavailable",
            "project", root, "1:10", "1700000000",
            "artifact", root, "safe", "javascriptCache", "1024", "1690000000",
            "1:11:1690000000", "\(root)/.next",
            "artifact", root, "warning", "dependencyNodeModules", "2048", "1680000000",
            "1:12:1680000000", "\(root)/node_modules",
            "summary", "1", "2", "1",
        ])
        let snapshot = try ProjectRadar.parse(radarData)
        try expect(snapshot.projects.count == 1 && snapshot.projects[0].safeArtifacts.count == 1 &&
                   snapshot.projects[0].warningArtifacts.count == 1,
                   "radar protocol lost risk classes")
        try expect(snapshot.unavailableLocations == ["/missing"],
                   "radar protocol lost unavailable root")
        let activity = try ProjectActivity.parse(nul([
            "activity", root, "idle", "no-open-file", "summary", "1", "0", "0",
        ]))
        try expect(activity[root]?.state == .idle, "activity protocol did not parse")
        pass("project radar and activity protocols are strict and NUL-safe")

        let safeArtifact = ProjectArtifact(projectRoot: root,
                                           path: "\(root)/.next",
                                           identity: "1:11:1690000000",
                                           kind: .javascriptCache,
                                           risk: .safe,
                                           bytes: 1024,
                                           modifiedAt: Date(timeIntervalSince1970: 1_690_000_000))
        let warningArtifact = ProjectArtifact(projectRoot: root,
                                              path: "\(root)/node_modules",
                                              identity: "1:12:1680000000",
                                              kind: .dependencyNodeModules,
                                              risk: .warning,
                                              bytes: 2048,
                                              modifiedAt: Date(timeIntervalSince1970: 1_680_000_000))
        let project = RadarProject(rootPath: root, rootIdentity: "1:10",
                                   lastActivityAt: Date(),
                                   artifacts: [safeArtifact, warningArtifact])
        let sameInodeElsewhere = RadarProject(rootPath: root + "-replacement",
                                              rootIdentity: project.rootIdentity,
                                              lastActivityAt: project.lastActivityAt,
                                              artifacts: [])
        try expect(project.id != sameInodeElsewhere.id,
                   "project automation identity ignored the bound root path")
        let automaticPlan = try ProjectHibernation.makePlan(
            project: project, mode: .automatic, runtimeState: .idle)
        try expect(automaticPlan.artifacts.map(\.path) == [safeArtifact.path],
                   "automatic plan included Warning dependency")
        let manualPlan = try ProjectHibernation.makePlan(
            project: project, mode: .manual, runtimeState: .idle,
            manuallyIncludedWarningPaths: [warningArtifact.path])
        try expect(Set(manualPlan.artifacts.map(\.path)) ==
                   Set([safeArtifact.path, warningArtifact.path]),
                   "manual explicit Warning selection was lost")
        do {
            _ = try ProjectHibernation.makePlan(
                project: project, mode: .automatic, runtimeState: .unknown)
            throw TestFailure.failed("unknown activity produced hibernation plan")
        } catch ProjectHibernationError.noEligibleArtifacts {
            // Expected.
        }
        pass("hibernation plans keep Safe automatic and Warning explicitly manual")

        let trashPath = temp.appendingPathComponent("trashed-artifact", isDirectory: true)
        try FileManager.default.createDirectory(at: trashPath, withIntermediateDirectories: true)
        let trashIdentity = try identity(trashPath.path)
        let receiptOutput = nul([
            "trashed", root, safeArtifact.path, safeArtifact.identity,
            trashPath.path, trashIdentity, "1024", "javascriptCache",
            "summary", "1", "0",
        ])
        let receipt = try ProjectHibernation.parseHibernateOutput(
            receiptOutput, plan: automaticPlan, now: now)
        try expect(receipt.state == .hibernated && receipt.recoverableArtifacts.count == 1,
                   "exact Trash receipt did not parse")
        let receiptFile = temp.appendingPathComponent("receipts.json")
        let receiptStore = ProjectHibernationReceiptStore(fileURL: receiptFile)
        try expect(receiptStore.upsert(receipt), "valid receipt was not persisted")
        receiptStore.refreshAvailability()
        try expect(receiptStore.receipts[0].state == .hibernated,
                   "valid Trash identity became unavailable")
        try FileManager.default.removeItem(at: trashPath)
        receiptStore.refreshAvailability()
        try expect(receiptStore.receipts[0].state == .unavailable,
                   "missing Trash path remained recoverable")
        let restore = try ProjectHibernation.parseRestoreOutput(nul([
            "restored", root, safeArtifact.path, trashPath.path, "javascriptCache",
            "summary", "1", "0",
        ]))
        let restored = ProjectHibernation.applying(restore, to: receipt)
        try expect(restored.state == .restored && restored.artifacts[0].state == .restored,
                   "restore result did not bind to exact original path")

        let recoveryTrash = temp.appendingPathComponent("recovery-trash", isDirectory: true)
        let recoveredArtifact = recoveryTrash.appendingPathComponent("crash-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveredArtifact,
                                                withIntermediateDirectories: true)
        let recoveredIdentity = try identity(recoveredArtifact.path)
        let crashArtifact = ProjectArtifact(projectRoot: root,
                                            path: "\(root)/.crash-cache",
                                            identity: recoveredIdentity,
                                            kind: .javascriptCache,
                                            risk: .safe,
                                            bytes: 4096,
                                            modifiedAt: now)
        let crashPlan = ProjectHibernationPlan(id: UUID(),
                                               projectRoot: root,
                                               projectRootIdentity: "1:10",
                                               mode: .automatic,
                                               maximumProjectActivityAt: nil,
                                               artifacts: [crashArtifact])
        let pending = ProjectHibernation.pendingReceipt(for: crashPlan, now: now)
        let recoveryFile = temp.appendingPathComponent("recovery-receipts.json")
        let pendingStore = ProjectHibernationReceiptStore(
            fileURL: recoveryFile, trashDirectoryURL: recoveryTrash)
        try expect(pendingStore.upsert(pending), "pending receipt was not persisted")
        let recoveredStore = ProjectHibernationReceiptStore(
            fileURL: recoveryFile, trashDirectoryURL: recoveryTrash)
        try expect(recoveredStore.receipts.first?.state == .partial
                   && recoveredStore.receipts.first?.artifacts.first?.trashPath.isEmpty == true,
                   "receipt store enumerated Trash during startup load")
        recoveredStore.refreshAvailability()
        let recoveredReceiptArtifact = recoveredStore.receipts.first?.artifacts.first
        let reboundIdentity = try recoveredReceiptArtifact.map { try identity($0.trashPath) }
        try expect(recoveredStore.receipts.first?.state == .hibernated
                   && recoveredReceiptArtifact?.trashIdentity == recoveredIdentity
                   && reboundIdentity == recoveredIdentity,
                   "crash-window receipt was not rebound by exact Trash identity")

        let blocker = temp.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blocker)
        let failingStore = ProjectHibernationReceiptStore(
            fileURL: blocker.appendingPathComponent("receipts.json"),
            trashDirectoryURL: recoveryTrash)
        try expect(!failingStore.upsert(pending) && failingStore.receipts.isEmpty,
                   "receipt persistence failure was hidden or published")
        let corruptReceiptFile = temp.appendingPathComponent("receipts-corrupt.json")
        try Data("not-json".utf8).write(to: corruptReceiptFile)
        let corruptReceiptStore = ProjectHibernationReceiptStore(
            fileURL: corruptReceiptFile, trashDirectoryURL: recoveryTrash)
        try expect(corruptReceiptStore.receipts.isEmpty && corruptReceiptStore.lastError != nil,
                   "corrupt receipt data was silently treated as empty")
        pass("hibernation receipts persist before mutation and recover by exact Trash identity")

        print("Project automation Swift tests passed: \(passed)")
    }

    private static func requireJSONObject(at url: URL) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let dictionary = object as? [String: Any] else {
            throw TestFailure.failed("automation fixture was not a JSON object")
        }
        return dictionary
    }

    private static func requireRule(_ rule: SmartTriggerRule?,
                                    _ name: String) throws -> SmartTriggerRule {
        guard let rule else { throw TestFailure.failed("missing \(name)") }
        return rule
    }
}
