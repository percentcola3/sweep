import AppKit

MainActor.assumeIsolated {
    BrandMigration.run()
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
