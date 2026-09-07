import Foundation

/// One-time migration from the pre-release Simple Mole identity to ForgeSweep.
/// Internal engine names remain unchanged; only user preferences and app-owned
/// storage move to the new product namespace.
enum BrandMigration {
    private static let migrationKey = "SMForgeSweepBrandMigrationV1"
    private static let legacyBundleIdentifier = "com.simplemole.app"

    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migrationKey) else { return }

        if let legacy = defaults.persistentDomain(forName: legacyBundleIdentifier) {
            for (key, value) in legacy where key.hasPrefix("SM") {
                if defaults.object(forKey: key) == nil {
                    defaults.set(value, forKey: key)
                }
            }
        }

        migrateDirectory(in: "Library/Application Support")
        migrateDirectory(in: "Library/Caches")
        defaults.set(true, forKey: migrationKey)
    }

    private static func migrateDirectory(in relativeParent: String) {
        let parent = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(relativeParent, isDirectory: true)
        let legacy = parent.appendingPathComponent("SimpleMole", isDirectory: true)
        let current = parent.appendingPathComponent("ForgeSweep", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path) else { return }
        try? fileManager.moveItem(at: legacy, to: current)
    }
}
