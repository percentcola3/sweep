import Foundation

enum AutomationRisk: String, Codable, CaseIterable, Sendable {
    case safe
    case warning
    case protected
}

enum AutomationDisposition: String, Codable, Sendable {
    case trash
    case ownerCommand
    case privileged
    case mutateInPlace
    case none
}

enum AutomationSource: String, Codable, Sendable {
    case quickClean
    case disposableDirectory
    case projectArtifact
    case docker
    case system
    case aiModel
    case aiSession
    case userSession
    case userData
    case ownerCommand
    case uninstall
    case process
    case imageRewrite
}

enum AutomationRuntimeState: String, Codable, Sendable {
    case idle
    case active
    case unknown
}

struct AutomationItem: Identifiable, Codable, Equatable, Sendable {
    var id: String { path }
    let path: String
    let identity: String
    let bytes: UInt64
    let risk: AutomationRisk
    let disposition: AutomationDisposition
    let source: AutomationSource
    let requiresPrivilege: Bool
    let runtimeState: AutomationRuntimeState
}

enum AutomationDenialReason: String, Codable, Sendable {
    case notSafe
    case notTrashable
    case privilegeRequired
    case activeOwner
    case activityUnknown
    case forbiddenSource
    case sensitivePath
    case invalidPath
    case missingIdentity
}

struct AutomationPolicyDecision: Equatable, Sendable {
    let allowed: Bool
    let reason: AutomationDenialReason?

    static let allow = AutomationPolicyDecision(allowed: true, reason: nil)

    static func deny(_ reason: AutomationDenialReason) -> AutomationPolicyDecision {
        AutomationPolicyDecision(allowed: false, reason: reason)
    }
}

/// The single Swift-side automation gate. Bridges must independently revalidate
/// the same invariants before touching the filesystem.
enum AutomationPolicy {
    private static let forbiddenSources: Set<AutomationSource> = [
        .docker, .system, .aiModel, .aiSession, .userSession, .userData,
        .ownerCommand, .uninstall, .process, .imageRewrite,
    ]

    static func decision(for item: AutomationItem) -> AutomationPolicyDecision {
        guard !item.path.isEmpty, (item.path as NSString).isAbsolutePath else {
            return .deny(.invalidPath)
        }
        guard !item.identity.isEmpty else { return .deny(.missingIdentity) }
        guard !isSensitivePath(item.path) else { return .deny(.sensitivePath) }
        guard !forbiddenSources.contains(item.source) else { return .deny(.forbiddenSource) }
        guard item.risk == .safe else { return .deny(.notSafe) }
        guard item.disposition == .trash else { return .deny(.notTrashable) }
        guard !item.requiresPrivilege else { return .deny(.privilegeRequired) }
        switch item.runtimeState {
        case .idle: return .allow
        case .active: return .deny(.activeOwner)
        case .unknown: return .deny(.activityUnknown)
        }
    }

    static func canAutomate(_ item: AutomationItem) -> Bool {
        decision(for: item).allowed
    }

    /// Defense in depth for inputs assembled outside the project scanner.
    static func isSensitivePath(_ rawPath: String) -> Bool {
        CleanupRiskPolicy.isSensitiveAutomationPath(rawPath)
    }
}
