import SwiftUI
import AppKit
import CoreImage

// MARK: - 数据模型

enum EditorTool: String, CaseIterable, Identifiable {
    case rect, ellipse, arrow, pen, text, mosaic
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .pen: return "pencil.tip"
        case .text: return "textformat"
        case .mosaic: return "squareshape.split.2x2"
        }
    }
}

enum BeautifyTemplate: String, CaseIterable, Identifiable {
    case none, sunset, violet, ocean, mint, graphite, rose
    var id: String { rawValue }
    var colors: [Color] {
        switch self {
        case .none: return [.clear, .clear]
        case .sunset: return [Color(red: 1.0, green: 0.55, blue: 0.35), Color(red: 1.0, green: 0.82, blue: 0.30)]
        case .violet: return [Color(red: 0.62, green: 0.40, blue: 0.95), Color(red: 0.90, green: 0.50, blue: 0.85)]
        case .ocean: return [Color(red: 0.15, green: 0.45, blue: 0.90), Color(red: 0.35, green: 0.80, blue: 0.95)]
        case .mint: return [Color(red: 0.10, green: 0.70, blue: 0.55), Color(red: 0.55, green: 0.92, blue: 0.70)]
        case .graphite: return [Color(red: 0.16, green: 0.17, blue: 0.20), Color(red: 0.36, green: 0.38, blue: 0.44)]
        case .rose: return [Color(red: 0.95, green: 0.45, blue: 0.60), Color(red: 1.0, green: 0.72, blue: 0.72)]
        }
    }
}

/// 标注笔画：坐标为归一化（0~1，相对原图），导出与显示尺寸解耦。
struct Stroke: Identifiable {
    enum Kind { case rect, ellipse, arrow, pen, mosaic, text }
    let id = UUID()
    let kind: Kind
    let colorIndex: Int
    var points: [CGPoint]
    var text: String = ""
}

private let editorColors: [Color] = [
    Color(red: 1.0, green: 0.84, blue: 0.18),
    .red, .blue, .black, .white
]

// MARK: - 编辑器视图

struct ScreenshotEditorView: View {
    let image: NSImage
    let onClose: () -> Void

    @State private var strokes: [Stroke] = []
    @State private var draft: Stroke?
    @State private var tool: EditorTool = .rect
    @State private var colorIndex = 0
    @State private var template: BeautifyTemplate = .none
    @State private var pendingTextAt: CGPoint?
    @State private var pendingTextInput = ""
    @State private var feedbackKey: String?
    @ObservedObject private var l10n = L10n.shared

    private var displaySize: CGSize {
        let maxW: CGFloat = 1100
        let maxH: CGFloat = 620
        let size = image.size
        let scale = min(1, maxW / size.width, maxH / size.height)
        return CGSize(width: floor(size.width * scale), height: floor(size.height * scale))
    }

    private var exportSize: CGSize {
        image.representations
            .map { CGSize(width: $0.pixelsWide, height: $0.pixelsHigh) }
            .filter { $0.width > 0 && $0.height > 0 }
            .max { $0.width * $0.height < $1.width * $1.height }
            ?? image.size
    }

    var body: some View {
        VStack(spacing: 8) {
            toolBar
            canvasArea
            templateBar
            actionBar
        }
        .padding(12)
        .frame(minWidth: displaySize.width + 24, idealWidth: displaySize.width + 24,
               minHeight: displaySize.height + 170)
        .preferredColorScheme(.dark)
    }

    // MARK: 工具条

    private var toolBar: some View {
        HStack(spacing: 6) {
            ForEach(EditorTool.allCases) { t in
                Button {
                    tool = t
                } label: {
                    Image(systemName: t.icon)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 24)
                        .background(RoundedRectangle(cornerRadius: 6)
                            .fill(tool == t ? AnyShapeStyle(Color.moleAccent.opacity(0.35))
                                            : AnyShapeStyle(Color.white.opacity(0.06))))
                }
                .buttonStyle(.plain)
                .help(l10n.t("tool.\(t.rawValue)"))
            }
            Divider().frame(height: 18)
            ForEach(editorColors.indices, id: \.self) { index in
                Circle()
                    .fill(editorColors[index])
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(
                        colorIndex == index ? Color.white : Color.white.opacity(0.25),
                        lineWidth: colorIndex == index ? 2 : 1))
                    .onTapGesture { colorIndex = index }
                    .padding(2)
            }
            Divider().frame(height: 18)
            Button {
                strokes.removeLast()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
            }
            .buttonStyle(.plain)
            .disabled(strokes.isEmpty)
            .help(l10n.t("shot.undo"))
            Spacer()
        }
    }

    // MARK: 画布（含模板）

    /// 截图 + 标注层（归一化坐标渲染到当前显示尺寸）。
    private var editorCanvas: some View {
        ZStack {
            Image(nsImage: image)
                .resizable()
                .frame(width: displaySize.width, height: displaySize.height)
            AnnotationCanvas(strokes: strokes + (draft.map { [$0] } ?? []),
                             baseImage: image,
                             size: displaySize)
                .frame(width: displaySize.width, height: displaySize.height)
                .contentShape(Rectangle())
                .gesture(dragGesture)
        }
        .overlay(pendingTextOverlay)
    }

    private var canvasArea: some View {
        Group {
            if template == .none {
                editorCanvas
            } else {
                BeautifyFrame(template: template, contentSize: displaySize) {
                    editorCanvas
                }
            }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard tool != .text else { return }
                let p = normalized(value.location)
                if draft == nil {
                    guard tool != .mosaic || strokes.count + 1 <= 400 else { return }
                    draft = Stroke(kind: kindFor(tool), colorIndex: colorIndex, points: [p])
                } else {
                    draft?.points.append(p)
                }
            }
            .onEnded { value in
                guard tool != .text else {
                    pendingTextAt = normalized(value.location)
                    pendingTextInput = ""
                    return
                }
                if var stroke = draft {
                    stroke.points.append(normalized(value.location))
                    // 单击（矩形/椭圆）给最小尺寸，避免零面积不可见
                    if stroke.points.count == 2, stroke.kind == .rect || stroke.kind == .ellipse {
                        stroke.points[1] = CGPoint(x: min(1, stroke.points[0].x + 0.05),
                                                   y: min(1, stroke.points[0].y + 0.05))
                    }
                    strokes.append(stroke)
                }
                draft = nil
            }
    }

    private func kindFor(_ tool: EditorTool) -> Stroke.Kind {
        switch tool {
        case .rect: return .rect
        case .ellipse: return .ellipse
        case .arrow: return .arrow
        case .pen: return .pen
        case .mosaic: return .mosaic
        case .text: return .text
        }
    }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(1, max(0, point.x / displaySize.width)),
                y: min(1, max(0, point.y / displaySize.height)))
    }

    /// 文字工具：点击位置弹出输入框。
    @ViewBuilder
    private var pendingTextOverlay: some View {
        if let at = pendingTextAt {
            HStack(spacing: 6) {
                TextField(l10n.t("tool.text"), text: $pendingTextInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .font(.system(size: 13))
                Button(l10n.t("common.done")) {
                    if !pendingTextInput.isEmpty {
                        strokes.append(Stroke(kind: .text, colorIndex: colorIndex,
                                              points: [at], text: pendingTextInput))
                    }
                    pendingTextAt = nil
                    pendingTextInput = ""
                }
                .buttonStyle(PrimaryButtonStyle())
                .controlSize(.small)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.ultraThinMaterial))
            .offset(x: at.x * displaySize.width,
                    y: at.y * displaySize.height + 12)
        }
    }

    // MARK: 模板选择条

    private var templateBar: some View {
        HStack(spacing: 8) {
            Text(l10n.t("shot.template"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            ForEach(BeautifyTemplate.allCases) { t in
                Button {
                    template = t
                } label: {
                    Group {
                        if t == .none {
                            Text(l10n.t("common.cancel"))
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .frame(width: 34, height: 22)
                        } else {
                            LinearGradient(colors: t.colors,
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                                .frame(width: 34, height: 22)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                        template == t ? Color.moleAccentText : Color.white.opacity(0.2),
                        lineWidth: template == t ? 2 : 1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: 操作条

    private var actionBar: some View {
        HStack(spacing: 8) {
            Button {
                showFeedback(copyToPasteboard() ? "shot.copied" : "shot.failed")
            } label: {
                Label(l10n.t("common.copy"), systemImage: "doc.on.doc")
            }
            .buttonStyle(SecondaryButtonStyle())
            Button {
                showFeedback(saveToDownloads() ? "shot.saved" : "shot.failed")
            } label: {
                Label(l10n.t("shot.save"), systemImage: "square.and.arrow.down")
            }
            .buttonStyle(SecondaryButtonStyle())
            if let feedbackKey {
                Text(l10n.t(feedbackKey))
                    .font(.system(size: 10))
                    .foregroundStyle(feedbackKey == "shot.failed" ? Color.orange : Color.moleAccentText)
            }
            Spacer()
            Button(l10n.t("common.done"), action: onClose)
                .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: 导出

    /// 导出视图 = 与画布一致的渲染（模板化或原图）+ 标注层。
    private var exportView: some View {
        Group {
            if template == .none {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: exportSize.width, height: exportSize.height)
                    AnnotationCanvas(strokes: strokes, baseImage: image, size: displaySize)
                        .frame(width: exportSize.width, height: exportSize.height)
                }
                .frame(width: exportSize.width, height: exportSize.height)
            } else {
                BeautifyFrame(template: template, contentSize: exportSize) {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: exportSize.width, height: exportSize.height)
                        AnnotationCanvas(strokes: strokes, baseImage: image, size: displaySize)
                            .frame(width: exportSize.width, height: exportSize.height)
                    }
                    .frame(width: exportSize.width, height: exportSize.height)
                }
            }
        }
    }

    private func renderExportImage() -> NSImage? {
        let renderer = ImageRenderer(content: exportView)
        // exportView 已按原始像素尺寸布局，scale=1 避免预览尺寸导致降采样。
        renderer.scale = 1
        return renderer.nsImage
    }

    private func copyToPasteboard() -> Bool {
        guard let rendered = renderExportImage(),
              let tiff = rendered.tiffRepresentation else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setData(tiff, forType: .tiff)
    }

    private func saveToDownloads() -> Bool {
        guard let rendered = renderExportImage(),
              let tiff = rendered.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshot-\(formatter.string(from: Date())).png")
        do {
            try png.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private func showFeedback(_ key: String) {
        feedbackKey = key
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            if feedbackKey == key { feedbackKey = nil }
        }
    }
}

// MARK: - 标注画布（Canvas 绘制）

struct AnnotationCanvas: View {
    let strokes: [Stroke]
    let baseImage: NSImage
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let pixelated = MosaicCache.shared.pixelatedImage(for: baseImage)
            let drawingScale = max(0.5, canvasSize.width / max(1, size.width))
            for stroke in strokes {
                let points = stroke.points.map {
                    CGPoint(x: $0.x * canvasSize.width, y: $0.y * canvasSize.height)
                }
                guard !points.isEmpty else { continue }
                let color = editorColors[stroke.colorIndex % editorColors.count]
                Self.draw(stroke, points: points, color: color,
                          in: &context, canvasSize: canvasSize,
                          drawingScale: drawingScale, pixelated: pixelated)
            }
        }
    }

    private static func draw(_ stroke: Stroke, points: [CGPoint], color: Color,
                             in context: inout GraphicsContext,
                             canvasSize: CGSize, drawingScale: CGFloat,
                             pixelated: CGImage?) {
        switch stroke.kind {
        case .pen:
            var path = Path()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 3 * drawingScale,
                                              lineCap: .round, lineJoin: .round))
        case .rect:
            context.stroke(Path(CGRect(points: points)), with: .color(color),
                           lineWidth: 3 * drawingScale)
        case .ellipse:
            context.stroke(Path(ellipseIn: CGRect(points: points)),
                           with: .color(color), lineWidth: 3 * drawingScale)
        case .arrow:
            guard let start = points.first, let end = points.last else { return }
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: 3 * drawingScale, lineCap: .round))
            let angle = atan2(end.y - start.y, end.x - start.x)
            let head: CGFloat = 12 * drawingScale
            let p1 = CGPoint(x: end.x - head * cos(angle - 0.45),
                             y: end.y - head * sin(angle - 0.45))
            let p2 = CGPoint(x: end.x - head * cos(angle + 0.45),
                             y: end.y - head * sin(angle + 0.45))
            var headPath = Path()
            headPath.move(to: end)
            headPath.addLine(to: p1)
            headPath.addLine(to: p2)
            headPath.closeSubpath()
            context.fill(headPath, with: .color(color))
        case .mosaic:
            guard let pixelated, points.count >= 2 else { return }
            var path = Path()
            path.move(to: points[0])
            for p in points.dropFirst() { path.addLine(to: p) }
            let outline = path.strokedPath(
                StrokeStyle(lineWidth: 22 * drawingScale,
                            lineCap: .round, lineJoin: .round))
            let nsPixelated = NSImage(cgImage: pixelated,
                                      size: NSSize(width: canvasSize.width, height: canvasSize.height))
            let drawContext = context
            drawContext.drawLayer { layer in
                layer.clip(to: outline)
                layer.draw(Image(nsImage: nsPixelated), in: CGRect(origin: .zero, size: canvasSize))
            }
        case .text:
            guard let location = points.first else { return }
            context.draw(Text(stroke.text)
                .font(.system(size: 15 * drawingScale, weight: .semibold))
                .foregroundColor(color), at: location)
        }
    }
}

extension CGRect {
    init(points: [CGPoint]) {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for p in points {
            minX = Swift.min(minX, p.x)
            minY = Swift.min(minY, p.y)
            maxX = Swift.max(maxX, p.x)
            maxY = Swift.max(maxY, p.y)
        }
        self.init(x: minX, y: minY,
                  width: Swift.max(0, maxX - minX),
                  height: Swift.max(0, maxY - minY))
    }
}

/// 像素化底图缓存（马赛克工具用；按原图指针缓存一份）。
final class MosaicCache {
    static let shared = MosaicCache()
    private var cachedKey: NSObject?
    private var cachedImage: CGImage?

    func pixelatedImage(for image: NSImage) -> CGImage? {
        if cachedKey === image, let cachedImage { return cachedImage }
        guard let tiff = image.tiffRepresentation,
              let source = NSImage(data: tiff)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let ciImage = CIImage(cgImage: source)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(ciImage, forKey: kCIInputImageKey)
        filter?.setValue(14, forKey: kCIInputScaleKey)
        guard let output = filter?.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        cachedKey = image
        cachedImage = cg
        return cg
    }

    func clear() {
        cachedKey = nil
        cachedImage = nil
    }
}



/// 美化相框：渐变背景 + 圆角窗口卡（红黄绿三点）+ 内容。预览与导出共用。
struct BeautifyFrame<Content: View>: View {
    let template: BeautifyTemplate
    let contentSize: CGSize
    @ViewBuilder let content: () -> Content

    var body: some View {
        let padding = contentSize.width * 0.05
        let frameWidth = contentSize.width + padding * 2
        let frameHeight = contentSize.height + padding * 2 + 30
        let colors = template.colors
        ZStack {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red.opacity(0.9)).frame(width: 10, height: 10)
                    Circle().fill(Color.yellow.opacity(0.9)).frame(width: 10, height: 10)
                    Circle().fill(Color.green.opacity(0.9)).frame(width: 10, height: 10)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                content()
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.85)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .padding(padding)
        }
        .frame(width: frameWidth, height: frameHeight)
    }
}
