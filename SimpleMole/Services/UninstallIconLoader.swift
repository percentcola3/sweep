import AppKit

/// NSWorkspace icon lookup is synchronous. Keep it off the UI actor, bounded
/// to one worker, and reuse images across tab visits. Callers never mutate the
/// cached image; SwiftUI supplies the display size.
enum UninstallIconLoader {
    private static let queue = DispatchQueue(label: "com.forgesweep.uninstall-icons", qos: .utility)
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    static func image(path: String, identity: String) async -> NSImage {
        await withCheckedContinuation { continuation in
            queue.async {
                let key = "\(path)#\(identity)" as NSString
                if let image = cache.object(forKey: key) {
                    continuation.resume(returning: image)
                    return
                }
                let image = NSWorkspace.shared.icon(forFile: path)
                cache.setObject(image, forKey: key)
                continuation.resume(returning: image)
            }
        }
    }
}
