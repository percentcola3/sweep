import Foundation

struct SmartTriggerContext: Sendable {
    var now: Date
    var projectLastActivity: [String: Date]
    var savedLocationBytes: [String: UInt64]
    var savedLocationOldestItem: [String: Date]

    init(now: Date = Date(),
         projectLastActivity: [String: Date] = [:],
         savedLocationBytes: [String: UInt64] = [:],
         savedLocationOldestItem: [String: Date] = [:]) {
        self.now = now
        self.projectLastActivity = projectLastActivity
        self.savedLocationBytes = savedLocationBytes
        self.savedLocationOldestItem = savedLocationOldestItem
    }
}

enum SmartTriggerSkipReason: String, Sendable {
    case disabled
    case invalidRule
    case cooldown
    case scheduleNotDue
    case targetUnavailable
    case thresholdNotReached
}

struct SmartTriggerEvaluation: Equatable, Sendable {
    let ruleID: UUID
    let shouldRun: Bool
    let skipReason: SmartTriggerSkipReason?

    static func run(_ id: UUID) -> Self {
        .init(ruleID: id, shouldRun: true, skipReason: nil)
    }

    static func skip(_ id: UUID, _ reason: SmartTriggerSkipReason) -> Self {
        .init(ruleID: id, shouldRun: false, skipReason: reason)
    }
}

/// Pure evaluator: it returns typed decisions and never executes a command.
enum SmartTriggerEvaluator {
    static func evaluate(_ rule: SmartTriggerRule,
                         context: SmartTriggerContext,
                         calendar: Calendar = .current) -> SmartTriggerEvaluation {
        guard rule.isEnabled else { return .skip(rule.id, .disabled) }
        guard rule.isValid else { return .skip(rule.id, .invalidRule) }
        if let lastFiredAt = rule.lastFiredAt,
           context.now.timeIntervalSince(lastFiredAt) < rule.cooldownSeconds {
            return .skip(rule.id, .cooldown)
        }

        switch rule.condition.kind {
        case .dailySchedule, .weeklySchedule:
            guard let armedAt = rule.armedAt else {
                return .skip(rule.id, .invalidRule)
            }
            guard let scheduled = mostRecentScheduledDate(
                for: rule.condition, now: context.now, calendar: calendar) else {
                return .skip(rule.id, .invalidRule)
            }
            if scheduled > context.now || scheduled < armedAt ||
                (rule.lastFiredAt.map { $0 >= scheduled } ?? false) {
                return .skip(rule.id, .scheduleNotDue)
            }
            return .run(rule.id)

        case .projectInactive:
            guard let id = rule.scope.targetID,
                  let lastActivity = context.projectLastActivity[id],
                  let days = rule.condition.days,
                  let cutoff = calendar.date(byAdding: .day, value: -days, to: context.now) else {
                return .skip(rule.id, .targetUnavailable)
            }
            return lastActivity <= cutoff
                ? .run(rule.id)
                : .skip(rule.id, .thresholdNotReached)

        case .savedLocationSizeLimit:
            guard let id = rule.scope.targetID,
                  let currentBytes = context.savedLocationBytes[id],
                  let limit = rule.condition.bytes else {
                return .skip(rule.id, .targetUnavailable)
            }
            return currentBytes > limit
                ? .run(rule.id)
                : .skip(rule.id, .thresholdNotReached)

        case .savedLocationRetention:
            guard let id = rule.scope.targetID,
                  let oldest = context.savedLocationOldestItem[id],
                  let days = rule.condition.days,
                  let cutoff = calendar.date(byAdding: .day, value: -days, to: context.now) else {
                return .skip(rule.id, .targetUnavailable)
            }
            return oldest < cutoff
                ? .run(rule.id)
                : .skip(rule.id, .thresholdNotReached)
        }
    }

    static func dueRules(_ rules: [SmartTriggerRule],
                         context: SmartTriggerContext,
                         calendar: Calendar = .current) -> [SmartTriggerRule] {
        rules.filter { evaluate($0, context: context, calendar: calendar).shouldRun }
    }

    private static func mostRecentScheduledDate(for condition: SmartTriggerCondition,
                                                now: Date,
                                                calendar: Calendar) -> Date? {
        guard let hour = condition.hour, let minute = condition.minute else { return nil }
        switch condition.kind {
        case .dailySchedule:
            guard let today = calendar.date(bySettingHour: hour,
                                            minute: minute,
                                            second: 0,
                                            of: now) else { return nil }
            return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)

        case .weeklySchedule:
            guard let weekday = condition.weekday else { return nil }
            var components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
            components.weekday = weekday
            components.hour = hour
            components.minute = minute
            components.second = 0
            guard let thisWeek = calendar.date(from: components) else { return nil }
            return thisWeek <= now
                ? thisWeek
                : calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek)

        default:
            return nil
        }
    }
}
