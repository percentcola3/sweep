import AppKit
import SwiftUI

struct PermissionCenterView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var permissions: PermissionCenter
    @ObservedObject private var l10n = L10n.shared

    init(state: AppState) {
        self.state = state
        _permissions = ObservedObject(wrappedValue: state.permissionCenter)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 10) {
                    if let errorKey = permissions.diskAuthorizationErrorKey {
                        Label(l10n.t(errorKey), systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 9)
                                .fill(Color.orange.opacity(0.08)))
                    }

                    diskAccessRow
                    screenRecordingRow

                    Label(l10n.t("permissions.noAccessibility"),
                          systemImage: "checkmark.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 470)
        .background(DarkGlassSurface())
        .animation(.easeInOut(duration: 0.22),
                   value: permissions.fullDiskAccessGranted)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 24))
                .foregroundStyle(Color.moleAccentText)
            VStack(alignment: .leading, spacing: 3) {
                Text(l10n.t("permissions.title"))
                    .font(.system(size: 17, weight: .semibold))
                Text(l10n.t("permissions.subtitle"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { state.cancelPermissionCenter() } label: {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .background(Circle().fill(.quinary))
            .help(l10n.t("common.close"))
        }
        .padding(16)
    }

    private var diskAccessRow: some View {
        PermissionRow(
            icon: "externaldrive.badge.checkmark",
            title: l10n.t("permissions.fullDisk.title"),
            detail: l10n.t("permissions.fullDisk.detail"),
            status: permissions.fullDiskAccessGranted
                ? l10n.t("permissions.status.granted")
                : l10n.t("permissions.status.required"),
            statusColor: permissions.fullDiskAccessGranted ? .green : .orange,
            primaryTitle: permissions.fullDiskAccessGranted
                ? l10n.t("permissions.openSettings")
                : l10n.t("permissions.openFullDiskSettings"),
            primaryIcon: "gearshape",
            primaryProminent: !permissions.fullDiskAccessGranted,
            primaryAction: { permissions.openSystemSettings(.fullDisk) },
            secondaryTitle: permissions.fullDiskAccessGranted
                ? nil : l10n.t("permissions.recheck"),
            secondaryAction: { state.recheckFullDiskAccess() },
            dragProvider: permissions.fullDiskAccessGranted ? nil : applicationDragProvider,
            dragHint: permissions.fullDiskAccessGranted
                ? nil : l10n.t("permissions.drag.hint.disk"))
    }

    private func applicationDragProvider() -> NSItemProvider {
        let provider = NSItemProvider(object: Bundle.main.bundleURL as NSURL)
        provider.suggestedName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return provider
    }

    private var screenRecordingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            PermissionRow(
                icon: "rectangle.inset.filled.and.person.filled",
                title: l10n.t("permissions.screen.title"),
                detail: l10n.t("permissions.screen.detail"),
                status: permissions.screenRecordingGranted
                    ? l10n.t("permissions.status.granted")
                    : l10n.t("permissions.status.optional"),
                statusColor: permissions.screenRecordingGranted ? .green : .secondary,
                primaryTitle: permissions.screenRecordingGranted
                    ? l10n.t("permissions.openSettings") : l10n.t("permissions.screen.action"),
                primaryIcon: permissions.screenRecordingGranted ? "gearshape" : "record.circle",
                primaryProminent: false,
                primaryAction: {
                    if permissions.screenRecordingGranted {
                        permissions.openSystemSettings(.screenRecording)
                    } else {
                        state.requestScreenRecordingAccess()
                    }
                },
                secondaryTitle: permissions.screenRecordingGranted
                    ? nil : l10n.t("permissions.openSettings"),
                secondaryAction: { permissions.openSystemSettings(.screenRecording) },
                dragProvider: permissions.screenRecordingGranted
                    ? nil : applicationDragProvider,
                dragHint: permissions.screenRecordingGranted
                    ? nil : l10n.t("permissions.drag.hint.screen"))

            // 屏幕录制授权只在新进程生效；授权后必须退出重开，否则快捷键
            // 一直被 preflight 拦下，看起来像"授权了也没用"。
            if !permissions.screenRecordingGranted {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.orange)
                        .padding(.top, 1)
                    Text(l10n.t("permissions.screen.restartHint"))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        state.relaunchApplication()
                    } label: {
                        Label(l10n.t("permissions.screen.restart"),
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
                .padding(.horizontal, 12)
            }
        }
    }

    private var footer: some View {
        let hasPendingAction = state.hasPendingPermissionAction
        let isWaitingForDiskAccess = hasPendingAction
            && !permissions.fullDiskAccessGranted

        return HStack(spacing: 10) {
            Text(l10n.t(hasPendingAction
                        ? "permissions.footer.pendingScan"
                        : "permissions.footer"))
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(l10n.t("common.cancel")) { state.cancelPermissionCenter() }
                .buttonStyle(SecondaryButtonStyle())
            Button(l10n.t(hasPendingAction
                          ? "permissions.continue"
                          : "common.done")) {
                state.completePermissionSetup()
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(isWaitingForDiskAccess)
            .opacity(isWaitingForDiskAccess ? 0.50 : 1)
            .help(isWaitingForDiskAccess
                  ? l10n.t("permissions.continue.requiresDiskAccess")
                  : "")
        }
        .padding(16)
        .animation(.easeInOut(duration: 0.18), value: isWaitingForDiskAccess)
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: String
    let statusColor: Color
    let primaryTitle: String
    let primaryIcon: String
    let primaryProminent: Bool
    let primaryAction: () -> Void
    var secondaryTitle: String?
    var secondaryAction: (() -> Void)?
    var dragProvider: (() -> NSItemProvider)? = nil
    /// 拖拽目标提示：授权哪个权限，卡片就指向哪个系统设置列表。
    var dragHint: String? = nil

    var body: some View {
        content
            .modifier(ConditionalDragModifier(provider: dragProvider,
                                               help: dragProvider == nil ? nil : dragHint))
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Color.moleAccentText)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Color.moleAccent.opacity(0.10)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: 12, weight: .semibold))
                        Text(status)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(statusColor)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(statusColor.opacity(0.10)))
                    }
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    if primaryProminent {
                        Button(action: primaryAction) {
                            Label(primaryTitle, systemImage: primaryIcon)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                    } else {
                        Button(action: primaryAction) {
                            Label(primaryTitle, systemImage: primaryIcon)
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if let secondaryTitle, let secondaryAction {
                        Button(secondaryTitle, action: secondaryAction)
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.moleAccentText)
                    }
                }
            }
            if dragProvider != nil, let dragHint {
                // 拖拽能力必须一眼可见：橙色虚线提示条本身就是拖拽目标的一部分。
                HStack(spacing: 8) {
                    Image(systemName: "hand.draw.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Text(dragHint)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "plus.square.dashed")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.orange.opacity(0.7))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.06)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.orange.opacity(0.45),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

private struct ConditionalDragModifier: ViewModifier {
    let provider: (() -> NSItemProvider)?
    let help: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let provider {
            content
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .onDrag(provider)
                .help(help ?? "")
        } else {
            content
        }
    }
}
