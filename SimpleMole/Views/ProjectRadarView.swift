import SwiftUI

struct ProjectRadarView: View {
    @ObservedObject var store: ProjectRadarStore
    let locations: [SavedScanLocation]
    @ObservedObject var hibernation: ProjectHibernationService
    let fullDiskAccessGranted: Bool
    let canMutate: Bool
    let onAddLocation: () -> Void
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var expandedProjects: Set<String> = []
    @State private var selectedWarnings: Set<String> = []
    @State private var pendingProject: RadarProject?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            statusArea
            content
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 540, idealHeight: 620)
        .onAppear {
            if fullDiskAccessGranted && store.snapshot.projects.isEmpty {
                store.scan(
                    locations: locations,
                    fullDiskAccessGranted: fullDiskAccessGranted)
            }
        }
        .onChange(of: store.snapshot.projects.flatMap { $0.warningArtifacts.map(\.path) }) { paths in
            selectedWarnings.formIntersection(Set(paths))
        }
        .alert(item: $pendingProject) { project in
            Alert(
                title: Text(l10n.t("projectRadar.confirm.title")),
                message: Text(confirmationMessage(for: project)),
                primaryButton: .destructive(Text(l10n.t("projectRadar.confirm.action"))) {
                    guard canMutate else { return }
                    let warnings = selectedWarningPaths(for: project)
                    Task {
                        _ = await hibernation.hibernate(
                            project: project,
                            mode: .manual,
                            fullDiskAccessGranted: fullDiskAccessGranted,
                            manuallyIncludedWarningPaths: warnings)
                        store.scan(
                            locations: locations,
                            fullDiskAccessGranted: fullDiskAccessGranted)
                    }
                },
                secondaryButton: .cancel(Text(l10n.t("common.cancel")))
            )
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "scope")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t("projectRadar.open"))
                    .font(.system(size: 16, weight: .semibold))
                Text(l10n.t("projectRadar.subtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                store.scan(
                    locations: locations,
                    fullDiskAccessGranted: fullDiskAccessGranted)
            } label: {
                Label(l10n.t("projectRadar.scan"), systemImage: "arrow.clockwise")
            }
            .disabled(!fullDiskAccessGranted || store.isScanning || hibernation.isWorking)
            if locations.isEmpty {
                Button {
                    dismiss()
                    DispatchQueue.main.async(execute: onAddLocation)
                } label: {
                    Label(l10n.t("savedLocation.add"), systemImage: "folder.badge.plus")
                }
                .disabled(!canMutate || store.isScanning || hibernation.isWorking)
            }
            Button(l10n.t("common.close")) { dismiss() }
        }
        .padding(16)
    }

    @ViewBuilder
    private var statusArea: some View {
        if store.isScanning || hibernation.isWorking {
            statusBanner(symbol: "hourglass", text: store.isScanning
                ? l10n.t("projectRadar.status.scanning")
                : l10n.t("projectRadar.status.hibernating"), color: .secondary,
                         showsProgress: true)
        } else if let error = hibernation.lastError ?? store.lastError, !error.isEmpty {
            statusBanner(symbol: "exclamationmark.triangle.fill", text: error,
                         color: .orange, showsProgress: false)
        } else if !store.snapshot.unavailableLocations.isEmpty {
            statusBanner(
                symbol: "externaldrive.badge.exclamationmark",
                text: l10n.tf("projectRadar.status.unavailable",
                              store.snapshot.unavailableLocations.joined(separator: ", ")),
                color: .orange,
                showsProgress: false)
        }
    }

    @ViewBuilder
    private var content: some View {
        if !store.isScanning && store.snapshot.projects.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "folder.badge.questionmark")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.secondary)
                Text(locations.isEmpty
                     ? l10n.t("projectRadar.empty.locations")
                     : l10n.t("projectRadar.empty.projects"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.snapshot.projects) { project in
                        projectCard(project)
                    }
                }
                .padding(16)
            }
        }
    }

    private func projectCard(_ project: RadarProject) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    withAnimation(reduceMotion ? nil : MoleMotion.panel) {
                        if expandedProjects.contains(project.id) {
                            expandedProjects.remove(project.id)
                        } else {
                            expandedProjects.insert(project.id)
                        }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expandedProjects.contains(project.id) ? 90 : 0))
                }
                .buttonStyle(MoleIconButtonStyle(
                    isActive: expandedProjects.contains(project.id)))

                Image(systemName: "shippingbox.and.arrow.backward.fill")
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.displayName)
                        .font(.system(size: 12, weight: .semibold))
                    Text(project.rootPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 10)
                riskBadge(l10n.t("cleanup.risk.safe"), count: project.safeArtifacts.count,
                          bytes: project.safeBytes, color: .green)
                riskBadge(l10n.t("cleanup.risk.warning"), count: project.warningArtifacts.count,
                          bytes: project.warningBytes, color: .orange)
                Button(l10n.t("projectRadar.hibernate")) { pendingProject = project }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!fullDiskAccessGranted || !canMutate
                              || !canHibernate(project) || hibernation.isWorking)
                    .help(ProjectHibernation.supportsRecoverableTrash(for: project.rootPath)
                          ? l10n.t("projectRadar.hibernate")
                          : l10n.t("projectRadar.sameVolumeOnly"))
            }

            if expandedProjects.contains(project.id) {
                Group {
                    Divider()
                    Text(l10n.tf("projectRadar.lastActivity",
                                 project.lastActivityAt.formatted(date: .abbreviated, time: .shortened)))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    ForEach(project.artifacts) { artifact in
                        artifactRow(artifact)
                    }
                }
                .transition(.molePanelReveal)
            }
        }
        .clipped()
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(.separator.opacity(0.45), lineWidth: 1))
    }

    private func artifactRow(_ artifact: ProjectArtifact) -> some View {
        HStack(spacing: 8) {
            if artifact.risk == .warning {
                Toggle("", isOn: Binding(
                    get: { selectedWarnings.contains(artifact.path) },
                    set: { selected in
                        if selected { selectedWarnings.insert(artifact.path) }
                        else { selectedWarnings.remove(artifact.path) }
                    }))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .help(l10n.t("projectRadar.warning.help"))
            } else {
                Image(systemName: artifact.risk == .safe
                      ? "checkmark.shield.fill" : "lock.shield.fill")
                    .foregroundStyle(artifact.risk == .safe ? .green : .red)
                    .frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: artifact.path).lastPathComponent)
                    .font(.system(size: 10, weight: .medium))
                Text(artifact.kind.rawValue)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text(riskTitle(artifact.risk))
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(artifact.risk == .safe ? .green
                    : artifact.risk == .warning ? .orange : .red)
            Text(ByteFormat.format(artifact.bytes))
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 68, alignment: .trailing)
        }
        .padding(.vertical, 3)
    }

    private func riskBadge(_ title: String, count: Int, bytes: UInt64, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(count) \(title)")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(color)
            Text(ByteFormat.format(bytes))
                .font(.system(size: 8).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func statusBanner(symbol: String, text: String, color: Color,
                              showsProgress: Bool) -> some View {
        HStack(spacing: 8) {
            if showsProgress { ProgressView().controlSize(.small) }
            else { Image(systemName: symbol).foregroundStyle(color) }
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(showsProgress ? .secondary : color)
                .lineLimit(2)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quinary)
    }

    private func selectedWarningPaths(for project: RadarProject) -> Set<String> {
        Set(project.warningArtifacts.map(\.path)).intersection(selectedWarnings)
    }

    private func canHibernate(_ project: RadarProject) -> Bool {
        ProjectHibernation.supportsRecoverableTrash(for: project.rootPath)
            && (!project.safeArtifacts.isEmpty || !selectedWarningPaths(for: project).isEmpty)
    }

    private func confirmationMessage(for project: RadarProject) -> String {
        let warnings = selectedWarningPaths(for: project)
        let selected = project.safeArtifacts + project.warningArtifacts.filter { warnings.contains($0.path) }
        let bytes = selected.reduce(UInt64(0)) { $0 &+ $1.bytes }
        if warnings.isEmpty {
            return l10n.tf("projectRadar.confirm.safeOnly",
                           selected.count, ByteFormat.format(bytes))
        }
        return l10n.tf("projectRadar.confirm.withWarnings",
                       selected.count, ByteFormat.format(bytes), warnings.count)
    }

    private func riskTitle(_ risk: AutomationRisk) -> String {
        switch risk {
        case .safe: return l10n.t("cleanup.risk.safe")
        case .warning: return l10n.t("cleanup.risk.warning")
        case .protected: return l10n.t("cleanup.risk.protected")
        }
    }
}
