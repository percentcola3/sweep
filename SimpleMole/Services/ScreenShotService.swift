import Foundation
import AppKit
import Carbon.HIToolbox

/// 全局快捷键（Carbon RegisterEventHotKey，无需辅助功能权限）。
final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: (() -> Void)?

    @discardableResult
    func register(keyCode: UInt32 = UInt32(kVK_ANSI_A),
                  modifiers: UInt32 = UInt32(cmdKey | shiftKey),
                  handler: @escaping () -> Void) -> Bool {
        unregister()
        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue().fire()
                return noErr
            }, 1, &eventType, selfPtr, &eventHandlerRef)
            guard status == noErr else {
                eventHandlerRef = nil
                return false
            }
        }
        self.handler = handler
        let hotKeyID = EventHotKeyID(signature: OSType(0x534D_484B), id: 1) // "SMHK"
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        hotKeyRef = status == noErr ? ref : nil
        if hotKeyRef == nil { self.handler = nil }
        return hotKeyRef != nil
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        handler = nil
    }

    private func fire() {
        Task { @MainActor in handler?() }
    }
}

/// 交互式截图：调系统 screencapture -i（区域/窗口选择体验与系统一致），
/// 完成后读取为内存图片并立即清理私有临时目录。需要屏幕录制权限（首次系统会弹授权）。
enum ScreenShotService {
    static func captureInteractive(completion: @escaping (NSImage?) -> Void) {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("com.forgesweep.screenshot.\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory,
                                            withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
        } catch {
            completion(nil)
            return
        }
        let url = directory.appendingPathComponent("capture.png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-x", url.path]
        process.terminationHandler = { proc in
            let image = proc.terminationStatus == 0
                ? (try? Data(contentsOf: url)).flatMap(NSImage.init(data:))
                : nil
            try? fileManager.removeItem(at: directory)
            DispatchQueue.main.async {
                completion(image)
            }
        }
        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: directory)
            DispatchQueue.main.async { completion(nil) }
        }
    }
}
