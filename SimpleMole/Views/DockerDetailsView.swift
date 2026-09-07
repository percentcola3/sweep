import SwiftUI

struct DockerDetailsView: View {
    @ObservedObject var store: DockerInventoryStore
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKind: DockerResourceKind? = .images

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NavigationSplitView {
                List(DockerResourceKind.allCases, selection: $selectedKind) { kind in
                    HStack(spacing: 8) {
                        Image(systemName: kind.symbolName)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(l10n.t(kind.titleKey))
                            .lineLimit(1)
                        Spacer()
                        Text("\(store.items(for: kind).count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .tag(kind)
                }
                .listStyle(.sidebar)
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            } detail: {
                detailPane
            }
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 520, idealHeight: 580)
        .onAppear {
            if store.phase == .idle { store.scan() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "shippingbox.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("docker.details.title"))
                    .font(.system(size: 15, weight: .semibold))
                Text(l10n.t("docker.details.subtitle"))
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
            .disabled(store.phase == .loading)
            Button(l10n.t("common.close")) { dismiss() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(16)
    }

    @ViewBuilder
    private var detailPane: some View {
        let kind = selectedKind ?? .images
        let rows = store.items(for: kind)
        VStack(spacing: 0) {
            HStack {
                Label(l10n.t(kind.titleKey), systemImage: kind.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if store.phase == .loading { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if case .partial(let message) = store.phase {
                diagnosticBanner(message)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if rows.isEmpty {
                emptyDetail(for: kind)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(rows) { row in
                            resourceRow(row)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder
    private func emptyDetail(for kind: DockerResourceKind) -> some View {
        if let message = store.diagnosticsByKind[kind] {
            VStack(spacing: 10) {
                inventoryMessage(symbol: "exclamationmark.triangle", key: "docker.details.failed")
                Text(message)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
                    .padding(.horizontal, 20)
            }
        } else {
            switch store.phase {
            case .idle, .loading:
                inventoryMessage(symbol: "shippingbox", key: "docker.details.scanning", progress: true)
            case .unavailable:
                inventoryMessage(symbol: "xmark.circle", key: "docker.details.unavailable")
            case .failed(let message):
                VStack(spacing: 10) {
                    inventoryMessage(symbol: "exclamationmark.triangle", key: "docker.details.failed")
                    Text(message)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(3)
                        .padding(.horizontal, 20)
                }
            case .ready, .partial:
                inventoryMessage(symbol: "checkmark.circle", key: "docker.details.empty")
            }
        }
    }

    private func resourceRow(_ item: DockerResourceItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if let active = item.isActive {
                Text(l10n.t(active ? "docker.item.active" : "docker.item.inactive"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(active ? Color.green : Color.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill((active ? Color.green : Color.secondary).opacity(0.10)))
            }
            if let reclaimable = item.reclaimableLabel, !reclaimable.isEmpty {
                Text(reclaimable)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.orange)
            }
            Text(item.sizeLabel ?? "--")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quinary.opacity(0.5)))
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

    private func diagnosticBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 9))
                .lineLimit(2)
            Spacer()
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }
}
