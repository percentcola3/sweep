import SwiftUI

/// 菜单栏快捷面板：环形指标双卡 + 内存占用榜（悬停强杀）+ 一键优化。
struct QuickPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    var onOpenMain: () -> Void
    var onQuit: () -> Void
    /// 内容高度变化回传（内存榜异步加载后面板需随之增高）。
    var onHeightChange: (CGFloat) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 0) {
                QuickRingCard(title: l10n.t("qp.cpu"),
                              centerText: String(format: "%.0f%%", state.metrics.cpuPercent),
                              progress: state.metrics.cpuPercent / 100)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1, height: 72)

                QuickRingCard(title: memoryTitle,
                              centerText: ByteFormat.memoryShort(state.metrics.memoryUsedBytes),
                              progress: state.metrics.memoryPercent / 100)
            }
            .background(QuickPanelSectionSurface(cornerRadius: 14))

            if !state.topMemoryApps.isEmpty {
                VStack(spacing: 0) {
                    Text(l10n.t("qp.topMemory"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 11)
                        .padding(.top, 9)
                        .padding(.bottom, 7)

                    ForEach(Array(state.topMemoryApps.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(Color.white.opacity(0.055))
                                .frame(height: 1)
                                .padding(.leading, 37)
                        }
                        TopMemoryRow(row: row) { state.forceQuitTopApp(row) }
                    }
                }
                .background(QuickPanelSectionSurface(cornerRadius: 12))
            }

            Button {
                onOpenMain()
                DispatchQueue.main.async {
                    state.requestQuickOptimizeFromQuickPanel()
                }
            } label: {
                HStack(spacing: 7) {
                    if state.isScanning || state.isApplying {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color.moleOnAccent)
                    } else {
                        Image(systemName: "sparkles")
                    }
                    Text(quickActionTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuickActionButtonStyle())
            .disabled(state.isScanning || state.isApplying)

            HStack {
                Button { onOpenMain() } label: {
                    Text(l10n.t("common.more"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                Button { onQuit() } label: {
                    Text(l10n.t("common.quit"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(width: 284)
        .background {
            DarkGlassSurface(cornerRadius: 18, usesSystemGlass: true)
        }
        .preferredColorScheme(.dark)
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: QuickPanelHeightKey.self, value: geo.size.height)
            }
        )
        .onPreferenceChange(QuickPanelHeightKey.self) { height in
            onHeightChange(height)
        }
        .onAppear { state.refreshTopMemoryApps() }
    }

    private struct QuickPanelHeightKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    /// 内存卡副标题：总量参照（如 "/ 24G"）。
    private var memoryTitle: String {
        guard state.metrics.memoryTotalBytes > 0 else { return l10n.t("qp.mem") }
        return "\(l10n.t("qp.mem")) / \(ByteFormat.memoryShort(state.metrics.memoryTotalBytes))"
    }

    private var quickActionTitle: String {
        if state.isApplying { return l10n.t("cleanup.apply.busy") }
        if state.isScanning { return l10n.t("common.scanning") }
        return l10n.t("qp.optimize")
    }
}

/// 快捷面板分组表面：统一承载指标与榜单，避免堆叠厚重的小卡片。
private struct QuickPanelSectionSurface: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.white.opacity(0.075), Color.white.opacity(0.032)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [Color.white.opacity(0.13), Color.white.opacity(0.035)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(0.16), radius: 7, y: 3)
    }
}

/// 环形指标卡：共享同一表面与中间分隔，保持紧凑的仪表层级。
private struct QuickRingCard: View {
    let title: String
    let centerText: String
    let progress: Double

    var body: some View {
        VStack(spacing: 7) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.09), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, progress))))
                    .stroke(Color.moleAccent, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(centerText)
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 8)
            }
            .frame(width: 56, height: 56)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
    }
}

/// 内存占用最高行：应用图标 + 名称 + 占用字节；悬停出现强杀按钮。
private struct TopMemoryRow: View {
    let row: ProcessRow
    let onForceQuit: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    @State private var actionHovered = false
    @FocusState private var actionFocused: Bool

    private var actionVisible: Bool { hovered || actionFocused }

    var body: some View {
        HStack(spacing: 8) {
            ProcessAppIcon(row: row,
                           size: 18,
                           fallbackSystemName: "app.fill",
                           fallbackTint: Color.secondary.opacity(0.6),
                           validatesNativeStartIdentity: false)
            Text(row.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            ZStack(alignment: .trailing) {
                Text(ByteFormat.memoryShort(row.memBytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .opacity(actionVisible ? 0 : 1)

                Button(role: .destructive, action: onForceQuit) {
                    ZStack {
                        Circle()
                            .fill(actionHovered
                                  ? Color.moleAccent
                                  : Color.moleAccent.opacity(0.14))
                        Circle()
                            .strokeBorder(Color.moleAccentText.opacity(actionHovered ? 0.75 : 0.34),
                                          lineWidth: 1)
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(actionHovered
                                             ? Color.moleOnAccent
                                             : Color.moleAccentText)
                    }
                    .frame(width: 20, height: 20)
                    .shadow(color: Color.moleAccent.opacity(actionHovered ? 0.24 : 0),
                            radius: 5, y: 1)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.shared.t("proc.kill"))
                .accessibilityLabel(L10n.shared.t("proc.kill"))
                .accessibilityHint(L10n.shared.tf("proc.confirm.kill.msg", row.pid))
                .focused($actionFocused)
                .opacity(actionVisible ? 1 : 0)
                .scaleEffect(reduceMotion ? 1
                             : (actionVisible ? (actionHovered ? 1.05 : 1) : 0.84))
                .allowsHitTesting(actionVisible)
                .onHover { hovering in
                    withAnimation(reduceMotion ? nil : MoleMotion.control) {
                        actionHovered = hovering
                    }
                }
            }
            .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.moleAccent.opacity(actionVisible ? 0.095 : 0),
                            Color.moleAccent.opacity(actionVisible ? 0.035 : 0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.moleAccentText.opacity(actionVisible ? 0.14 : 0),
                                      lineWidth: 1)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : MoleMotion.control) {
                hovered = hovering
                if !hovering { actionHovered = false }
            }
        }
    }
}
