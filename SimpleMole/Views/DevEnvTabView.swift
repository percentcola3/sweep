import SwiftUI

/// 开发环境：识别版本管理器下的运行时版本（含使用中标记）与工具本体，
/// 支持勾选清理不再使用的旧版本（移入废纸篓）。
struct DevEnvTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Spacer()
                Menu {
                    Button {
                        state.showSimulatorDevices = true
                    } label: {
                        Label(l10n.t("sim.title"), systemImage: "iphone.gen3")
                    }
                    Button {
                        state.showDockerDetails = true
                    } label: {
                        Label(l10n.t("docker.details.title"), systemImage: "shippingbox.circle")
                    }
                } label: {
                    Label(l10n.t("devenv.resourceManagers"), systemImage: "square.grid.2x2")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button { state.scanDevEnv() } label: {
                    Label(state.isScanningEnv ? l10n.t("common.scanning") : l10n.t("common.rescan"),
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.isBusy)
                Button {
                    state.jump(to: .cleanup)
                    state.scanDeveloperTools()
                } label: {
                    Label(l10n.t("devenv.manageCli"), systemImage: "shippingbox.fill")
                }
                .buttonStyle(SecondaryButtonStyle())
                .labelStyle(.iconOnly)
                .help(l10n.t("devenv.manageCli"))
                .disabled(state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .sheet(isPresented: $state.showSimulatorDevices) {
                SimulatorDevicesView(store: state.simulatorInventory,
                                     canMutate: !state.isBusy)
            }

            HStack(spacing: 6) {
                if state.isScanningEnv { ProgressView().controlSize(.mini) }
                Text(state.devEnvStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .sheet(isPresented: $state.showDockerDetails) {
                DockerDetailsView(store: state.dockerInventory)
            }

            if state.devEnvEntries.isEmpty && state.gcActions.isEmpty {
                EmptyStateView(symbol: "cpu",
                               title: state.isScanningEnv ? l10n.t("devenv.status.scanning") : l10n.t("devenv.status.empty"),
                               subtitle: state.isScanningEnv ? nil : l10n.t("devenv.empty.subtitle"))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(state.devEnvManagers, id: \.manager) { group in
                            VStack(alignment: .leading, spacing: 4) {
                                sectionHeader(title: group.manager,
                                              count: group.entries.count,
                                              bytes: group.entries.reduce(0) { $0 + $1.bytes })
                                ForEach(group.entries) { entry in
                                    DevEnvRowView(entry: entry, isSelected: state.devEnvSelection.contains(entry.path)) {
                                        toggleSelection(entry)
                                    }
                                }
                            }
                        }
                        if !nodePackageGcActions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                sectionTitle(l10n.t("devenv.nodeCaches"))
                                ForEach(nodePackageGcActions) { action in
                                    GcActionRowView(action: action,
                                                    isRunning: state.gcRunningId == action.id,
                                                    anyRunning: state.gcRunningId != nil) {
                                        state.runGc(action)
                                    }
                                }
                                Text(l10n.t("devenv.nodeCaches.hint"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !state.devEnvManagerEntries.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                sectionHeader(title: l10n.t("devenv.tools"),
                                              count: state.devEnvManagerEntries.count,
                                              bytes: state.devEnvManagerEntries.reduce(0) { $0 + $1.bytes })
                                ForEach(state.devEnvManagerEntries) { entry in
                                    HStack(spacing: 8) {
                                        Image(systemName: "wrench.and.screwdriver")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Color.moleAccentText)
                                            .frame(width: 20)
                                        Text(entry.name)
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text(ByteFormat.format(entry.bytes))
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
                                }
                                Text(l10n.t("devenv.tools.hint"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !state.dockerDfRows.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Image(systemName: "shippingbox.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.moleAccentText)
                                    Text("Docker")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Button(l10n.t("docker.details.open")) {
                                        state.showDockerDetails = true
                                    }
                                    .buttonStyle(SecondaryButtonStyle())
                                    .controlSize(.small)
                                }
                                .padding(.horizontal, 4)
                                ForEach(state.dockerDfRows) { row in
                                    HStack(spacing: 8) {
                                        Text(row.type)
                                            .font(.system(size: 12, weight: .medium))
                                        Spacer()
                                        Text("\(row.count) · \(row.size)")
                                            .font(.system(size: 10).monospacedDigit())
                                            .foregroundStyle(.secondary)
                                        if row.reclaimable != "0B" && !row.reclaimable.isEmpty {
                                            SizeBadge(text: "\(row.reclaimable)")
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
                                }
                            }
                        }
                        if state.shellAudited {
                            VStack(alignment: .leading, spacing: 4) {
                                sectionTitle(l10n.t("audit.shell.title"))
                                if state.shellIssues.isEmpty {
                                    auditEmptyRow(l10n.t("audit.shell.empty"))
                                } else {
                                    ForEach(state.shellIssues) { issue in
                                        HStack(spacing: 8) {
                                            Text(issue.kind)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(issue.location)
                                                    .font(.system(size: 10, design: .monospaced))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                Text(issue.detail)
                                                    .font(.system(size: 9, design: .monospaced))
                                                    .foregroundStyle(.tertiary)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                            Spacer()
                                            Button {
                                                state.openInEditor(issue.file)
                                            } label: {
                                                Label(l10n.t("audit.open"), systemImage: "arrow.up.right")
                                            }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .controlSize(.small)
                                            .labelStyle(.iconOnly)
                                            .help(l10n.t("audit.open"))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
                                    }
                                }
                                Text(l10n.t("audit.shell.hint"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if state.netAudited {
                            VStack(alignment: .leading, spacing: 4) {
                                sectionTitle(l10n.t("audit.net.title"))
                                if state.netProxies.isEmpty && state.netHosts.isEmpty {
                                    auditEmptyRow(l10n.t("audit.net.empty"))
                                } else {
                                    ForEach(state.netProxies) { proxy in
                                        HStack(spacing: 8) {
                                            Text(proxy.kind)
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                                            Text(proxy.service)
                                                .font(.system(size: 12, weight: .medium))
                                            Spacer()
                                            Text(proxy.endpoint)
                                                .font(.system(size: 10).monospacedDigit())
                                                .foregroundStyle(.secondary)
                                            if state.netFixRunning {
                                                ProgressView().controlSize(.mini)
                                            } else {
                                                Button { state.disableProxy(proxy) } label: {
                                                    Label(l10n.t("audit.fixProxy"), systemImage: "xmark.shield")
                                                }
                                                .buttonStyle(SecondaryButtonStyle())
                                                .controlSize(.small)
                                                .labelStyle(.iconOnly)
                                                .help(l10n.t("audit.fixProxy"))
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
                                    }
                                    ForEach(state.netHosts, id: \.self) { line in
                                        HStack(spacing: 8) {
                                            Text("hosts")
                                                .font(.system(size: 9, weight: .semibold))
                                                .foregroundStyle(.orange)
                                                .padding(.horizontal, 5)
                                                .padding(.vertical, 1)
                                                .background(Capsule().fill(Color.orange.opacity(0.12)))
                                            Text(line)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                            Spacer()
                                            Button {
                                                state.openInEditor("/etc/hosts")
                                            } label: {
                                                Label(l10n.t("audit.open"), systemImage: "arrow.up.right")
                                            }
                                            .buttonStyle(SecondaryButtonStyle())
                                            .controlSize(.small)
                                            .labelStyle(.iconOnly)
                                            .help(l10n.t("audit.open"))
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
                                    }
                                }
                                Text(l10n.t("audit.net.hint"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        if !generalGcActions.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(l10n.t("gc.title"))
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 4)
                                ForEach(generalGcActions) { action in
                                    GcActionRowView(action: action,
                                                    isRunning: state.gcRunningId == action.id,
                                                    anyRunning: state.gcRunningId != nil) {
                                        state.runGc(action)
                                    }
                                }
                                Text(l10n.t("gc.subtitle"))
                                    .font(.system(size: 10))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
            }

            if !state.devEnvEntries.isEmpty {
                Divider()
                HStack {
                    Text(state.devEnvSelection.isEmpty
                         ? l10n.t("devenv.apply.hint")
                         : l10n.tf("devenv.apply.selected", state.devEnvSelection.count,
                                   ByteFormat.format(state.devEnvSelectedBytes)))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { state.applyDevEnvCleanup() } label: {
                        Label(l10n.t("devenv.apply"), systemImage: "trash.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .labelStyle(.iconOnly)
                    .help(l10n.t("devenv.apply"))
                    .disabled(state.devEnvSelection.isEmpty || state.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var nodePackageGcActions: [GcAction] {
        state.gcActions.filter { ["npm", "pnpm", "yarn"].contains($0.id) }
    }

    private var generalGcActions: [GcAction] {
        state.gcActions.filter { !["npm", "pnpm", "yarn"].contains($0.id) }
    }

    private func toggleSelection(_ entry: DevEnvEntry) {
        guard entry.kind == "runtime" else { return }
        if state.devEnvSelection.contains(entry.path) {
            state.devEnvSelection.remove(entry.path)
        } else {
            state.devEnvSelection.insert(entry.path)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }

    private func auditEmptyRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.035)))
    }

    private func sectionHeader(title: String, count: Int, bytes: UInt64) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(l10n.tf("devenv.versions", count, ByteFormat.format(bytes)))
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 4)
    }
}

/// 官方 GC 命令行：工具名 + 命令原文，右侧运行按钮。
private struct GcActionRowView: View {
    let action: GcAction
    let isRunning: Bool
    let anyRunning: Bool
    let onRun: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(action.id)
                    .font(.system(size: 12, weight: .medium))
                Text(action.command)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.mini)
            } else {
                if action.bytes > 0 {
                    SizeBadge(text: ByteFormat.format(action.bytes))
                }
                Button(action: onRun) { Label(l10n.t("gc.run"), systemImage: "play.fill") }
                    .buttonStyle(SecondaryButtonStyle())
                    .controlSize(.small)
                    .disabled(anyRunning)
                    .labelStyle(.iconOnly)
                    .help(l10n.t("gc.run"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.045)))
    }
}

private struct DevEnvRowView: View {
    let entry: DevEnvEntry
    let isSelected: Bool
    let onToggle: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Group {
                    if entry.isCurrent {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                            .frame(width: 16)
                    } else {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(isSelected
                                ? AnyShapeStyle(Color.moleAccentText) : AnyShapeStyle(.tertiary))
                            .frame(width: 16)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.versionLabel.isEmpty ? entry.name : entry.versionLabel)
                        .font(.system(size: 12, weight: .medium))
                    Text(entry.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if entry.isBuiltin {
                    Text(l10n.t("devenv.builtin"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                } else if entry.isCurrent {
                    Text(l10n.t("devenv.current"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange.opacity(0.8)))
                }
                if entry.hasVersionGlobalPackages {
                    Text(l10n.tf("devenv.globalPackages", ByteFormat.format(entry.relatedBytes)))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.quaternary))
                        .help(entry.relatedPath ?? "")
                }
                SizeBadge(text: ByteFormat.format(entry.bytes), prominent: isSelected)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MoleSelectableRowButtonStyle(
            isSelected: isSelected,
            verticalPadding: 7))
    }
}

/// 白名单管理：直接维护 Mole 引擎共用的 `~/.config/mole/whitelist`。
struct WhitelistSheet: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var newPath = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(l10n.t("wl.title"))
                        .font(.system(size: 14, weight: .semibold))
                    Text(l10n.t("wl.subtitle"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(l10n.t("common.done")) { state.showWhitelistSheet = false }
                    .buttonStyle(PrimaryButtonStyle())
                Button {
                    state.showWhitelistSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(16)

            ScrollView {
                LazyVStack(spacing: 4) {
                    if state.whitelistEntries.isEmpty {
                        VStack(spacing: 6) {
                            Image(systemName: "shield")
                                .font(.system(size: 22, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text(l10n.t("wl.empty.title"))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                            Text(l10n.t("wl.empty.subtitle"))
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 24)
                    }
                    ForEach(state.whitelistEntries, id: \.self) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "shield.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.moleAccentText)
                            Text(entry)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                state.removeWhitelistEntry(entry)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
                    }
                }
                .padding(.horizontal, 16)
            }

            Divider()
            HStack(spacing: 8) {
                TextField(l10n.t("wl.add.placeholder"), text: $newPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                Button {
                    state.addWhitelistEntry(newPath)
                    newPath = ""
                } label: {
                    Label(l10n.t("wl.add"), systemImage: "plus")
                }
                .buttonStyle(SecondaryButtonStyle())
                .labelStyle(.iconOnly)
                .help(l10n.t("wl.add"))
                .disabled(!newPath.trimmingCharacters(in: .whitespaces).hasPrefix("/"))
            }
            .padding(16)
        }
        .frame(width: 520, height: 420)
        .onAppear { state.loadWhitelist() }
    }
}
