import SwiftUI

/// 按应用排查代理消耗，保留独立的 Clash 和进程采样口径。
struct TrafficTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var store: TrafficMonitorStore
    @ObservedObject private var l10n = L10n.shared
    @State private var showConnections = false
    @State private var showClashSettings = false
    @State private var showAuxiliary = false
    @State private var detailApp: TrafficAppSelection?

    init(state: AppState) {
        self.state = state
        self.store = state.trafficMonitor
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                if store.sampling {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Toggle(l10n.t("netmon.persistent"), isOn: $store.persistentMonitoring)
                    .toggleStyle(MoleSwitchToggleStyle())
                    .controlSize(.small)
                    .font(.system(size: 11))
                Button(l10n.t("netmon.reset")) { store.resetSession() }
                    .controlSize(.small)
                    .disabled(store.rows.isEmpty && store.clashSessionDown == 0 && store.clashSessionUp == 0)
                Button {
                    showClashSettings = true
                } label: {
                    Label(l10n.t("netmon.settings"), systemImage: "gearshape")
                        .labelStyle(.titleAndIcon)
                }
                .controlSize(.small)
                .popover(isPresented: $showClashSettings, arrowEdge: .bottom) {
                    TrafficClashSettingsPanel(store: store)
                        .frame(width: 320)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 8)

            HStack(spacing: 6) {
                TrafficSummaryCard(title: l10n.t("netmon.card.proxyNode"),
                                   down: store.nodeDown, up: store.nodeUp, tint: .blue)
                TrafficSummaryCard(title: l10n.t("netmon.card.proxyDirect"),
                                   down: store.directDown, up: store.directUp, tint: .orange)
                TrafficSummaryCard(title: l10n.t("netmon.card.unattributed"),
                                   down: store.unattributedDown, up: store.unattributedUp,
                                   tint: .secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)

            HStack(spacing: 8) {
                Text(l10n.tf("netmon.session.started", store.sessionStartedAt.formatted(date: .abbreviated, time: .shortened))
                     + (store.historySaveFailed ? "" : " · " + l10n.t("netmon.history.saved")))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button {
                    showAuxiliary.toggle()
                } label: {
                    Label(l10n.t("netmon.auxiliary"),
                          systemImage: showAuxiliary ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.plain)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if store.historySaveFailed {
                Text(l10n.t("netmon.history.saveFailed"))
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            }

            if showAuxiliary {
                HStack(spacing: 6) {
                    TrafficSummaryCard(title: l10n.t("netmon.card.clashSession"),
                                       down: store.clashSessionDown, up: store.clashSessionUp,
                                       tint: .secondary)
                    TrafficSummaryCard(title: l10n.t("netmon.card.clashCore"),
                                       down: store.clashCoreDown, up: store.clashCoreUp,
                                       tint: .secondary)
                    TrafficSummaryCard(title: l10n.t("netmon.card.tunnel"),
                                       down: store.tunnelDown, up: store.tunnelUp, tint: .secondary)
                    TrafficSummaryCard(title: l10n.t("netmon.card.physical"),
                                       down: store.physicalDown, up: store.physicalUp, tint: .secondary)
                }
                .padding(.horizontal, 16)
                Text(l10n.t("netmon.auxiliary.hint"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }

            if store.clashState != .ok {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(clashStateText)
                        Text(clashStateHint ?? l10n.t("netmon.clash.unavailableHint"))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(clashTint)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Picker("", selection: $showConnections) {
                Text(l10n.t("netmon.tab.apps")).tag(false)
                Text(l10n.t("netmon.tab.connections")).tag(true)
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)

            if !showConnections {
                HStack(spacing: 8) {
                    Picker(l10n.t("netmon.sort.title"), selection: $store.sortOrder) {
                        ForEach(TrafficSortOrder.allCases, id: \.rawValue) { order in
                            Text(l10n.t(order.titleKey)).tag(order)
                        }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                    Text(l10n.t("netmon.sort.descending"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 6)
            } else {
                Text(l10n.t("netmon.clash.connectionsHint"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
            }

            if showConnections {
                clashConnectionList
            } else if store.rows.isEmpty {
                EmptyStateView(symbol: "antenna.radiowaves.left.and.right",
                               title: l10n.t("netmon.empty.title"),
                               subtitle: l10n.t("netmon.empty.subtitle"))
            } else {
                appList
            }

            Text(l10n.t("netmon.footnote"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
        .sheet(item: $detailApp) { selection in
            TrafficAppDetailSheet(store: store, appKey: selection.id)
                .frame(minWidth: 680, minHeight: 460)
        }
        .onAppear { store.setPageVisible(true) }
        .onDisappear { store.setPageVisible(false) }
    }

    private var statusText: String {
        if !store.bytesSourceAvailable { return l10n.t("netmon.status.bytesUnavailable") }
        if let lastSample = store.lastSample {
            let formatter = DateFormatter()
            formatter.timeStyle = .short
            return l10n.tf("netmon.status.lastSample", formatter.string(from: lastSample))
        }
        return l10n.t("netmon.status.sampling")
    }

    private var clashTint: Color {
        switch store.clashState {
        case .ok: return .blue
        case .notConfigured: return .secondary
        case .unauthorized, .unreachable, .stale: return .orange
        }
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(Array(store.rows.enumerated()), id: \.element.id) { index, row in
                    Button {
                        detailApp = TrafficAppSelection(id: row.appKey)
                    } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 18)
                                ProcessAppIcon(
                                    row: ProcessRow(pid: row.representativePID,
                                                    startIdentity: "",
                                                    name: row.displayName,
                                                    detail: "",
                                                    isNativeApp: row.bundleIdentifier != nil,
                                                    cpu: 0, mem: 0, memBytes: 0),
                                    size: 26,
                                    fallbackSystemName: "terminal.fill",
                                    fallbackTint: .secondary,
                                    validatesNativeStartIdentity: false)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.displayName)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Text("\(l10n.t("netmon.col.sampleRate")) \(rateText(row.rateDown, row.rateUp))")
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                TrafficMetric(label: l10n.t(store.sortOrder.titleKey),
                                              value: ByteFormat.short(store.sortOrder.bytes(in: row)),
                                              isElevated: false)
                                TrafficMetric(label: l10n.t("netmon.col.conns"),
                                              value: "\(row.connectionCount)",
                                              isElevated: false)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            HStack(spacing: 8) {
                                TrafficByteMetric(title: l10n.t("netmon.sort.proxyNode"),
                                                  down: row.proxyNodeDown, up: row.proxyNodeUp,
                                                  tint: .blue)
                                TrafficByteMetric(title: l10n.t("netmon.card.proxyDirect"),
                                                  down: row.proxyDirectDown, up: row.proxyDirectUp,
                                                  tint: .orange)
                                TrafficByteMetric(title: l10n.t("netmon.sort.appTotal"),
                                                  down: row.sessionDown, up: row.sessionUp,
                                                  tint: .secondary)
                            }
                            if row.proxyUnknownDown > 0 || row.proxyUnknownUp > 0 {
                                Text(l10n.t("netmon.detail.proxyUnknown")
                                     + "  ↓\(ByteFormat.short(row.proxyUnknownDown)) ↑\(ByteFormat.short(row.proxyUnknownUp))")
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.4), lineWidth: 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private var clashConnectionList: some View {
        Group {
            if store.clashConnections.isEmpty {
                VStack(spacing: 6) {
                    EmptyStateView(symbol: "arrow.triangle.branch",
                                   title: l10n.t("netmon.clash.noConnections"),
                                   subtitle: clashStateText)
                    if let hint = clashStateHint {
                        Text(hint)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(store.clashConnections.sorted {
                            $0.download + $0.upload > $1.download + $1.upload
                        }, id: \.id) { connection in
                            HStack(spacing: 8) {
                                TrafficExitBadge(kind: clashExitKind(connection))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(clashRemoteText(connection))
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Text("\(connection.metadata.process ?? l10n.t("netmon.clash.unknownApp"))"
                                         + " · \(l10n.t("netmon.clash.chains")): \((connection.chains ?? []).joined(separator: " → "))"
                                         + (connection.rule.map { " · \($0)" } ?? ""))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                TrafficMetric(label: l10n.t("netmon.col.down"),
                                              value: ByteFormat.short(connection.download),
                                              isElevated: false)
                                TrafficMetric(label: l10n.t("netmon.col.up"),
                                              value: ByteFormat.short(connection.upload),
                                              isElevated: false)
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

    private var clashStateText: String {
        switch store.clashState {
        case .ok: return l10n.t("netmon.clash.state.ok")
        case .unauthorized: return l10n.t("netmon.clash.state.unauthorized")
        case .unreachable: return l10n.t("netmon.clash.state.unreachable")
        case .stale: return l10n.t("netmon.clash.state.stale")
        case .notConfigured: return l10n.t("netmon.clash.state.notConfigured")
        }
    }

    private var clashStateHint: String? {
        store.clashState == .stale ? l10n.t("netmon.clash.state.staleHint") : nil
    }

    private func clashRemoteText(_ connection: ClashAPI.Connection) -> String {
        let metadata = connection.metadata
        if let host = metadata.host, !host.isEmpty {
            return metadata.destinationPort.map { "\(host):\($0)" } ?? host
        }
        if let address = metadata.destinationIP, !address.isEmpty {
            return metadata.destinationPort.map { "\(address):\($0)" } ?? address
        }
        return l10n.t("netmon.clash.unknownApp")
    }

    private func clashExitKind(_ connection: ClashAPI.Connection) -> TrafficExitKind {
        guard let chains = connection.chains, !chains.isEmpty else { return .unknown }
        return connection.isDirectExit ? .proxyDirect : .proxyNode
    }

    private func rateText(_ down: Double, _ up: Double) -> String {
        "↓\(ByteFormat.short(UInt64(max(down, 0))))/s ↑\(ByteFormat.short(UInt64(max(up, 0))))/s"
    }
}

// MARK: - 子组件

private struct TrafficAppSelection: Identifiable {
    let id: String
}

private struct TrafficByteMetric: View {
    let title: String
    let down: UInt64
    let up: UInt64
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(ByteFormat.short(down + up))
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(tint)
            Text("↓\(ByteFormat.short(down)) ↑\(ByteFormat.short(up))")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TrafficSummaryCard: View {
    let title: String
    let down: UInt64
    let up: UInt64
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.tail)
            Text("↓\(ByteFormat.short(down)) ↑\(ByteFormat.short(up))")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.4), lineWidth: 1))
    }
}

private struct TrafficMetric: View {
    let label: String
    let value: String
    let isElevated: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(isElevated ? Color.orange : Color.secondary)
                .lineLimit(1)
        }
        .frame(minWidth: 52, alignment: .trailing)
    }
}

private struct TrafficExitBadge: View {
    let kind: TrafficExitKind
    @ObservedObject private var l10n = L10n.shared

    private var tint: Color {
        switch kind {
        case .direct: return .secondary
        case .tunnel: return .indigo
        case .proxyDirect: return .orange
        case .proxyNode: return .blue
        case .proxy: return .teal
        case .loopback: return .gray
        case .unknown: return .secondary
        }
    }

    var body: some View {
        Text(l10n.t(kind.titleKey))
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .frame(height: 16)
            .background(Capsule().fill(tint.opacity(0.12)))
            .overlay(Capsule().strokeBorder(tint.opacity(0.32), lineWidth: 1))
            .fixedSize()
    }
}

/// 应用会话累计与端点历史，按稳定 appKey 读取最新数据。
private struct TrafficAppDetailSheet: View {
    @ObservedObject var store: TrafficMonitorStore
    let appKey: String
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.dismiss) private var dismiss

    private var row: TrafficAppRow? { store.rows.first { $0.appKey == appKey } }
    private var endpoints: [TrafficEndpointRow] { store.endpointsByApp[appKey] ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(row?.displayName ?? l10n.t("netmon.detail.title"))
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)

            if let row {
                HStack(spacing: 6) {
                    TrafficSummaryCard(title: l10n.t("netmon.detail.proxyNode"),
                                       down: row.proxyNodeDown, up: row.proxyNodeUp, tint: .blue)
                    TrafficSummaryCard(title: l10n.t("netmon.detail.proxyDirect"),
                                       down: row.proxyDirectDown, up: row.proxyDirectUp, tint: .orange)
                    TrafficSummaryCard(title: l10n.t("netmon.detail.proxyUnknown"),
                                       down: row.proxyUnknownDown, up: row.proxyUnknownUp,
                                       tint: .secondary)
                    TrafficSummaryCard(title: l10n.t("netmon.detail.session"),
                                       down: row.sessionDown, up: row.sessionUp, tint: .secondary)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            Text(l10n.t("netmon.detail.scope"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            HStack {
                Text(l10n.t("netmon.detail.endpoints"))
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(l10n.t("netmon.sort.descending"))
                    .font(.system(size: 9))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            if endpoints.isEmpty {
                Text(l10n.t("netmon.detail.noEndpoints"))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(endpoints) { endpoint in
                            TrafficEndpointHistoryRow(endpoint: endpoint)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 2)
                }
            }
        }
    }
}

private struct TrafficEndpointHistoryRow: View {
    let endpoint: TrafficEndpointRow
    @ObservedObject private var l10n = L10n.shared

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            TrafficExitBadge(kind: endpoint.kind)
            VStack(alignment: .leading, spacing: 3) {
                Text(endpoint.remote)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !endpoint.clashChains.isEmpty {
                    Text("\(l10n.t("netmon.clash.chains")): \(endpoint.clashChains.joined(separator: " → "))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if !endpoint.clashRule.isEmpty {
                    Text("\(l10n.t("netmon.clash.rule")): \(endpoint.clashRule)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack(spacing: 6) {
                    Text(endpoint.activeConnections > 0
                         ? l10n.tf("netmon.detail.active", endpoint.activeConnections)
                         : l10n.t("netmon.detail.inactive"))
                    if let lastSeen = endpoint.lastSeen {
                        Text(l10n.tf("netmon.detail.lastSeen", lastSeen.formatted(date: .abbreviated, time: .shortened)))
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if endpoint.clashDown > 0 || endpoint.clashUp > 0 {
                TrafficMetric(label: l10n.t("netmon.col.down"),
                              value: ByteFormat.short(endpoint.clashDown), isElevated: false)
                TrafficMetric(label: l10n.t("netmon.col.up"),
                              value: ByteFormat.short(endpoint.clashUp), isElevated: false)
            } else {
                Text(l10n.t("netmon.detail.noBytes"))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator.opacity(0.4), lineWidth: 1))
    }
}

/// Clash 控制器配置：地址 / 密钥 / 自动发现 / 连通性测试。
private struct TrafficClashSettingsPanel: View {
    @ObservedObject var store: TrafficMonitorStore
    @ObservedObject private var l10n = L10n.shared
    @State private var endpointDraft: String
    @State private var secretDraft: String

    init(store: TrafficMonitorStore) {
        self.store = store
        _endpointDraft = State(initialValue: store.clashEndpoint)
        _secretDraft = State(initialValue: store.clashSecret)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(l10n.t("netmon.settings"))
                .font(.system(size: 12, weight: .semibold))

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t("netmon.clash.endpoint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                TextField(l10n.t("netmon.clash.endpointHint"), text: $endpointDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .font(.system(size: 11, design: .monospaced))
                    .autocorrectionDisabled()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(l10n.t("netmon.clash.secret"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                SecureField("", text: $secretDraft)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button(l10n.t("netmon.clash.discover")) {
                    Task {
                        await store.discoverClash()
                        endpointDraft = store.clashEndpoint
                        secretDraft = store.clashSecret
                    }
                }
                Button(l10n.t("netmon.clash.test")) {
                    store.applyClashConfiguration(endpoint: endpointDraft, secret: secretDraft)
                    Task { await store.testConnection() }
                }
                Spacer()
                Circle()
                    .fill(stateTint)
                    .frame(width: 7, height: 7)
                Text(stateText)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)

            if store.clashState == .stale {
                Text(l10n.t("netmon.clash.state.staleHint"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
    }

    private var stateTint: Color {
        switch store.clashState {
        case .ok: return .green
        case .notConfigured: return .secondary
        case .unauthorized, .unreachable, .stale: return .orange
        }
    }

    private var stateText: String {
        switch store.clashState {
        case .ok: return l10n.t("netmon.clash.state.ok")
        case .unauthorized: return l10n.t("netmon.clash.state.unauthorized")
        case .unreachable: return l10n.t("netmon.clash.state.unreachable")
        case .stale: return l10n.t("netmon.clash.state.stale")
        case .notConfigured: return l10n.t("netmon.clash.state.notConfigured")
        }
    }
}
