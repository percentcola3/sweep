import SwiftUI

/// 主窗口：标题与指标卡 → 胶囊导航 → 功能页。
/// 每个视图持有 L10n 引用，语言切换即时重绘。
struct MainWindowView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var headerPanel: HeaderPanel?

    private enum HeaderPanel: Equatable {
        case language
        case automation
    }

    private var tabs: [String] {
        state.visiblePages.map { l10n.t($0.titleKey) }
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                titleBarRow
                metricBar
                    // 权限中心挂在独立子视图节点：与其他 sheet 分开，避免多 sheet 同节点时 dismiss 绑定失联。
                    .sheet(isPresented: $state.showPermissionCenter) {
                        PermissionCenterView(state: state)
                    }
                    .sheet(isPresented: $state.showAutoCleanupSheet) {
                        AutoCleanupRulesView(state: state)
                    }
                Divider()
                PillPicker(items: tabs, selection: $state.selectedTab)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .sheet(isPresented: $state.showAutomationSettings) {
                        AutomationSettingsView(
                            locations: state.savedScanLocations,
                            automations: state.smartAutomation,
                            receipts: state.projectHibernation.receiptStore,
                            projectRadar: state.projectRadar,
                            hibernation: state.projectHibernation,
                            authorizedLocationIDs: state.automationAuthorizedLocationIDs,
                            fullDiskAccessGranted: state.permissionCenter.fullDiskAccessGranted,
                            canMutate: !state.isBusy,
                            onAddLocation: { state.addSavedScanLocation() },
                            onRestore: { state.restoreHibernatedProject($0) })
                    }
                Divider()
                AnimatedTabContent(state: state)
                    .frame(maxHeight: .infinity)
            }

            if let headerPanel {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { dismissHeaderPanel() }
                    .zIndex(1)

                headerFloatingPanel(headerPanel)
                    .padding(.top, 42)
                    .padding(.trailing, 16)
                    .transition(.moleFloatingPanel)
                    .zIndex(2)
            }

            if state.showSettingsSheet {
                Color.black.opacity(0.30)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { state.showSettingsSheet = false }
                    .transition(.opacity)
                    .zIndex(3)

                SettingsSheet(state: state)
                    .background(DarkGlassSurface(cornerRadius: 18, usesSystemGlass: true))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
                    .shadow(color: .black.opacity(0.38), radius: 34, y: 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .transition(.moleFloatingPanel)
                    .zIndex(4)
            }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 620, idealHeight: 720)
        .background {
            DarkGlassSurface()
                .ignoresSafeArea()
        }
        // 内容上移进标题栏区域：交通灯与标题/按钮同排（titleBarRow 左侧已留交通灯空位）。
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: headerPanel)
        .animation(reduceMotion ? nil : MoleMotion.panel, value: state.showSettingsSheet)
        .onExitCommand {
            if state.showSettingsSheet { state.showSettingsSheet = false }
            else { dismissHeaderPanel() }
        }
        .sheet(isPresented: $state.showWhitelistSheet) {
            WhitelistSheet(state: state)
        }
        .alert(confirmationTitle,
               isPresented: confirmationBinding) {
            Button(confirmationAction, role: .destructive) { runConfirmation() }
            Button(l10n.t("common.cancel"), role: .cancel) { state.confirmation = nil }
        } message: {
            Text(state.confirmation?.message ?? "")
        }
        .confirmationDialog(l10n.t("confirm.slimChoice.title"),
                            isPresented: slimBinding,
                            titleVisibility: .visible) {
            Button(l10n.t("confirm.slimChoice.replace")) { runSlim("replace") }
            Button(l10n.t("confirm.slimChoice.copy")) { runSlim("copy") }
            Button(l10n.t("common.cancel"), role: .cancel) { state.slimRequest = nil }
        } message: {
            Text(l10n.t("confirm.slimChoice.msg"))
        }
    }

    /// 顶部工具排：标题（左）+ 四个同款胶囊按钮（右），两端对齐。
    private var titleBarRow: some View {
        HStack(spacing: 8) {
            // 避开交通灯区域
            Color.clear.frame(width: 66, height: 1)
            HeaderBrandIconView(size: 20,
                                isSearching: state.isScanning,
                                searchSucceeded: state.cleanupScanComplete)
            Text(l10n.t("window.title"))
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            HStack(spacing: 8) {
                languageButton
                automationButton
                Button { state.showWhitelistSheet = true } label: {
                    Label(l10n.t("header.whitelist"), systemImage: "shield.lefthalf.filled")
                }
                .labelStyle(.iconOnly)
                .help(l10n.t("header.whitelist"))
                .buttonStyle(TitleBarButtonStyle())
                Button {
                    headerPanel = nil
                    state.showSettingsSheet = true
                } label: {
                    Label(l10n.t("settings.title"), systemImage: "gearshape")
                }
                .labelStyle(.iconOnly)
                .help(l10n.t("settings.title"))
                .buttonStyle(TitleBarButtonStyle())
            }
            // 按钮玻璃合成范围略大于布局框，做独立光学校正，避免贴住顶边。
            .offset(y: 4)
        }
        // 固定标题栏内容槽：小按钮在槽内居中，不再贴住窗口顶边。
        .frame(height: 28)
        .padding(.leading, 10)
        .padding(.trailing, 26)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    private var languageButton: some View {
        Button { toggleHeaderPanel(.language) } label: {
            Label(l10n.t("header.language"), systemImage: "globe")
        }
        .labelStyle(.iconOnly)
        .help(l10n.t("header.language"))
        .buttonStyle(TitleBarButtonStyle(isActive: headerPanel == .language))
    }

    private var automationButton: some View {
        Button { toggleHeaderPanel(.automation) } label: {
            Label(l10n.t("automation.menu"), systemImage: "clock.arrow.circlepath")
        }
        .labelStyle(.iconOnly)
        .help(l10n.t("automation.menu"))
        .buttonStyle(TitleBarButtonStyle(isActive: headerPanel == .automation))
    }

    @ViewBuilder
    private func headerFloatingPanel(_ panel: HeaderPanel) -> some View {
        switch panel {
        case .language:
            VStack(spacing: 3) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        L10n.shared.setLanguage(language)
                        dismissHeaderPanel()
                    } label: {
                        HStack(spacing: 9) {
                            Text(language.displayName)
                                .lineLimit(1)
                            Spacer(minLength: 12)
                            Image(systemName: "checkmark")
                                .opacity(L10n.shared.language == language ? 1 : 0)
                        }
                        .font(.system(size: 11, weight: L10n.shared.language == language ? .semibold : .regular))
                        .foregroundStyle(L10n.shared.language == language ? Color.primary : Color.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 27)
                        .background(RoundedRectangle(cornerRadius: 7)
                            .fill(L10n.shared.language == language
                                  ? Color.moleAccent.opacity(0.16) : Color.clear))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 176)
            .background(DarkGlassSurface(cornerRadius: 12, usesSystemGlass: true))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.34), radius: 18, y: 8)

        case .automation:
            VStack(spacing: 3) {
                headerPanelAction(l10n.t("auto.header"), symbol: "folder.badge.clock") {
                    dismissHeaderPanel()
                    state.showAutoCleanupSheet = true
                }
                headerPanelAction(l10n.t("automation.header"), symbol: "gearshape.2") {
                    dismissHeaderPanel()
                    state.openAutomationSettings()
                }
            }
            .padding(6)
            .frame(width: 210)
            .background(DarkGlassSurface(cornerRadius: 12, usesSystemGlass: true))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.34), radius: 18, y: 8)
        }
    }

    private func headerPanelAction(_ title: String, symbol: String,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 29)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.055)))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func toggleHeaderPanel(_ panel: HeaderPanel) {
        state.showSettingsSheet = false
        headerPanel = headerPanel == panel ? nil : panel
    }

    private func dismissHeaderPanel() {
        headerPanel = nil
    }

    private var metricBar: some View {
        MetricBar(items: [
            .init(title: l10n.t("metric.cleanable"), symbol: "trash",
                  value: state.selectedCount > 0 ? ByteFormat.format(state.selectedBytes) : l10n.t("metric.pending")),
            .init(title: l10n.t("metric.memory"), symbol: "memorychip",
                  value: String(format: "%.0f%%", state.metrics.memoryPercent),
                  progress: state.metrics.memoryPercent / 100),
            .init(title: l10n.t("metric.disk"), symbol: "internaldrive",
                  value: state.metrics.diskFreeBytes > 0 ? ByteFormat.format(state.metrics.diskFreeBytes) : "--",
                  progress: state.metrics.diskUsedPercent / 100),
            .init(title: l10n.t("metric.network"), symbol: "network",
                  value: String(format: "↓%.1f ↑%.1f", state.metrics.networkRxMBps, state.metrics.networkTxMBps),
                  sparkline: state.networkHistory),
        ])
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: 弹窗绑定

    private var confirmationTitle: String { state.confirmation?.title ?? "" }
    private var confirmationAction: String { state.confirmation?.confirmLabel ?? l10n.t("common.done") }

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { state.confirmation != nil },
                set: { if !$0 { state.confirmation = nil } })
    }

    private var slimBinding: Binding<Bool> {
        Binding(get: { state.slimRequest != nil },
                set: { if !$0 { state.slimRequest = nil } })
    }

    /// 先关闭弹窗再异步执行确认动作，保证动作里再弹出的下一层确认框能正常呈现。
    private func runConfirmation() {
        state.runConfirmation()
    }

    private func runSlim(_ mode: String) {
        let request = state.slimRequest
        state.slimRequest = nil
        DispatchQueue.main.async { request?(mode) }
    }
}

/// 业务选择仍由 AppState 即时驱动；这里单独保存呈现中的页面，让导航玻璃先流动、
/// 内容随后按方向轻量过渡。连续点击会直接改向，不排队也不阻塞业务扫描。
private struct AnimatedTabContent: View {
    @ObservedObject private var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var presentedTab: Int
    @State private var direction: CGFloat = 1

    init(state: AppState) {
        _state = ObservedObject(wrappedValue: state)
        _presentedTab = State(initialValue: state.selectedTab)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            page(for: presentedTab)
                .id(presentedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onChange(of: state.selectedTab) { next in
            present(next)
        }
    }

    @ViewBuilder
    private func page(for tab: Int) -> some View {
        if tab < state.visiblePages.count {
            switch state.visiblePages[tab] {
            case .cleanup: CleanupTabView(state: state)
            case .analyze: AnalyzeTabView(state: state)
            case .uninstall: UninstallTabView(state: state)
            case .optimize: OptimizeTabView(state: state)
            case .system: SystemDataView(state: state)
            case .devenv: DevEnvTabView(state: state)
            case .processes: ProcessesTabView(state: state)
            case .ports: PortsTabView(state: state)
            case .images: ImagesTabView(state: state)
            case .clipboard: ClipboardHistoryTabView(manager: state.clipboardManager)
            }
        } else {
            EmptyView()
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }

        return .asymmetric(
            insertion: .modifier(
                active: TabPageMotion(x: direction * 28, opacity: 0),
                identity: TabPageMotion(x: 0, opacity: 1)
            ),
            removal: .modifier(
                active: TabPageMotion(x: -direction * 18, opacity: 0),
                identity: TabPageMotion(x: 0, opacity: 1)
            )
        )
    }

    private func present(_ next: Int) {
        guard next != presentedTab else { return }
        let nextDirection: CGFloat = next > presentedTab ? 1 : -1

        let animation: Animation = reduceMotion
            ? .easeOut(duration: 0.12)
            : .timingCurve(0.20, 0.78, 0.20, 1, duration: 0.40)
        withAnimation(animation) {
            direction = nextDirection
            presentedTab = next
        }
    }
}

private struct TabPageMotion: ViewModifier {
    let x: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(x: x)
            .opacity(opacity)
    }
}
