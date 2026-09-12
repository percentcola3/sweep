import SwiftUI

/// 进程清理：默认 NSWorkspace 应用级视图，高级模式走 ps 桥接并按进程树聚合。
struct ProcessesTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Spacer()
                Toggle(l10n.t("proc.advanced"), isOn: $state.advancedProcesses)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .font(.system(size: 11))
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                if state.runtimeInFlight && state.advancedProcesses {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(state.processActionStatus.isEmpty ? state.processStatus : state.processActionStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if state.processRows.isEmpty {
                EmptyStateView(symbol: "cpu",
                               title: state.advancedProcesses
                                 ? state.processStatus : l10n.t("proc.status.none"),
                               subtitle: state.advancedProcesses ? nil : l10n.t("proc.status.systemHint"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.processRows) { row in
                            HStack(spacing: 8) {
                                if row.isNativeApp {
                                    ProcessAppIcon(row: row,
                                                   size: 26,
                                                   fallbackSystemName: "app.fill",
                                                   fallbackTint: Color.moleAccentText,
                                                   validatesNativeStartIdentity: true)
                                } else {
                                    Image(systemName: "terminal.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(row.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        if row.lifecycle != .normal {
                                            ProcessLifecycleBadge(lifecycle: row.lifecycle)
                                        }
                                    }
                                    Text(row.detail)
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                ProcessMetric(label: "CPU",
                                              value: String(format: "%.1f%%", row.cpu),
                                              isElevated: row.cpu >= 50)
                                ProcessMetric(label: l10n.t("proc.memory"),
                                              value: row.memBytes > 0
                                                ? ByteFormat.short(row.memBytes) : "--",
                                              isElevated: row.mem >= 20)
                                Button(row.lifecycle == .normal
                                       ? l10n.t("proc.kill")
                                       : l10n.t("proc.cleanupStale")) {
                                    state.terminateProcess(row)
                                }
                                    .buttonStyle(DangerButtonStyle())
                                    .disabled(state.isBusy || state.runtimeInFlight)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

private struct ProcessLifecycleBadge: View {
    let lifecycle: ProcessLifecycle
    @ObservedObject private var l10n = L10n.shared

    private var label: String {
        switch lifecycle {
        case .zombie: return l10n.t("proc.badge.zombie")
        case .exiting: return l10n.t("proc.badge.exiting")
        case .normal: return ""
        }
    }

    private var tint: Color {
        switch lifecycle {
        case .zombie: return .red
        case .exiting: return .orange
        case .normal: return .secondary
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 17)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1))
            .fixedSize()
    }
}

private struct ProcessMetric: View {
    let label: String
    let value: String
    let isElevated: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isElevated ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
        .frame(width: 62, alignment: .trailing)
    }
}

/// 端口清理：lsof 监听列表 + 关闭对应进程。
struct PortsTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            HStack(spacing: 6) {
                if state.runtimeInFlight {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(state.portStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if state.portRows.isEmpty {
                EmptyStateView(symbol: "network",
                               title: state.runtimeInFlight ? l10n.t("ports.status.reading") : l10n.t("ports.status.none"),
                               subtitle: nil)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(state.portRows) { row in
                            HStack(spacing: 8) {
                                Image(systemName: "dot.radiowaves.left.and.right")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.moleAccentText)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(l10n.tf("ports.row", row.port, row.command))
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(row.endpoint) · PID \(row.pid)")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button(l10n.t("ports.close")) { state.closePort(row) }
                                    .buttonStyle(DangerButtonStyle())
                                    .disabled(state.isBusy)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.4), lineWidth: 1))
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }
        }
    }
}
