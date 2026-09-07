import SwiftUI
import AppKit

struct ClipboardHistoryTabView: View {
    @ObservedObject var manager: ClipboardHistoryManager
    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: Filter = .all

    private enum Filter: String, CaseIterable, Identifiable {
        case all, pinned, text, url, file, image
        var id: String { rawValue }
        var titleKey: String { "clip.filter.\(rawValue)" }

        var icon: String {
            switch self {
            case .all: "square.grid.2x2"
            case .pinned: "pin.fill"
            case .text: "text.alignleft"
            case .url: "link"
            case .file: "doc"
            case .image: "photo"
            }
        }
    }

    private var filteredEntries: [ClipboardHistoryManager.Entry] {
        switch filter {
        case .all: manager.entries
        case .pinned: manager.entries.filter(\.isPinned)
        case .text: manager.entries.filter { $0.kind == .text }
        case .url: manager.entries.filter { $0.kind == .url }
        case .file: manager.entries.filter { $0.kind == .file }
        case .image: manager.entries.filter { $0.kind == .image }
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Filter.allCases) { item in
                            Button {
                                if reduceMotion {
                                    filter = item
                                } else {
                                    withAnimation(MoleMotion.selection) { filter = item }
                                }
                            } label: {
                                Label(l10n.t(item.titleKey), systemImage: item.icon)
                            }
                            .buttonStyle(ClipboardFilterButtonStyle(isSelected: filter == item))
                        }
                    }
                }
                .layoutPriority(1)

                Spacer()

                Button {
                    manager.clearUnpinned()
                } label: {
                    Label(l10n.t("clip.clearUnpinned"), systemImage: "trash.fill")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(PrimaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(2)
                .disabled(manager.unpinnedCount == 0)
            }

            if filteredEntries.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: filter == .all ? "clipboard" : "line.3.horizontal.decrease.circle")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text(l10n.t(filter == .all ? "clip.empty" : "clip.filter.empty"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)],
                              alignment: .leading, spacing: 10) {
                        ForEach(filteredEntries) { entry in
                            ClipboardHistoryCard(
                                entry: entry,
                                onCopy: { manager.copyToPasteboard(entry) },
                                onTogglePin: { manager.togglePinned(entry.id) },
                                onDelete: { manager.remove(entry.id) }
                            )
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

private struct ClipboardFilterButtonStyle: ButtonStyle {
    let isSelected: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSelected ? Color.moleAccentText : Color.secondary)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                Capsule().fill(isSelected
                    ? Color.moleAccent.opacity(configuration.isPressed ? 0.24 : 0.17)
                    : Color.white.opacity(configuration.isPressed ? 0.09 : 0.055))
            )
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.98)
            .animation(reduceMotion ? nil : MoleMotion.press,
                       value: configuration.isPressed)
    }
}

private struct ClipboardIconButtonStyle: ButtonStyle {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(configuration.isPressed ? 0.10 : 0.055)))
            .scaleEffect(reduceMotion || !configuration.isPressed ? 1 : 0.92)
            .animation(reduceMotion ? nil : MoleMotion.press,
                       value: configuration.isPressed)
    }
}

private struct ClipboardHistoryCard: View {
    let entry: ClipboardHistoryManager.Entry
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @ObservedObject private var l10n = L10n.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Label(l10n.t(kindTitleKey), systemImage: kindIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(kindTint)
                Spacer()
                Text(entry.date, style: .relative)
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.tertiary)
                Button(action: onTogglePin) {
                    Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                }
                .buttonStyle(ClipboardIconButtonStyle(
                    tint: entry.isPinned ? Color.moleAccentText : Color.secondary
                ))
                .help(l10n.t(entry.isPinned ? "clip.unpin" : "clip.pin"))
            }

            content
                .frame(maxWidth: .infinity, minHeight: 84, maxHeight: 84,
                       alignment: .topLeading)
                .clipped()

            HStack(spacing: 8) {
                Button {
                    onCopy()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Label(l10n.t(copied ? "shot.copied" : "clip.copy"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(SecondaryButtonStyle(tint: copied ? Color.moleAccentText : nil))

                Spacer()

                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(ClipboardIconButtonStyle(tint: .secondary))
                .help(l10n.t("clip.delete"))
            }
        }
        .padding(12)
        .frame(height: 182, alignment: .topLeading)
        .clipped()
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(entry.isPinned ? Color.moleAccent.opacity(0.075) : Color.white.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
        .animation(reduceMotion ? nil : MoleMotion.selection, value: entry.isPinned)
        .animation(reduceMotion ? nil : MoleMotion.press, value: copied)
    }

    @ViewBuilder
    private var content: some View {
        switch entry.kind {
        case .image:
            if let data = entry.imageData, let image = NSImage(data: data) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 92)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.16)))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text(l10n.t("clip.imageUnavailable"))
                    .foregroundStyle(.tertiary)
            }
        case .file:
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.filePaths.map { URL(fileURLWithPath: $0).lastPathComponent }
                    .joined(separator: ", "))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Text(entry.filePaths.joined(separator: "\n"))
                    .font(.system(size: 9).monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(3)
            }
        case .url:
            Text(entry.text ?? "")
                .font(.system(size: 11).monospaced())
                .foregroundStyle(Color.moleAccentText)
                .lineLimit(4)
        case .text:
            Text(entry.text ?? "")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(5)
        }
    }

    private var kindTitleKey: String { "clip.kind.\(entry.kind.rawValue)" }

    private var kindIcon: String {
        switch entry.kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .file: "doc"
        case .image: "photo"
        }
    }

    private var kindTint: Color {
        switch entry.kind {
        case .text: .secondary
        case .url: .cyan
        case .file: .blue
        case .image: .purple
        }
    }
}
