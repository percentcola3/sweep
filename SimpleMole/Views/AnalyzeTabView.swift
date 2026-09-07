import SwiftUI

/// 全盘空间分析：默认从整机概览开始，把可直接清理、用户目录、应用数据、
/// 应用和系统目录分层展示。只有通过客户端安全策略的条目可勾选清理。
struct AnalyzeTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var savedLocations: SavedScanLocationStore
    @ObservedObject private var l10n = L10n.shared

    init(state: AppState) {
        self.state = state
        self.savedLocations = state.savedScanLocations
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                if !state.analyzeIsOverview {
                    Button { state.analyzeGoUp() } label: {
                        Label(l10n.t("analyze.up"), systemImage: "chevron.left")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .labelStyle(.iconOnly)
                    .help(l10n.t("analyze.up"))
                    .disabled(state.isBusy)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(scopeTitle)
                        .font(.system(size: 13, weight: .semibold))
                    Text(state.analyzeIsOverview ? l10n.t("analyze.overview.hint") : state.analyzePath)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Menu {
                    Button { state.scanDiskOverview(force: true) } label: {
                        Label(l10n.t("analyze.scope.full"), systemImage: "macbook.and.iphone")
                    }
                    Button { state.chooseAnalyzeFolder() } label: {
                        Label(l10n.t("analyze.pick"), systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button { state.addSavedScanLocation() } label: {
                        Label(l10n.t("analyze.savedScope.add"), systemImage: "bookmark")
                    }
                    ForEach(savedLocations.locations) { location in
                        Button {
                            state.scanAnalyze(location.path)
                        } label: {
                            Label(location.displayName, systemImage: "bookmark.fill")
                        }
                        .disabled(location.availability != .available)
                    }
                    Divider()
                    Button { state.openProjectRadar() } label: {
                        Label(l10n.t("analyze.projectRadar"), systemImage: "scope")
                    }
                } label: {
                    Label(l10n.t("analyze.advanced"), systemImage: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.isBusy)
                Button { refreshCurrentScope() } label: {
                    Label(state.isAnalyzing ? l10n.t("common.scanning") : l10n.t("analyze.scan"),
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            .sheet(isPresented: $state.showProjectRadar) {
                ProjectRadarView(
                    store: state.projectRadar,
                    locations: savedLocations.locations,
                    hibernation: state.projectHibernation,
                    fullDiskAccessGranted: state.permissionCenter.fullDiskAccessGranted,
                    canMutate: !state.isBusy,
                    onAddLocation: state.addSavedScanLocation)
            }
            .onAppear {
                if state.permissionCenter.fullDiskAccessGranted {
                    _ = savedLocations.refreshAvailability(persist: false)
                }
                state.scanDiskOverview()
            }

            HStack(spacing: 6) {
                if state.isAnalyzing { ProgressView().controlSize(.mini) }
                Text(state.analyzeStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                if state.isScanningDups {
                    ProgressView().controlSize(.mini)
                    Text(l10n.t("common.scanning"))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                } else if !state.analyzeLargeFiles.isEmpty {
                    Button { state.scanDuplicates() } label: {
                        Label(l10n.t("analyze.dupScan"), systemImage: "square.on.square.dashed")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .labelStyle(.iconOnly)
                    .help(l10n.t("analyze.dupScan"))
                    .controlSize(.small)
                }
                Text(l10n.t("analyze.top10Hint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if state.isAnalyzing && state.analyzeEntries.isEmpty && state.analyzeAIItems.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(l10n.t("analyze.scanning"))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.analyzeEntries.isEmpty && state.analyzeAIItems.isEmpty {
                EmptyStateView(symbol: "chart.bar.doc.horizontal",
                               title: l10n.t("analyze.status.empty"),
                               subtitle: l10n.t("analyze.empty.subtitle"))
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if !state.analyzeAIItems.isEmpty {
                            aiInventorySection
                        }
                        ForEach(analysisGroups) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(alignment: .center, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(l10n.t(group.titleKey))
                                            .font(.system(size: 11, weight: .semibold))
                                        Text(l10n.t(group.subtitleKey))
                                            .font(.system(size: 9))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text(ByteFormat.format(group.totalBytes))
                                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                ForEach(group.entries) { entry in
                                    AnalyzeRowView(
                                        entry: entry,
                                        isSelected: state.analyzeSelection.contains(entry.path),
                                        canSelect: entry.canCleanDirectly
                                    ) {
                                        state.toggleAnalyzeSelection(entry)
                                    } onOpen: {
                                        if entry.canCleanDirectly {
                                            state.toggleAnalyzeSelection(entry)
                                        } else {
                                            state.openAnalyzeEntry(entry)
                                        }
                                    }
                                }
                            }
                        }
                        if !state.dupGroups.isEmpty {
                            duplicatesSection
                        }
                        if state.snapshotsScanned {
                            snapshotsSection
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            if !state.analyzeEntries.isEmpty || !state.analyzeAIItems.isEmpty {
                Divider()
                HStack {
                    Text(footerText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !state.dupSelection.isEmpty {
                        Button { state.deleteDuplicates() } label: {
                            Label(l10n.t("analyze.dupDelete"),
                                  systemImage: "trash.fill")
                        }
                        .buttonStyle(DangerButtonStyle())
                        .labelStyle(.iconOnly)
                        .help(l10n.t("analyze.dupDelete"))
                        .disabled(state.isBusy)
                    }
                    Button { state.applyAnalyzeCleanup() } label: {
                        Label(l10n.t("analyze.apply"), systemImage: "trash.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled((state.analyzeSelection.isEmpty && state.analyzeAISelection.isEmpty)
                              || state.isBusy)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
        }
    }

    private var scopeTitle: String {
        if state.analyzeIsOverview { return l10n.t("analyze.scope.full") }
        let name = URL(fileURLWithPath: state.analyzePath).lastPathComponent
        return name.isEmpty ? state.analyzePath : name
    }

    private var analysisGroups: [AnalyzeGroup] {
        let definitions: [(AnalyzePresentationKind, String, String)] = [
            (.developer, "analyze.group.developer", "analyze.group.developer.subtitle"),
            (.ai, "analyze.group.ai", "analyze.group.ai.subtitle"),
            (.user, "analyze.group.user", "analyze.group.user.subtitle"),
            (.appData, "analyze.group.appData", "analyze.group.appData.subtitle"),
            (.application, "analyze.group.apps", "analyze.group.apps.subtitle"),
            (.system, "analyze.group.system", "analyze.group.system.subtitle"),
        ]
        return definitions.compactMap { definition in
            let entries = state.analyzeEntries.filter {
                presentationKind(for: $0) == definition.0
            }.sorted { $0.size > $1.size }
            guard !entries.isEmpty else { return nil }
            return AnalyzeGroup(id: definition.0.rawValue, titleKey: definition.1,
                                subtitleKey: definition.2, entries: entries)
        }.sorted {
            if $0.totalBytes != $1.totalBytes { return $0.totalBytes > $1.totalBytes }
            return $0.id < $1.id
        }
    }

    private func presentationKind(for entry: AnalyzeEntry) -> AnalyzePresentationKind {
        let path = entry.path.lowercased()
        let developerFragments = [
            "/node_modules", "/.nvm/", "/.npm", "/.pnpm", "/pnpm/",
            "/.yarn", "/.gradle/", "/.cargo/", "/.rustup/", "/.m2/",
            "/.nuget/", "/go/pkg/", "/library/developer/", "/deriveddata/",
            "/coresimulator/", "/android/sdk/"
        ]
        if entry.hintKind == "hint.artifact"
            || developerFragments.contains(where: { path.contains($0) }) {
            return .developer
        }

        let aiFragments = [
            "/.ollama/", "/.cache/huggingface", "/.cache/lm-studio/",
            "/.cache/torch", "/.codex/", "/.claude/", "/.gemini/",
            "/library/application support/codex"
        ]
        if aiFragments.contains(where: { path.contains($0) }) { return .ai }

        switch entry.handling {
        case .directCleanup, .browse: return .user
        case .appData: return .appData
        case .application: return .application
        case .systemReadOnly: return .system
        }
    }

    private func refreshCurrentScope() {
        if state.analyzeIsOverview {
            state.scanDiskOverview(force: true)
        } else {
            state.scanAnalyze()
        }
    }

    private var aiInventorySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(l10n.t("analyze.aiInventory.title"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(l10n.t("analyze.aiInventory.subtitle"))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(ByteFormat.format(state.analyzeAIItems.reduce(0) { $0 &+ $1.bytes }))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ForEach(state.analyzeAIItems) { item in
                AnalyzeAIItemRow(
                    item: item,
                    isSelected: state.analyzeAISelection.contains(item.path)
                ) {
                    state.toggleAnalyzeAISelection(item)
                }
            }
        }
    }

    private var snapshotsSection: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 1) {
                Text(l10n.t("analyze.snapshots"))
                    .font(.system(size: 11, weight: .semibold))
                Text(l10n.tf("analyze.snapshotCount", state.localSnapshots.count))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(state.purgeableBytes > 0 ? ByteFormat.format(state.purgeableBytes) : "--")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
            if state.isThinning {
                ProgressView().controlSize(.mini)
            } else if !state.localSnapshots.isEmpty {
                Button { state.thinSnapshots() } label: {
                    Label(l10n.t("analyze.thin"), systemImage: "arrow.down.circle")
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
    }

    private var footerText: String {
        if !state.dupSelection.isEmpty {
            return l10n.tf("analyze.dup.selected", state.dupSelection.count)
        }
        if state.analyzeSelection.isEmpty {
            if state.analyzeAISelection.isEmpty { return l10n.t("analyze.hint") }
        }
        return l10n.tf("analyze.selected", state.analyzeCombinedSelectedCount,
                       ByteFormat.format(state.analyzeCombinedSelectedBytes))
    }

    /// 重复文件分组区：每组一张卡片，成员行可勾选删除。
    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("analyze.dup.hint"))
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 10)
            ForEach(state.dupGroups.indices, id: \.self) { groupIndex in
                let members = state.dupGroups[groupIndex]
                VStack(alignment: .leading, spacing: 4) {
                    Text(l10n.tf("analyze.dup.group", members.count,
                                 ByteFormat.format(members.first?.size ?? 0)))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(members) { member in
                        let isSelected = state.dupSelection.contains(member.path)
                        Button { state.toggleDupSelection(member) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: isSelected
                                      ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(isSelected
                                        ? AnyShapeStyle(Color.moleAccentText) : AnyShapeStyle(.tertiary))
                                    .frame(width: 18)
                                Text(member.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.format(member.size))
                                    .font(.system(size: 10).monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(MoleSelectableRowButtonStyle(
                            isSelected: isSelected,
                            cornerRadius: 6,
                            horizontalPadding: 10,
                            verticalPadding: 4))
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.055)))
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(.separator.opacity(0.4), lineWidth: 1))
            }
        }
    }
}

private struct AnalyzeAIItemRow: View {
    let item: AnalyzeAIItem
    let isSelected: Bool
    let onToggle: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.moleAccentText)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(l10n.t(kindKey))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.moleAccentText)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.moleAccent.opacity(0.2)))
                    }
                    Text(item.path)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(ByteFormat.format(item.bytes))
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected
                        ? AnyShapeStyle(Color.moleAccentText) : AnyShapeStyle(.tertiary))
                    .frame(width: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(MoleSelectableRowButtonStyle(isSelected: isSelected))
    }

    private var iconName: String {
        switch item.kind {
        case .skill: return "puzzlepiece.extension.fill"
        case .linkedSkill: return "link"
        case .mcpCache: return "server.rack"
        }
    }

    private var kindKey: String {
        switch item.kind {
        case .skill: return "analyze.aiInventory.skill"
        case .linkedSkill: return "analyze.aiInventory.linkedSkill"
        case .mcpCache: return "analyze.aiInventory.mcpCache"
        }
    }
}

private struct AnalyzeGroup: Identifiable {
    let id: String
    let titleKey: String
    let subtitleKey: String
    let entries: [AnalyzeEntry]
    var totalBytes: UInt64 { entries.reduce(0) { $0 &+ $1.size } }
}

private enum AnalyzePresentationKind: String {
    case developer, ai, user, appData, application, system
}

private struct AnalyzeRowView: View {
    let entry: AnalyzeEntry
    let isSelected: Bool
    let canSelect: Bool
    let onToggle: () -> Void
    let onOpen: () -> Void
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 8) {
                    Image(systemName: rowIcon)
                        .font(.system(size: 11))
                        .foregroundStyle(iconStyle)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(entry.name)
                                .font(.system(size: 12, weight: entry.isDir ? .medium : .regular))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if let hint = entry.hintKind {
                                Text(l10n.t(hint))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.orange.opacity(0.12)))
                            }
                            if let badgeKey {
                                Text(l10n.t(badgeKey))
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(badgeColor)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(badgeColor.opacity(0.12)))
                            }
                        }
                        if !entry.isDir, let lastAccess = entry.lastAccess, let date = isoDate(lastAccess) {
                            Text(date, style: .date)
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Text(ByteFormat.format(entry.size))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                    if canSelect {
                        Color.clear.frame(width: 24, height: 24)
                    } else {
                        Image(systemName: entry.handling == .systemReadOnly ? "lock.fill" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .frame(width: 18)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MoleSelectableRowButtonStyle(isSelected: isSelected))

            if canSelect {
                Button(action: onToggle) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                }
                .buttonStyle(MoleIconButtonStyle(
                    isActive: isSelected,
                    tint: isSelected ? Color.moleAccentText : Color.secondary,
                    size: 24))
                .padding(.trailing, 3)
            }
        }
    }

    private var rowIcon: String {
        switch entry.handling {
        case .directCleanup: return entry.isDir ? "sparkles" : "doc.fill"
        case .browse: return entry.isDir ? "folder.fill" : "doc.fill"
        case .appData: return "shippingbox.fill"
        case .application: return "app.fill"
        case .systemReadOnly: return "internaldrive.fill"
        }
    }

    private var iconStyle: AnyShapeStyle {
        switch entry.handling {
        case .directCleanup: return AnyShapeStyle(Color.moleAccentText)
        case .application: return AnyShapeStyle(Color.orange)
        case .systemReadOnly: return AnyShapeStyle(.tertiary)
        default: return AnyShapeStyle(.secondary)
        }
    }

    private var badgeKey: String? {
        switch entry.handling {
        case .directCleanup: return "analyze.cleanable"
        case .browse: return entry.isDir ? "analyze.route.browse" : nil
        case .appData: return "analyze.route.appData"
        case .application: return "analyze.route.app"
        case .systemReadOnly: return "analyze.route.system"
        }
    }

    private var badgeColor: Color {
        switch entry.handling {
        case .directCleanup: return Color.moleAccentText
        case .application: return .orange
        case .systemReadOnly: return .secondary
        default: return .secondary
        }
    }

    private func isoDate(_ string: String) -> Date? {
        ISO8601DateFormatter().date(from: string)
    }
}
