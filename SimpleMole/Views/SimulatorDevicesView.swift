import SwiftUI

struct SimulatorDevicesView: View {
    @ObservedObject var store: SimulatorInventoryStore
    let canMutate: Bool
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var showsDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 520, idealHeight: 580)
        .onAppear {
            if store.phase == .idle { store.scan() }
        }
        .onChange(of: store.devices.map(\.id)) { currentIDs in
            selection.formIntersection(Set(currentIDs))
        }
        .alert(l10n.t("sim.confirm.title"), isPresented: $showsDeleteConfirmation) {
            Button(l10n.t("sim.delete"), role: .destructive) {
                guard canMutate else { return }
                let submitted = selection
                selection.removeAll()
                store.deleteAfterUserConfirmation(submitted)
            }
            Button(l10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l10n.tf("sim.confirm.message", selectedDevices.count))
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "iphone.gen3")
                .font(.system(size: 22))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("sim.title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(l10n.t("sim.subtitle"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { store.scan() } label: {
                Label(l10n.t("common.rescan"), systemImage: "arrow.clockwise")
            }
            .buttonStyle(SecondaryButtonStyle())
            .labelStyle(.iconOnly)
            .help(l10n.t("common.rescan"))
            .disabled(store.phase == .loading || store.isDeleting)
            Button(l10n.t("common.close")) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
    }

    @ViewBuilder
    private var content: some View {
        if store.devices.isEmpty {
            switch store.phase {
            case .idle, .loading:
                inventoryMessage(symbol: "iphone.gen3", key: "sim.status.scanning", progress: true)
            case .unavailable:
                inventoryMessage(symbol: "xmark.circle", key: "sim.status.unavailable")
            case .failed(let message):
                VStack(spacing: 12) {
                    inventoryMessage(symbol: "exclamationmark.triangle", key: "sim.status.failed")
                    if !message.isEmpty { errorBanner(message) }
                }
                .padding(16)
            case .ready:
                inventoryMessage(symbol: "checkmark.circle", key: "sim.empty")
            }
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if case .failed(let message) = store.phase {
                        errorBanner(message)
                    }
                    ForEach(store.groupedDevices, id: \.runtime) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.runtime)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 4)
                            ForEach(group.devices) { device in
                                deviceRow(device)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if store.phase == .loading || store.isDeleting {
                ProgressView().controlSize(.small)
            }
            if let summary = store.lastDeleteSummary {
                Text(l10n.tf("sim.delete.summary", summary.removed, summary.skipped, summary.failed))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Text(l10n.t("sim.manualOnly"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                showsDeleteConfirmation = true
            } label: {
                Label(l10n.tf("sim.delete.count", selectedDevices.count), systemImage: "trash")
            }
            .buttonStyle(DangerButtonStyle())
            .disabled(!canMutate || selectedDevices.isEmpty
                      || store.phase == .loading || store.isDeleting)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var selectedDevices: [SimulatorDevice] {
        store.devices.filter { selection.contains($0.id) && $0.canDeleteManually }
    }

    private func deviceRow(_ device: SimulatorDevice) -> some View {
        HStack(spacing: 10) {
            Button {
                if selection.contains(device.id) { selection.remove(device.id) }
                else { selection.insert(device.id) }
            } label: {
                Image(systemName: selection.contains(device.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(device.canDeleteManually
                        ? AnyShapeStyle(Color.moleAccentText) : AnyShapeStyle(.tertiary))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .disabled(!canMutate || !device.canDeleteManually || store.isDeleting)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 5) {
                    Text(device.udid)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    if let date = device.lastActivityAt {
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(date, style: .relative)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let error = device.availabilityError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(localizedState(device.state))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(device.canDeleteManually
                    ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
            riskBadge(device.risk)
            Text(device.dataBytes.map(ByteFormat.format) ?? "--")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary.opacity(0.5)))
    }

    private func localizedState(_ state: String) -> String {
        switch state.lowercased() {
        case "booted": return l10n.t("sim.state.booted")
        case "shutdown": return l10n.t("sim.state.shutdown")
        default: return l10n.t("sim.state.unknown")
        }
    }

    private func riskBadge(_ risk: CleanupRisk) -> some View {
        let protected = risk == .protected
        return Text(l10n.t(protected ? "cleanup.risk.protected" : "cleanup.risk.warning"))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(protected ? Color.red : Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill((protected ? Color.red : Color.orange).opacity(0.12)))
    }

    private func inventoryMessage(symbol: String, key: String, progress: Bool = false) -> some View {
        VStack(spacing: 10) {
            if progress { ProgressView().controlSize(.large) }
            else { Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(.secondary) }
            Text(l10n.t(key))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .lineLimit(2)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }
}
