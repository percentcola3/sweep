import SwiftUI

/// 原生系统维护：每项操作独立执行并显示结果。
struct OptimizeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("optimize.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(l10n.t("optimize.subtitle"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button {
                    state.requestScanAccess(.optimize)
                } label: {
                    Label(state.isOptimizing ? l10n.t("common.scanning") : l10n.t("optimize.run"),
                          systemImage: "wand.and.stars")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                if state.isOptimizing { ProgressView().controlSize(.mini) }
                Text(state.optimizeStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(state.optimizeTasks) { task in
                        taskRow(task)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }

    private func taskRow(_ task: NativeCore.OptimizeTask) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(for: task.id))
                .font(.system(size: 13))
                .foregroundStyle(color(for: task.state))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(localizedTitle(task))
                    .font(.system(size: 12, weight: .medium))
                Text(localizedDetail(task))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                if !task.message.isEmpty {
                    Text(task.message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(stateLabel(task.state))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color(for: task.state))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
    }

    private func localizedTitle(_ task: NativeCore.OptimizeTask) -> String {
        let key = "optimize.task.\(task.id).title"
        let value = l10n.t(key)
        return value == key ? task.title : value
    }

    private func localizedDetail(_ task: NativeCore.OptimizeTask) -> String {
        let key = "optimize.task.\(task.id).detail"
        let value = l10n.t(key)
        return value == key ? task.detail : value
    }

    private func stateLabel(_ state: NativeCore.OptimizeTask.State) -> String {
        let key = "optimize.state.\(state.rawValue)"
        let value = l10n.t(key)
        return value == key ? state.rawValue.capitalized : value
    }

    private func color(for state: NativeCore.OptimizeTask.State) -> Color {
        switch state {
        case .applied: return .green
        case .failed: return .red
        case .unavailable: return .orange
        case .unchanged: return .secondary
        case .pending: return .moleAccentText
        }
    }

    private func icon(for id: String) -> String {
        switch id {
        case "dns": return "network"
        case "quicklook": return "doc.richtext"
        case "iconservices": return "app.dashed"
        case "launchservices": return "square.grid.2x2"
        case "saved-state": return "clock.arrow.circlepath"
        case "finder-dsstore": return "folder.badge.gearshape"
        case "network-stack": return "arrow.triangle.2.circlepath"
        case "sqlite-vacuum": return "cylinder.split.1x2"
        case "spotlight": return "magnifyingglass"
        case "spotlight-orphans": return "magnifyingglass.circle"
        case "disk-verify": return "externaldrive.badge.checkmark"
        case "login-items": return "person.crop.circle.badge.checkmark"
        case "launch-agents": return "bolt.horizontal.circle"
        case "notifications": return "bell.badge"
        case "permissions": return "lock.shield"
        default: return "gearshape"
        }
    }
}
