import AppKit
import Combine
import CoreGraphics
import Darwin
import Foundation

/// macOS 隐私权限的统一状态入口。
///
/// Full Disk Access 没有公开的通用查询 API。使用 TCC 数据库作为只读探针：
/// 成功可以确认已授权，失败只表示当前不能确认授权。不要用其他 App 的
/// Containers 做探针，否则检测权限这个动作本身就会触发系统授权弹窗。
/// 屏幕录制使用 Core Graphics 的公开预检 API。
@MainActor
final class PermissionCenter: ObservableObject {
    static let shared = PermissionCenter()

    enum SettingsDestination {
        case fullDisk
        case screenRecording

        fileprivate var legacyAnchor: String {
            switch self {
            case .fullDisk: "Privacy_AllFiles"
            case .screenRecording: "Privacy_ScreenCapture"
            }
        }
    }

    @Published private(set) var fullDiskAccessGranted = false
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var diskAuthorizationErrorKey: String?

    private init() {
        refresh()
    }

    var hasConfiguredScanAccess: Bool { fullDiskAccessGranted }

    /// 只读刷新权限状态，不访问 Desktop、Documents 等会触发 TCC 提示的目录。
    @discardableResult
    func refresh() -> Bool {
        fullDiskAccessGranted = Self.canOpenProtectedScanLocation()
        screenRecordingGranted = CGPreflightScreenCaptureAccess()
        if fullDiskAccessGranted { diskAuthorizationErrorKey = nil }
        return fullDiskAccessGranted
    }

    func reportDiskAccessNotDetected() {
        diskAuthorizationErrorKey = "permissions.disk.notDetected"
    }

    func clearDiskAuthorizationError() {
        diskAuthorizationErrorKey = nil
    }

    @discardableResult
    func requestScreenRecordingAccess() -> Bool {
        let granted = CGRequestScreenCaptureAccess()
        refresh()
        return granted || screenRecordingGranted
    }

    func openSystemSettings(_ destination: SettingsDestination) {
        let direct: URL?
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 13 {
            direct = URL(string:
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(destination.legacyAnchor)")
        } else {
            direct = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?\(destination.legacyAnchor)")
        }
        if let direct, NSWorkspace.shared.open(direct) { return }
        if let privacy = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy") {
            NSWorkspace.shared.open(privacy)
        }
    }

    private static func canOpenProtectedScanLocation() -> Bool {
        let path = NSHomeDirectory()
            + "/Library/Application Support/com.apple.TCC/TCC.db"
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        close(descriptor)
        return true
    }
}
