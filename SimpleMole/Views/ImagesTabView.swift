import SwiftUI
import AppKit
import QuickLookThumbnailing

/// 图片瘦身：图片清单缩略图网格 + 入口跳转到压缩/重复清理。
struct ImagesTabView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var l10n = L10n.shared

    private let columns = [
        GridItem(.flexible(minimum: 220), spacing: 12, alignment: .top),
        GridItem(.flexible(minimum: 220), spacing: 12, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                Spacer()
                Button { state.requestScanAccess(.imageScan) } label: {
                    Label(state.isScanningImages ? l10n.t("common.scanning") : l10n.t("img.scan"), systemImage: "photo")
                }
                .buttonStyle(SecondaryButtonStyle())
                .disabled(state.isBusy)
                Button { state.openSlimCleanup() } label: {
                    Label(l10n.t("img.slim"), systemImage: "photo.badge.arrow.down")
                }
                .buttonStyle(PrimaryButtonStyle())
                .labelStyle(.iconOnly)
                .help(l10n.t("img.slim"))
                .disabled(state.isBusy)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if state.isScanningImages || !state.images.isEmpty {
                HStack(spacing: 6) {
                    if state.isScanningImages {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(state.imageStatus)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }

            if state.images.isEmpty {
                EmptyStateView(symbol: "photo.on.rectangle.angled",
                               title: state.isScanningImages ? l10n.t("img.status.scanning") : l10n.t("img.status.none"),
                               subtitle: state.isScanningImages ? nil : l10n.t("img.empty.subtitle"))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(state.images) { item in
                            ImageCardView(item: item) { state.revealImage(item) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }
        }
    }
}

private struct ImageCardView: View {
    let item: ImageItem
    let onReveal: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: NSImage?
    @State private var isLoading = true
    @State private var isHovering = false

    private var cacheKey: String { "\(item.path)#\(item.bytes)" }
    private var fileName: String { (item.path as NSString).lastPathComponent }
    private var dimensions: String? {
        guard item.width > 0, item.height > 0 else { return nil }
        return "\(item.width) × \(item.height)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onReveal) {
                ZStack {
                    Color.black.opacity(0.18)

                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "photo")
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 168)
                .clipped()
                .overlay(alignment: .topTrailing) {
                    Text(ByteFormat.format(item.bytes))
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.black.opacity(0.62), in: Capsule())
                        .padding(8)
                }
            }
            .buttonStyle(.plain)
            .help(L10n.shared.t("common.reveal"))

            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileName)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                    if let dimensions {
                        Text(dimensions)
                            .font(.system(size: 9).monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer(minLength: 0)
                Button(action: onReveal) {
                    Image(systemName: "folder")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.white.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help(L10n.shared.t("common.reveal"))
                .accessibilityLabel(L10n.shared.t("common.reveal"))
            }
            .padding(10)
        }
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(Color.white.opacity(isHovering ? 0.10 : 0.06))
        )
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(isHovering ? 0.16 : 0.10), radius: isHovering ? 8 : 5, y: 2)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.16)) {
                isHovering = hovering
            }
        }
        .task(id: cacheKey, priority: .utility) {
            guard thumbnail == nil else { return }
            isLoading = true
            let image = await ImageThumbnailStore.thumbnail(
                for: item,
                displayScale: displayScale
            )
            guard !Task.isCancelled else { return }
            thumbnail = image
            isLoading = false
        }
    }
}

private enum ImageThumbnailStore {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 48
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()

    static func thumbnail(for item: ImageItem, displayScale: CGFloat) async -> NSImage? {
        let key = "\(item.path)#\(item.bytes)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: item.path),
            size: CGSize(width: 360, height: 200),
            scale: displayScale,
            representationTypes: .thumbnail
        )
        let image: NSImage? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                    continuation.resume(returning: representation?.nsImage)
                }
            }
        } onCancel: {
            QLThumbnailGenerator.shared.cancel(request)
        }

        guard !Task.isCancelled, let image else { return nil }
        cache.setObject(image, forKey: key, cost: cacheCost(for: image, scale: displayScale))
        return image
    }

    private static func cacheCost(for image: NSImage, scale: CGFloat) -> Int {
        let width = max(1, Int(image.size.width * scale))
        let height = max(1, Int(image.size.height * scale))
        return width * height * 4
    }
}
