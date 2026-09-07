import AppKit
import SwiftUI
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    private var statusItem: NSStatusItem?
    private var quickPanel: NSPanel?
    private var mainWindow: NSWindow?
    private var runtimeTimer: Timer?
    private var autoCleanupTimer: Timer?
    private var isCapturingScreenshot = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            if let image = menuBarIcon(size: NSSize(width: 18, height: 18)) {
                button.image = image
            }
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "ForgeSweep"
            button.target = self
            button.action = #selector(toggleQuickPanel(_:))
        }
        statusItem = item

        // 附件应用：启动只驻留菜单栏；点击图标展示快捷面板，"更多"才开主窗口。
        runtimeTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.appState.refreshMetrics()
                self.appState.refreshRuntimeIfNeeded()
                if self.quickPanel?.isVisible == true {
                    self.appState.refreshTopMemoryApps()
                }
            }
        }
        runtimeTimer?.tolerance = 0.2
        setupScreenshotPipeline()
        // 自动目录规则由应用常驻进程调度；AppState 内部按六小时最小间隔限频。
        autoCleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.appState.runScheduledAutoCleanup() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.appState.runScheduledAutoCleanup()
        }
        // auto 模式下，回到前台时重新解析系统语言。
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { _ in
                L10n.shared.refreshIfAuto()
            }
            .store(in: &observables)
        // 语言切换后重建本地化菜单。
        L10n.shared.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.setupMenu() }
            .store(in: &observables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        autoCleanupTimer?.invalidate()
        runtimeTimer?.invalidate()
        HotKeyCenter.shared.unregister()
        MosaicCache.shared.clear()
        appState.stopUninstallQueueForTermination()
        MoleEngine.shared.cancelAll()
    }

    /// 点击程序坞图标：唤起详细面板（主窗口）。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return false
    }

    /// 截图编辑器独立窗口（新建/复用）。
    private var editorWindow: NSWindow?

    private func setupScreenshotPipeline() {
        NotificationCenter.default.publisher(for: .smTakeScreenshot)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self,
                      !self.isCapturingScreenshot,
                      self.editorWindow?.isVisible != true else { return }
                self.appState.permissionCenter.refresh()
                guard self.appState.permissionCenter.screenRecordingGranted else {
                    self.showMainWindow()
                    self.appState.presentPermissionCenter()
                    return
                }
                self.isCapturingScreenshot = true
                ScreenShotService.captureInteractive { image in
                    self.isCapturingScreenshot = false
                    guard let image else { return }
                    self.openScreenshotEditor(image: image)
                }
            }
            .store(in: &observables)
    }

    private func openScreenshotEditor(image: NSImage) {
        NSApp.activate(ignoringOtherApps: true)
        if editorWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = L10n.shared.t("shot.title")
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 640, height: 480)
            window.center()
            observeEditorWindow(window)
            editorWindow = window
        }
        editorWindow?.contentViewController = NSHostingController(
            rootView: ScreenshotEditorView(image: image) { [weak self] in
                self?.closeScreenshotEditor()
            })
        editorWindow?.makeKeyAndOrderFront(nil)
    }

    private func closeScreenshotEditor() {
        editorWindow?.close()
    }

    private func observeEditorWindow(_ window: NSWindow) {
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak window] _ in
                MosaicCache.shared.clear()
                // 关闭后释放原图和笔画；窗口外壳保留用于下次快速复用。
                DispatchQueue.main.async {
                    window?.contentViewController = nil
                }
            }
            .store(in: &observables)
    }

    // MARK: - 菜单

    /// 附件应用没有默认菜单；补一个最小菜单让日志等文本可复制。
    private func setupMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        appMenuItem.title = "ForgeSweep"
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.shared.t("menu.about"), action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = appMenu.addItem(withTitle: L10n.shared.t("settings.title"),
                                           action: #selector(openSettings(_:)),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L10n.shared.t("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: L10n.shared.t("menu.edit"))
        editMenu.addItem(withTitle: L10n.shared.t("menu.copy"), action: NSSelectorFromString("copy:"), keyEquivalent: "c")
        editMenu.addItem(withTitle: L10n.shared.t("menu.selectAll"), action: NSSelectorFromString("selectAll:"), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApp.menu = mainMenu
    }

    @objc private func openSettings(_ sender: Any?) {
        showMainWindow()
        DispatchQueue.main.async { [weak self] in
            self?.appState.showSettingsSheet = true
        }
    }

    private func menuBarIcon(size: NSSize) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "MenuBarIconTemplate", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.size = size
        image.isTemplate = true
        return image
    }

    // MARK: - 快捷面板

    @objc private func toggleQuickPanel(_ sender: Any?) {
        if let quickPanel, quickPanel.isVisible {
            quickPanel.orderOut(nil)
            return
        }
        showQuickPanel()
    }

    private func showQuickPanel() {
        if quickPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 284, height: 260),
                                styleMask: [.borderless, .utilityWindow],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.hidesOnDeactivate = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.appearance = NSAppearance(named: .darkAqua)
            panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces]
            let content = QuickPanelView(state: appState,
                                         onOpenMain: { [weak self] in
                                             self?.showMainWindow()
                                         },
                                         onQuit: { NSApp.terminate(nil) },
                                         onHeightChange: { [weak self] height in
                                             guard let panel = self?.quickPanel else { return }
                                             let newHeight = ceil(height) + 1
                                             guard abs(panel.frame.height - newHeight) > 1 else { return }
                                             panel.setContentSize(NSSize(width: 284, height: newHeight))
                                             self?.positionQuickPanel(panel)
                                         })
            panel.contentViewController = NSHostingController(rootView: content)
            quickPanel = panel
        }
        guard let quickPanel else { return }
        appState.refreshMetrics()
        appState.refreshTopMemoryApps(force: true)
        // 点击图标只看快捷面板：主窗口若开着先收起。
        if let mainWindow, mainWindow.isVisible {
            mainWindow.orderOut(nil)
        }
        let fitting = quickPanel.contentViewController?.view.fittingSize ?? NSSize(width: 284, height: 260)
        quickPanel.setContentSize(NSSize(width: ceil(fitting.width), height: ceil(fitting.height)))
        positionQuickPanel(quickPanel)
        quickPanel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func positionQuickPanel(_ panel: NSPanel) {
        guard let button = statusItem?.button,
              let statusWindow = button.window,
              let screen = statusWindow.screen else { return }
        let buttonFrame = statusWindow.convertToScreen(button.frame)
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size
        var origin = NSPoint(x: NSMidX(buttonFrame) - panelSize.width / 2,
                             y: NSMinY(buttonFrame) - panelSize.height - 8)
        if origin.y < NSMinY(screenFrame) + 8 {
            origin.y = NSMaxY(buttonFrame) + 8
        }
        origin.x = max(NSMinX(screenFrame) + 8, min(origin.x, NSMaxX(screenFrame) - panelSize.width - 8))
        panel.setFrameOrigin(origin)
    }

    // MARK: - 主窗口

    func showMainWindow() {
        quickPanel?.orderOut(nil)
        if mainWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 720),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 680, height: 620)
            // 深色玻璃基调：内容延伸进标题栏（fullSizeContentView），标题栏透明，
            // DarkGlassSurface 贯通整窗；标题/交通灯/工具栏按钮浮在玻璃上。
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.appearance = NSAppearance(named: .darkAqua)
            // 系统标题文字由 SwiftUI 头部替代。
            window.title = ""
            window.contentView = NSHostingView(rootView: MainWindowView(state: appState))
            window.center()
            observeMainWindow(window)
            mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func observeMainWindow(_ window: NSWindow) {
        NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification, object: window)
            .sink { [weak self] _ in self?.appState.mainWindowVisible = true }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
            .sink { [weak self] _ in self?.appState.mainWindowVisible = false }
            .store(in: &observables)
        NotificationCenter.default.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in self?.appState.mainWindowVisible = false }
            .store(in: &observables)
    }

    private var observables: Set<AnyCancellable> = []
}
