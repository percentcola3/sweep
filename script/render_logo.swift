// Renders the transparent-background panda-head logo used in the title bar.
// Usage: swift render_logo.swift /path/to/LogoTransparent.png
import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write("usage: render_logo.swift OUTPUT.png\n".data(using: .utf8)!)
    exit(2)
}
let outputURL = URL(fileURLWithPath: arguments[1])

let canvas = 512.0
let image = NSImage(size: NSSize(width: canvas, height: canvas))
image.lockFocus()

// 耳朵（黑）
NSColor.black.setFill()
NSBezierPath(ovalIn: CGRect(x: 45, y: 285, width: 190, height: 190)).fill()
NSBezierPath(ovalIn: CGRect(x: 277, y: 285, width: 190, height: 190)).fill()

// 脸（白）
NSColor.white.setFill()
NSBezierPath(ovalIn: CGRect(x: 61, y: 5, width: 390, height: 390)).fill()

// 眼斑（黑斜椭圆）+ 高光
for (cx, angle) in [(185.0, 0.35), (327.0, -0.35)] {
    let patch = NSBezierPath()
    patch.appendOval(in: CGRect(x: cx - 52, y: 165, width: 104, height: 150))
    var transform = AffineTransform.identity
    transform.translate(x: cx, y: 240)
    transform.rotate(byRadians: CGFloat(angle))
    transform.translate(x: -cx, y: -240)
    patch.transform(using: transform)
    NSColor.black.setFill()
    patch.fill()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: CGRect(x: cx - 14, y: 225, width: 30, height: 34)).fill()
}

// 鼻子（黑）
NSColor.black.setFill()
NSBezierPath(ovalIn: CGRect(x: 226, y: 96, width: 60, height: 42)).fill()

// 安全帽（黄，含帽檐）
let helmet = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.18, alpha: 1.0)
helmet.setFill()
let dome = NSBezierPath()
dome.move(to: NSPoint(x: 71, y: 330))
dome.appendArc(withCenter: NSPoint(x: 256, y: 330), radius: 185,
               startAngle: 0, endAngle: 180, clockwise: false)
dome.close()
dome.fill()
NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.30, alpha: 1.0).setFill()
NSBezierPath(roundedRect: NSRect(x: 56, y: 306, width: 400, height: 40),
             xRadius: 20, yRadius: 20).fill()
// 帽脊
NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.45, alpha: 1.0).setFill()
NSBezierPath(roundedRect: NSRect(x: 216, y: 400, width: 80, height: 46),
             xRadius: 24, yRadius: 24).fill()

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    FileHandle.standardError.write("error: failed to encode PNG\n".data(using: .utf8)!)
    exit(1)
}
try png.write(to: outputURL)
print("wrote \(outputURL.path)")
