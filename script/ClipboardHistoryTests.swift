import Foundation

@main
@MainActor
struct ClipboardHistoryTests {
    static func main() {
        let suite = "com.simplemole.clipboard-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("could not create isolated defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("simple-mole-clipboard-\(UUID().uuidString)",
                                    isDirectory: true)
        let historyURL = testDirectory.appendingPathComponent("history.plist")
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let manager = ClipboardHistoryManager(defaults: defaults, historyURL: historyURL)
        precondition(manager.capacity == 50, "default capacity must be 50")
        manager.updateCapacity(10)
        precondition(manager.capacity == 10, "capacity update failed")

        for index in 0..<12 {
            manager.record(.init(kind: .text, text: "item-\(index)",
                                 date: Date(timeIntervalSince1970: Double(index))))
        }
        precondition(manager.entries.count == 10, "oldest unpinned entries were not trimmed")
        precondition(manager.entries.last?.text == "item-2", "trim order is not oldest first")

        guard let pinnedID = manager.entries.last?.id else { fatalError("missing test entry") }
        manager.togglePinned(pinnedID)
        for index in 12..<15 {
            manager.record(.init(kind: .url, text: "https://example.com/\(index)",
                                 date: Date(timeIntervalSince1970: Double(index))))
        }
        precondition(manager.pinnedCount == 1, "pinned entry was lost")
        precondition(manager.unpinnedCount == 10, "capacity must apply only to unpinned entries")
        precondition(manager.entries.first?.id == pinnedID, "pinned entry is not kept first")

        let duplicate = ClipboardHistoryManager.Entry(kind: .text, text: "item-2")
        manager.record(duplicate)
        precondition(manager.entries.first?.id == pinnedID,
                     "re-copying pinned content must preserve pin identity")

        manager.clearUnpinned()
        precondition(manager.entries.count == 1 && manager.entries[0].isPinned,
                     "clear unpinned removed a pinned entry")

        let sourceURL = testDirectory.appendingPathComponent("large-source.bin")
        let sourceData = Data(repeating: 0x5a, count: 1024 * 1024)
        try! FileManager.default.createDirectory(at: testDirectory,
                                                 withIntermediateDirectories: true)
        try! sourceData.write(to: sourceURL)
        manager.record(.init(kind: .file, filePaths: [sourceURL.path]))

        let archiveAttributes = try! FileManager.default.attributesOfItem(
            atPath: historyURL.path)
        let archiveSize = (archiveAttributes[.size] as! NSNumber).intValue
        precondition(archiveSize < sourceData.count,
                     "file clipboard entry copied source contents into history storage")

        try! FileManager.default.removeItem(at: sourceURL)
        let restored = ClipboardHistoryManager(defaults: defaults, historyURL: historyURL)
        precondition(restored.entries.count == 2, "persisted entries were not restored")
        precondition(restored.pinnedCount == 1, "pinned state was not restored")
        precondition(restored.entries.contains {
            $0.kind == .file && $0.filePaths == [sourceURL.path] && $0.imageData == nil
        }, "file history must persist only its path index")
        print("Clipboard history tests passed")
    }
}
