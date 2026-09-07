import SwiftUI

struct AutomationProjectOption: Identifiable, Equatable {
    let id: String
    let name: String
}

struct AutomationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var locations: SavedScanLocationStore
    @ObservedObject var automations: AutomationStore
    @ObservedObject var receipts: ProjectHibernationReceiptStore
    @ObservedObject var projectRadar: ProjectRadarStore
    @ObservedObject var hibernation: ProjectHibernationService
    let authorizedLocationIDs: Set<UUID>
    let fullDiskAccessGranted: Bool
    let canMutate: Bool
    let onAddLocation: () -> Void
    let onRestore: (ProjectHibernationReceipt) -> Void
    @ObservedObject private var l10n = L10n.shared

    @State private var showsRuleEditor = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    safetyNotice
                    savedLocationsSection
                    triggersSection
                    receiptsSection
                }
                .padding(16)
            }
        }
        .frame(minWidth: 680, idealWidth: 740, minHeight: 560, idealHeight: 640)
        .onAppear {
            guard fullDiskAccessGranted else { return }
            locations.refreshAvailability()
            receipts.refreshAvailability()
            if canMutate {
                projectRadar.scan(
                    locations: locations.locations,
                    fullDiskAccessGranted: fullDiskAccessGranted)
            }
        }
        .sheet(isPresented: $showsRuleEditor) {
            SmartTriggerEditor(locations: locations.locations.filter {
                                   authorizedLocationIDs.contains($0.id)
                               },
                               projects: automatableProjects,
                               canMutate: canMutate) { rule in
                guard canMutate else { return }
                _ = automations.add(rule)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "gearshape.2.fill")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t("automation.header"))
                    .font(.system(size: 16, weight: .semibold))
                Text(l10n.t("automation.subtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(l10n.t("common.close")) { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(16)
    }

    private var safetyNotice: some View {
        Label {
            Text(l10n.t("automation.safety"))
                .font(.system(size: 10))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(.green)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.08)))
    }

    private var savedLocationsSection: some View {
        section(title: l10n.t("savedLocation.section"),
                actionTitle: l10n.t("savedLocation.add"),
                actionSymbol: "folder.badge.plus",
                actionDisabled: !canMutate,
                action: onAddLocation) {
            if let error = locations.lastError, !error.isEmpty {
                persistenceError(error)
            }
            if locations.locations.isEmpty {
                emptyRow(l10n.t("savedLocation.empty"))
            } else {
                ForEach(locations.locations) { location in
                    HStack(spacing: 9) {
                        Image(systemName: location.availability == .available
                              ? "folder.fill" : "folder.badge.questionmark")
                            .foregroundStyle(location.availability == .available
                                             ? Color.accentColor : Color.orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.displayName)
                                .font(.system(size: 11, weight: .medium))
                            Text(location.path)
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Text(availabilityTitle(location.availability))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(location.availability == .available
                                             ? Color.green : Color.orange)
                        Button(role: .destructive) {
                            guard canMutate else { return }
                            _ = locations.remove(id: location.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help(l10n.t("savedLocation.remove.help"))
                        .disabled(!canMutate)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var triggersSection: some View {
        section(title: l10n.t("automation.triggers"),
                actionTitle: l10n.t("automation.addTrigger"),
                actionSymbol: "plus.circle",
                actionDisabled: !canMutate,
                action: {
                    guard canMutate else { return }
                    showsRuleEditor = true
                }) {
            if let error = automations.lastError, !error.isEmpty {
                persistenceError(error)
            }
            if automations.triggers.isEmpty {
                emptyRow(l10n.t("automation.empty"))
            } else {
                ForEach(automations.triggers) { rule in
                    let targetAvailable = isTargetAvailable(for: rule)
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: {
                                guard canMutate else { return }
                                _ = automations.setEnabled($0, id: rule.id)
                            }))
                            .labelsHidden()
                            .toggleStyle(MoleSwitchToggleStyle())
                            .controlSize(.mini)
                            .disabled(!canMutate || !rule.isValid
                                      || (!rule.isEnabled && !targetAvailable))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.name.isEmpty ? actionTitle(rule.action) : rule.name)
                                .font(.system(size: 11, weight: .medium))
                            Text(triggerSummary(rule))
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundStyle(rule.isValid && targetAvailable
                                                 ? Color.secondary : Color.red)
                        }
                        Spacer()
                        if !rule.isValid || !targetAvailable {
                            Text(l10n.t(rule.isValid
                                        ? "automation.targetUnavailable"
                                        : "automation.invalidDisabled"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.red)
                        }
                        Button(role: .destructive) {
                            guard canMutate else { return }
                            _ = automations.remove(id: rule.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!canMutate)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private var receiptsSection: some View {
        section(title: l10n.t("automation.receipts")) {
            if hibernation.isWorking {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(l10n.t("projectRadar.status.hibernating"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
            } else if let error = hibernation.lastError, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
            }
            if let error = receipts.lastError, !error.isEmpty {
                persistenceError(error)
            }
            if receipts.receipts.isEmpty {
                emptyRow(l10n.t("automation.receipts.empty"))
            } else {
                ForEach(receipts.receipts.sorted { $0.createdAt > $1.createdAt }) { receipt in
                    HStack(spacing: 9) {
                        Image(systemName: receipt.recoverableArtifacts.isEmpty
                              ? "checkmark.circle" : "arrow.uturn.backward.circle.fill")
                            .foregroundStyle(receipt.recoverableArtifacts.isEmpty
                                             ? Color.secondary : Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(URL(fileURLWithPath: receipt.projectRoot).lastPathComponent)
                                .font(.system(size: 11, weight: .medium))
                            Text(l10n.tf("automation.receipt.summary",
                                         receiptStateTitle(receipt.state),
                                         receipt.recoverableArtifacts.count,
                                         ByteFormat.format(receipt.recoverableBytes)))
                                .font(.system(size: 8).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !receipt.recoverableArtifacts.isEmpty {
                            Button(l10n.t("automation.restore")) { onRestore(receipt) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .help(l10n.t("automation.restore.help"))
                                .disabled(!canMutate || hibernation.isWorking)
                        } else {
                            Button(role: .destructive) {
                                guard canMutate else { return }
                                _ = receipts.remove(id: receipt.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!canMutate)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func section<Content: View>(title: String,
                                        actionTitle: String? = nil,
                                        actionSymbol: String? = nil,
                                        actionDisabled: Bool = false,
                                        action: (() -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let actionTitle, let actionSymbol, let action {
                    Button(action: action) {
                        Label(actionTitle, systemImage: actionSymbol)
                    }
                    .controlSize(.small)
                    .disabled(actionDisabled)
                }
            }
            VStack(alignment: .leading, spacing: 5) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.separator.opacity(0.45), lineWidth: 1))
        }
    }

    private func emptyRow(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func persistenceError(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 9))
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func triggerSummary(_ rule: SmartTriggerRule) -> String {
        let target = scopeTitle(rule.scope)
        switch rule.condition.kind {
        case .dailySchedule:
            return l10n.tf("automation.summary.daily",
                           rule.condition.hour ?? 0, rule.condition.minute ?? 0,
                           actionTitle(rule.action), target)
        case .weeklySchedule:
            return l10n.tf("automation.summary.weekly",
                           rule.condition.weekday ?? 0, actionTitle(rule.action), target)
        case .projectInactive:
            return l10n.tf("automation.summary.inactive",
                           rule.condition.days ?? 0, target)
        case .savedLocationSizeLimit:
            return l10n.tf("automation.summary.size",
                           ByteFormat.format(rule.condition.bytes ?? 0), target)
        case .savedLocationRetention:
            return l10n.tf("automation.summary.retention",
                           rule.condition.days ?? 0, target)
        }
    }

    private func scopeTitle(_ scope: AutomationScope) -> String {
        switch scope.kind {
        case .allSafe:
            return l10n.t("automation.scope.allSafe")
        case .savedLocation:
            return locations.locations.first {
                $0.id.uuidString == scope.targetID
            }?.displayName ?? scope.targetID ?? "—"
        case .project:
            return projects.first { $0.id == scope.targetID }?.name
                ?? scope.targetID ?? "—"
        }
    }

    private var projects: [AutomationProjectOption] {
        projectRadar.snapshot.projects.map {
            AutomationProjectOption(id: $0.id, name: $0.displayName)
        }
    }

    private var automatableProjects: [AutomationProjectOption] {
        projectRadar.snapshot.projects.compactMap { project in
            guard ProjectHibernation.supportsRecoverableTrash(for: project.rootPath) else {
                return nil
            }
            return AutomationProjectOption(id: project.id, name: project.displayName)
        }
    }

    private func availabilityTitle(_ availability: SavedScanLocationAvailability) -> String {
        switch availability {
        case .available: return l10n.t("savedLocation.available")
        case .unavailable: return l10n.t("savedLocation.unavailable")
        }
    }

    private func receiptStateTitle(_ state: ProjectHibernationReceiptState) -> String {
        l10n.t("automation.receipt.state.\(state.rawValue)")
    }

    private func actionTitle(_ action: AutomationAction) -> String {
        l10n.t("automation.action.\(action.rawValue)")
    }

    private func isTargetAvailable(for rule: SmartTriggerRule) -> Bool {
        guard rule.scope.kind == .project else { return true }
        guard let targetID = rule.scope.targetID else { return false }
        return automatableProjects.contains { $0.id == targetID }
    }
}

private struct SmartTriggerEditor: View {
    private enum DraftKind: String, CaseIterable, Identifiable {
        case dailyQuickClean = "Daily Safe Quick Clean"
        case savedSizeLimit = "Saved Location Size Limit"
        case savedRetention = "Saved Location Retention"
        case projectInactive = "Inactive Project Hibernation"

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .dailyQuickClean: return "automation.editor.kind.dailyQuickClean"
            case .savedSizeLimit: return "automation.editor.kind.savedSizeLimit"
            case .savedRetention: return "automation.editor.kind.savedRetention"
            case .projectInactive: return "automation.editor.kind.projectInactive"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    let locations: [SavedScanLocation]
    let projects: [AutomationProjectOption]
    let canMutate: Bool
    let onSave: (SmartTriggerRule) -> Void
    @ObservedObject private var l10n = L10n.shared

    @State private var kind: DraftKind = .dailyQuickClean
    @State private var name = ""
    @State private var targetID = ""
    @State private var hour = 3
    @State private var minute = 0
    @State private var sizeGB = 10.0
    @State private var days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(l10n.t("automation.editor.title"))
                .font(.system(size: 16, weight: .semibold))
            Text(l10n.t("automation.editor.subtitle"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Form {
                Picker(l10n.t("automation.editor.type"), selection: $kind) {
                    ForEach(DraftKind.allCases) { value in
                        Text(l10n.t(value.titleKey)).tag(value)
                    }
                }
                TextField(l10n.t("automation.editor.name"), text: $name)
                if kind == .savedSizeLimit || kind == .savedRetention {
                    Picker(l10n.t("automation.editor.savedLocation"), selection: $targetID) {
                        ForEach(locations) { location in
                            Text(location.displayName).tag(location.id.uuidString)
                        }
                    }
                } else if kind == .projectInactive {
                    Picker(l10n.t("automation.editor.project"), selection: $targetID) {
                        ForEach(projects) { project in Text(project.name).tag(project.id) }
                    }
                }

                if kind == .dailyQuickClean {
                    Stepper(l10n.tf("automation.editor.hour", hour), value: $hour, in: 0...23)
                    Stepper(l10n.tf("automation.editor.minute", minute), value: $minute, in: 0...59, step: 5)
                } else if kind == .savedSizeLimit {
                    HStack {
                        TextField(l10n.t("automation.editor.gb"), value: $sizeGB,
                                  format: .number.precision(.fractionLength(1)))
                            .frame(width: 80)
                        Stepper(l10n.t("automation.editor.gb"), value: $sizeGB,
                                in: 0.1...1024, step: 0.1)
                            .labelsHidden()
                    }
                } else {
                    Stepper(l10n.tf("automation.editor.days", days), value: $days, in: 1...3650)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(l10n.t("common.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(l10n.t("automation.editor.saveDisabled")) {
                    if let rule = makeRule() {
                        onSave(rule)
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canMutate || !canSave)
            }
        }
        .padding(20)
        .frame(width: 480, height: 430)
        .onAppear { selectFirstTarget() }
        .onChange(of: kind) { _ in selectFirstTarget() }
    }

    private var canSave: Bool {
        switch kind {
        case .dailyQuickClean: return true
        case .savedSizeLimit, .savedRetention:
            return locations.contains { $0.id.uuidString == targetID }
        case .projectInactive:
            return projects.contains { $0.id == targetID }
        }
    }

    private func selectFirstTarget() {
        switch kind {
        case .savedSizeLimit, .savedRetention:
            if !locations.contains(where: { $0.id.uuidString == targetID }) {
                targetID = locations.first?.id.uuidString ?? ""
            }
        case .projectInactive:
            if !projects.contains(where: { $0.id == targetID }) {
                targetID = projects.first?.id ?? ""
            }
        case .dailyQuickClean:
            targetID = ""
        }
    }

    private func makeRule() -> SmartTriggerRule? {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .dailyQuickClean:
            return SmartTriggerRule(name: title.isEmpty ? l10n.t(kind.titleKey) : title,
                                    condition: .daily(hour: hour, minute: minute),
                                    action: .quickCleanSafe,
                                    scope: .allSafe)
        case .savedSizeLimit:
            guard let id = UUID(uuidString: targetID) else { return nil }
            let clamped = min(1024, max(0.1, sizeGB))
            let bytes = UInt64((clamped * 1_000_000_000).rounded())
            return SmartTriggerRule(name: title.isEmpty ? l10n.t(kind.titleKey) : title,
                                    condition: .savedLocationSizeLimit(bytes: bytes),
                                    action: .cleanSavedLocationSafe,
                                    scope: .savedLocation(id))
        case .savedRetention:
            guard let id = UUID(uuidString: targetID) else { return nil }
            return SmartTriggerRule(name: title.isEmpty ? l10n.t(kind.titleKey) : title,
                                    condition: .savedLocationRetention(days: days),
                                    action: .cleanSavedLocationSafe,
                                    scope: .savedLocation(id))
        case .projectInactive:
            guard !targetID.isEmpty else { return nil }
            return SmartTriggerRule(name: title.isEmpty ? l10n.t(kind.titleKey) : title,
                                    condition: .projectInactive(days: days),
                                    action: .hibernateProjectSafeArtifacts,
                                    scope: .project(targetID))
        }
    }
}
