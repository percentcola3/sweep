import SwiftUI

/// 系统数据页：root 拥有的日志、报告与缓存的分组清单。
/// 布局对齐参考设计：标题行（勾选安全项 / 重新扫描）→ 摘要条（剩余 · 发现）
/// → 分组小计 → 行级勾选、风险徽章、容量、定位与单行删除 → 底部本次回收。
struct SystemDataView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared
    @State private var collapsedGroups: Set<SystemDataGroupKind> = []

    private struct SystemGroup: Identifiable {
        let kind: SystemDataGroupKind
        let entries: [SystemDataEntry]
        var id: String { kind.rawValue }
    }

    /// 按 SystemDataGroupKind 固定顺序输出非空分组，组内按容量降序。
    private var groups: [SystemGroup] {
        SystemDataGroupKind.allCases.compactMap { kind in
            let entries = state.systemEntries
                .filter { $0.group == kind }
                .sorted { $0.bytes != $1.bytes ? $0.bytes > $1.bytes : $0.name < $1.name }
            return entries.isEmpty ? nil : SystemGroup(kind: kind, entries: entries)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            summaryBar
            Divider().opacity(0.4)
            content
            if state.systemHasResult {
                footer
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: 标题行

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(l10n.t("system.title"))
                    .font(.system(size: 13, weight: .semibold))
                Text(l10n.t("system.subtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if state.systemHasResult {
                Button {
                    state.selectSafeSystemEntries()
                } label: {
                    Label(l10n.t("system.selectSafe"), systemImage: "checkmark.shield")
                }
                .buttonStyle(SecondaryButtonStyle(tint: .green))
                .disabled(state.isBusy || state.systemEntries.isEmpty)
            }
            Button {
                state.requestScanAccess(.systemScan)
            } label: {
                Label(state.systemScanning ? l10n.t("common.scanning")
                                            : l10n.t("system.rescan"),
                      systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(state.isBusy)
        }
        .padding(.bottom, 10)
    }

    // MARK: 摘要条

    private var summaryBar: some View {
        HStack(spacing: 6) {
            if state.systemScanning {
                ProgressView().controlSize(.mini)
            }
            Text(state.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            if state.systemHasResult {
                Text(l10n.tf("system.summary",
                             ByteFormat.format(state.metrics.diskFreeBytes),
                             ByteFormat.format(state.systemFoundBytes)))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: 内容区

    @ViewBuilder
    private var content: some View {
        if !state.systemHasResult {
            hero
        } else if state.systemEntries.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(l10n.t("system.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(groups) { group in
                        groupSection(group.kind, entries: group.entries)
                    }
                }
                .padding(.vertical, 8)
            }
        }
    }

    /// 从未扫描过的首屏：一次显式扫描按钮（每次扫描需要管理员授权）。
    private var hero: some View {
        VStack(spacing: 14) {
            if state.systemScanning {
                ProgressView().controlSize(.large)
                Text(l10n.t("status.systemScanning"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 30))
                    .foregroundStyle(Color.moleAccentText.opacity(0.7))
                VStack(spacing: 6) {
                    Text(l10n.t("system.hero.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(l10n.t("system.hero.msg"))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
                Button {
                    state.requestScanAccess(.systemScan)
                } label: {
                    Label(l10n.t("system.scan"), systemImage: "magnifyingglass")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isBusy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 分组

    private func groupSection(_ kind: SystemDataGroupKind,
                              entries: [SystemDataEntry]) -> some View {
        let isCollapsed = collapsedGroups.contains(kind)
        let total = entries.reduce(UInt64(0)) { $0 &+ $1.bytes }
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(MoleMotion.selection) {
                    if isCollapsed {
                        collapsedGroups.remove(kind)
                    } else {
                        collapsedGroups.insert(kind)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: kind.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.moleAccentText.opacity(0.85))
                    Text(l10n.t(kind.titleKey))
                        .font(.system(size: 12, weight: .semibold))
                    Text("— \(ByteFormat.format(total))")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(l10n.tf("system.group.items", entries.count))
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MolePlainButtonStyle())

            if !isCollapsed {
                VStack(spacing: 5) {
                    ForEach(entries) { entry in
                        SystemDataRow(entry: entry,
                                      selectionEnabled: !state.isBusy) {
                            state.toggleSystemEntry(entry.id)
                        } onReveal: {
                            state.revealSystemEntry(entry.path)
                        } onDelete: {
                            state.deleteSystemEntry(entry)
                        }
                    }
                }
            }
        }
        .padding(.bottom, 2)
    }

    // MARK: 底部

    private var footer: some View {
        HStack(spacing: 10) {
            Text(l10n.tf("system.reclaimed",
                         ByteFormat.format(state.systemSessionReclaimed)))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                state.applySystemCleanup()
            } label: {
                Label(applyLabel, systemImage: "trash.fill")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(state.systemSelectedCount == 0 || state.isBusy)
        }
        .padding(.top, 6)
    }

    private var applyLabel: String {
        if state.isApplying { return l10n.t("cleanup.apply.busy") }
        return l10n.tf("cleanup.delete.withCount", state.systemSelectedCount,
                       ByteFormat.format(state.systemSelectedBytes))
    }
}

/// 单行：勾选、名称/描述、风险徽章、容量、Finder 定位与单行删除。
private struct SystemDataRow: View {
    let entry: SystemDataEntry
    let selectionEnabled: Bool
    let onToggle: () -> Void
    let onReveal: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                ZStack {
                    Circle()
                        .strokeBorder(entry.selected ? Color.moleAccent : Color.secondary.opacity(0.55),
                                      lineWidth: 1.4)
                        .background(Circle().fill(entry.selected ? Color.moleAccent : .clear))
                    if entry.selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: 15, height: 15)
            }
            .buttonStyle(MolePlainButtonStyle())
            .disabled(!selectionEnabled)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            riskBadge

            Spacer(minLength: 8)

            Text(ByteFormat.format(entry.bytes))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)

            Button(action: onReveal) {
                Image(systemName: "folder")
            }
            .buttonStyle(MoleIconButtonStyle())
            .help(L10n.shared.t("system.row.reveal"))

            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(MoleIconButtonStyle(tint: .red))
            .help(L10n.shared.t("system.row.delete"))
            .disabled(!selectionEnabled)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.045)))
        .opacity(selectionEnabled ? 1 : 0.6)
    }

    @ViewBuilder
    private var riskBadge: some View {
        let isSafe = entry.risk == .safe
        Text(l10nBadge)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(isSafe ? Color.green : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill((isSafe ? Color.green : Color.orange).opacity(0.14)))
    }

    private var l10nBadge: String {
        L10n.shared.t(entry.risk == .safe ? "system.badge.safe" : "system.badge.review")
    }
}
