import Foundation
import Combine

/// AutomationStore persists dates with ISO-8601 second precision. Round an enable
/// instant upward so reloading can never move it to before the user's toggle.
private func normalizedArmedAt(_ date: Date) -> Date {
    Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.up))
}

enum SmartTriggerConditionKind: String, Codable, CaseIterable, Sendable {
    case dailySchedule
    case weeklySchedule
    case projectInactive
    case savedLocationSizeLimit
    case savedLocationRetention
}

struct SmartTriggerCondition: Codable, Equatable, Sendable {
    static let minimumSizeLimitBytes: UInt64 = 100_000_000 // 0.1 GB.
    static let maximumSizeLimitBytes: UInt64 = 1_024_000_000_000 // 1024 GB.

    let kind: SmartTriggerConditionKind
    let hour: Int?
    let minute: Int?
    let weekday: Int?
    let days: Int?
    let bytes: UInt64?

    static func daily(hour: Int, minute: Int = 0) -> Self {
        .init(kind: .dailySchedule, hour: hour, minute: minute,
              weekday: nil, days: nil, bytes: nil)
    }

    static func weekly(weekday: Int, hour: Int, minute: Int = 0) -> Self {
        .init(kind: .weeklySchedule, hour: hour, minute: minute,
              weekday: weekday, days: nil, bytes: nil)
    }

    static func projectInactive(days: Int) -> Self {
        .init(kind: .projectInactive, hour: nil, minute: nil,
              weekday: nil, days: days, bytes: nil)
    }

    static func savedLocationSizeLimit(bytes: UInt64) -> Self {
        .init(kind: .savedLocationSizeLimit, hour: nil, minute: nil,
              weekday: nil, days: nil, bytes: bytes)
    }

    static func savedLocationRetention(days: Int) -> Self {
        .init(kind: .savedLocationRetention, hour: nil, minute: nil,
              weekday: nil, days: days, bytes: nil)
    }

    var isValid: Bool {
        switch kind {
        case .dailySchedule:
            return validTime && weekday == nil && days == nil && bytes == nil
        case .weeklySchedule:
            return validTime && (1...7).contains(weekday ?? 0) && days == nil && bytes == nil
        case .projectInactive, .savedLocationRetention:
            return hour == nil && minute == nil && weekday == nil
                && (1...3650).contains(days ?? 0) && bytes == nil
        case .savedLocationSizeLimit:
            return hour == nil && minute == nil && weekday == nil && days == nil
                && (Self.minimumSizeLimitBytes...Self.maximumSizeLimitBytes).contains(bytes ?? 0)
        }
    }

    private var validTime: Bool {
        (0...23).contains(hour ?? -1) && (0...59).contains(minute ?? -1)
    }
}

enum AutomationAction: String, Codable, CaseIterable, Sendable {
    case quickCleanSafe
    case cleanSavedLocationSafe
    case hibernateProjectSafeArtifacts
}

enum AutomationScopeKind: String, Codable, CaseIterable, Sendable {
    case allSafe
    case savedLocation
    case project
}

struct AutomationScope: Codable, Equatable, Sendable {
    let kind: AutomationScopeKind
    let targetID: String?

    static let allSafe = AutomationScope(kind: .allSafe, targetID: nil)

    static func savedLocation(_ id: UUID) -> Self {
        AutomationScope(kind: .savedLocation, targetID: id.uuidString)
    }

    static func project(_ id: String) -> Self {
        AutomationScope(kind: .project, targetID: id)
    }

    var isValid: Bool {
        switch kind {
        case .allSafe: return targetID == nil
        case .savedLocation, .project: return !(targetID ?? "").isEmpty
        }
    }
}

struct SmartTriggerRule: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var isEnabled: Bool
    var condition: SmartTriggerCondition
    var action: AutomationAction
    var scope: AutomationScope
    var cooldownSeconds: TimeInterval
    /// 本次启用的基线。计划触发只能消费不早于该时间的计划点，避免补跑上一周期。
    var armedAt: Date?
    var lastFiredAt: Date?

    init(id: UUID = UUID(),
         name: String,
         isEnabled: Bool = false,
         condition: SmartTriggerCondition,
         action: AutomationAction,
         scope: AutomationScope,
         cooldownSeconds: TimeInterval = 6 * 60 * 60,
         armedAt: Date? = nil,
         lastFiredAt: Date? = nil) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.condition = condition
        self.action = action
        self.scope = scope
        self.cooldownSeconds = cooldownSeconds
        self.armedAt = isEnabled ? normalizedArmedAt(armedAt ?? Date()) : nil
        self.lastFiredAt = lastFiredAt
    }

    var isValid: Bool {
        guard condition.isValid, scope.isValid,
              cooldownSeconds.isFinite, cooldownSeconds >= 60 * 60 else { return false }
        switch action {
        case .quickCleanSafe:
            return scope.kind == .allSafe
                && (condition.kind == .dailySchedule || condition.kind == .weeklySchedule)
        case .cleanSavedLocationSafe:
            return scope.kind == .savedLocation
                && condition.kind != .projectInactive
        case .hibernateProjectSafeArtifacts:
            return scope.kind == .project
                && (condition.kind == .projectInactive
                    || condition.kind == .dailySchedule
                    || condition.kind == .weeklySchedule)
        }
    }
}

@MainActor
final class AutomationStore: ObservableObject {
    private struct Payload: Codable {
        var schemaVersion: Int
        var triggers: [SmartTriggerRule]
    }

    static let schemaVersion = 1

    static var defaultFileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/ForgeSweep", isDirectory: true)
            .appendingPathComponent("automation-v1.json", isDirectory: false)
    }

    @Published private(set) var triggers: [SmartTriggerRule]
    @Published private(set) var lastError: String?

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil,
         fileManager: FileManager = .default,
         now: Date = Date()) {
        let resolvedFileURL = fileURL ?? Self.defaultFileURL
        let loaded = Self.loadResult(from: resolvedFileURL, fileManager: fileManager)
        self.fileURL = resolvedFileURL
        self.fileManager = fileManager
        self.lastError = loaded.error
        var migrated = false
        self.triggers = loaded.triggers.map { rule in
            var safeRule = rule
            if !safeRule.isValid {
                if safeRule.isEnabled || safeRule.armedAt != nil { migrated = true }
                safeRule.isEnabled = false
                safeRule.armedAt = nil
            } else if safeRule.isEnabled && safeRule.armedAt == nil {
                // schema v1 没有 armedAt。保守地从本次加载开始计时，并立即回写，
                // 避免每次启动都重新推迟首个正常计划点。
                safeRule.armedAt = normalizedArmedAt(now)
                migrated = true
            } else if !safeRule.isEnabled && safeRule.armedAt != nil {
                safeRule.armedAt = nil
                migrated = true
            }
            return safeRule
        }
        if migrated { _ = persist(triggers) }
    }

    @discardableResult
    func add(_ rule: SmartTriggerRule) -> Bool {
        var safeRule = rule
        // Every new automation requires an explicit enable action after review.
        safeRule.isEnabled = false
        safeRule.armedAt = nil
        var next = triggers
        next.append(safeRule)
        return persist(next)
    }

    @discardableResult
    func update(_ rule: SmartTriggerRule) -> Bool {
        guard let index = triggers.firstIndex(where: { $0.id == rule.id }) else { return false }
        var safeRule = rule
        if !safeRule.isValid {
            safeRule.isEnabled = false
            safeRule.armedAt = nil
        } else if safeRule.isEnabled {
            // Editing an already-enabled rule keeps its existing enable baseline.
            safeRule.armedAt = triggers[index].armedAt ?? normalizedArmedAt(Date())
        } else {
            safeRule.armedAt = nil
        }
        var next = triggers
        next[index] = safeRule
        return persist(next)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool, id: UUID, at date: Date = Date()) -> Bool {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return false }
        var next = triggers
        let willEnable = enabled && next[index].isValid
        next[index].isEnabled = willEnable
        next[index].armedAt = willEnable ? normalizedArmedAt(date) : nil
        return persist(next)
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        let next = triggers.filter { $0.id != id }
        guard next != triggers else { return true }
        return persist(next)
    }

    @discardableResult
    func markFired(id: UUID, at date: Date = Date()) -> Bool {
        guard let index = triggers.firstIndex(where: { $0.id == id }) else { return false }
        var next = triggers
        next[index].lastFiredAt = date
        // Keep the in-process cooldown even if durable storage is unavailable;
        // otherwise the same trigger could fire repeatedly during this launch.
        return persist(next, publishOnFailure: true)
    }

    @discardableResult
    func replaceForTesting(_ replacement: [SmartTriggerRule]) -> Bool {
        let next = replacement.map { rule in
            var safeRule = rule
            if !safeRule.isValid {
                safeRule.isEnabled = false
                safeRule.armedAt = nil
            } else if safeRule.isEnabled && safeRule.armedAt == nil {
                safeRule.armedAt = normalizedArmedAt(Date())
            } else if !safeRule.isEnabled {
                safeRule.armedAt = nil
            }
            return safeRule
        }
        return persist(next)
    }

    @discardableResult
    private func persist(_ next: [SmartTriggerRule],
                         publishOnFailure: Bool = false) -> Bool {
        do {
            try Self.save(next, to: fileURL, fileManager: fileManager)
            triggers = next
            lastError = nil
            return true
        } catch {
            if publishOnFailure { triggers = next }
            lastError = error.localizedDescription
            return false
        }
    }

    static func load(from fileURL: URL) -> [SmartTriggerRule] {
        loadResult(from: fileURL, fileManager: .default).triggers
    }

    private static func loadResult(from fileURL: URL,
                                   fileManager: FileManager) -> (triggers: [SmartTriggerRule],
                                                                 error: String?) {
        guard fileManager.fileExists(atPath: fileURL.path) else { return ([], nil) }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(Payload.self, from: data)
            guard payload.schemaVersion == schemaVersion else {
                return ([], "Smart Triggers use an unsupported data version.")
            }
            return (payload.triggers, nil)
        } catch {
            return ([], "Could not load Smart Triggers: \(error.localizedDescription)")
        }
    }

    static func save(_ triggers: [SmartTriggerRule],
                     to fileURL: URL,
                     fileManager: FileManager = .default) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory,
                                        withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: NSNumber(value: 0o700)])
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o700)],
                                      ofItemAtPath: directory.path)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Payload(schemaVersion: schemaVersion, triggers: triggers))
        try data.write(to: fileURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o600)],
                                      ofItemAtPath: fileURL.path)
    }
}
