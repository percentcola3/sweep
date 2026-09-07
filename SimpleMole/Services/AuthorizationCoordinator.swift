import Combine
import Foundation

/// 需要完全磁盘访问权限才能安全执行的用户操作。
///
/// 这里保存的是可恢复的业务意图，不保存闭包。应用在打开系统设置期间被
/// macOS 退出或用户手动重启后，仍能在确认授权后准确恢复一次原操作。
enum ProtectedOperation: Codable, Equatable {
    case cleanupScan(force: Bool)
    case deepCleanupScan
    case quickOptimize
    case optimize
    case developerToolsScan
    case aiScan
    case xcodeScan
    case slimScan
    case systemScan
    case imageScan
    case installedAppsScan
    case uninstall(app: UninstallApp)
    case developmentEnvironmentScan
    case diskOverview(force: Bool)
    case diskAnalyze(path: String?)
    case duplicateScan
    case openProjectRadar
    case openAutomationSettings
    case restoreProject(receipt: ProjectHibernationReceipt)
    case previewAutoCleanup(ruleID: UUID)
    case runAutoCleanup(ruleID: UUID)
}

/// 持久化一个尚未获得授权的受保护操作。
///
/// 同一时刻只保留最新一次明确的用户意图。消费时先删除持久化记录，再执行，
/// 保证应用激活通知重复到达时也只会恢复一次。
@MainActor
final class AuthorizationCoordinator: ObservableObject {
    @Published private(set) var pendingOperation: ProtectedOperation?

    private static let pendingOperationKey = "ForgeSweep.PendingProtectedOperation.v1"
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.pendingOperationKey),
           let operation = try? decoder.decode(ProtectedOperation.self, from: data) {
            pendingOperation = operation
        } else {
            pendingOperation = nil
            defaults.removeObject(forKey: Self.pendingOperationKey)
        }
    }

    func storePending(_ operation: ProtectedOperation) {
        guard let data = try? encoder.encode(operation) else {
            clearPending()
            return
        }
        // @Published 会同步通知订阅者；先持久化，避免恢复流程观察到仅存在于内存的意图。
        defaults.set(data, forKey: Self.pendingOperationKey)
        pendingOperation = operation
    }

    func takePending() -> ProtectedOperation? {
        let operation = pendingOperation
        clearPending()
        return operation
    }

    func clearPending() {
        pendingOperation = nil
        defaults.removeObject(forKey: Self.pendingOperationKey)
    }
}
