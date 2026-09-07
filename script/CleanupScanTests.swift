import Darwin
import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
        exit(1)
    }
}

@main
struct CleanupScanTests {
    static func main() async throws {
        let fm = FileManager.default
        // The production policy excludes /private and /var, including the
        // macOS temporary directory. Use the script's isolated workspace home.
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixture) }
        let home = fixture.appendingPathComponent("home")
        func write(_ path: String, bytes: Int = 4096) throws {
            let url = home.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 97, count: bytes).write(to: url)
        }
        try write("Library/Caches/com.example.ordinary/cache")
        try write("Library/Caches/com.example.second/cache")
        try write("Library/Caches/Homebrew/downloads/package")
        try write("Library/Caches/Codex/Default/Cache/entry")
        try write("Library/Caches/Codex/Default/Cookies")
        try write("Library/Application Support/Cursor/Cache/entry")
        try write("Library/Application Support/Cursor/User/settings.json")
        try write(".cache/huggingface/models/weights")
        try write(".codex/sessions/history.jsonl")
        try write(".npm/_cacache/package")
        try write(".Trash/old.log")
        try write("Library/Application Support/Example/Cache/entry")
        try write("Library/Containers/com.example.other/Data/Library/Caches/entry")
        try write("Library/Caches/whitelisted/entry")
        try write(".config/mole/whitelist", bytes: 0)
        try Data((home.path + "/Library/Caches/whitelisted\n").utf8)
            .write(to: home.appendingPathComponent(".config/mole/whitelist"))
        let outside = fixture.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data(repeating: 98, count: 8192).write(to: outside.appendingPathComponent("entry"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Caches/linked"),
                                  withDestinationURL: outside)
        // Ancestor symlinks must also be rejected before profile discovery.
        try fm.createSymbolicLink(at: home.appendingPathComponent("Library/Application Support/Claude"),
                                  withDestinationURL: outside)

        let quick = await NativeCore.shared.scanCleanup(homeDirectory: home.path)
        let quickPaths = quick.categories.flatMap(\.paths)
        expect(quick.succeeded && quick.deferredPaths.isEmpty, "quick fixture did not complete")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.ordinary"), "ordinary cache group lost")
        expect(quickPaths.contains(home.path + "/Library/Caches/com.example.second"), "sibling cache group lost")
        expect(quickPaths.contains(home.path + "/Library/Caches/Codex/Default/Cache"), "AI cache missing")
        expect(!quickPaths.contains(home.path + "/Library/Caches/Codex"), "AI profile parent offered")
        expect(CleanupRiskPolicy.core(section: "Caches", path: home.path + "/Library/Caches/Codex",
            homeDirectory: home.path).risk == .protected, "empty-cache profile parent was not protected")
        expect(CleanupRiskPolicy.core(section: "Caches", path: home.path + "/Library/Caches/Codex/Default/Cookies",
            homeDirectory: home.path).risk == .protected, "profile cookies were not protected")
        expect(quickPaths.contains(home.path + "/.npm"), "developer cache missing")
        expect(quickPaths.contains(home.path + "/.Trash/old.log"), "Trash missing")
        expect(!quickPaths.contains(where: { $0.contains("huggingface") || $0.contains("sessions")
            || $0.contains("linked") || $0.contains("whitelisted") }), "protected path admitted")
        for a in quickPaths {
            expect(!quickPaths.contains { $0 != a && $0.hasPrefix(a + "/") }, "overlapping scan work")
        }
        let deep = await NativeCore.shared.scanCleanup(homeDirectory: home.path, mode: .deep)
        let deepPaths = Set(deep.categories.flatMap(\.paths))
        expect(deepPaths.isSuperset(of: quickPaths), "deep scan lost quick results")
        expect(deepPaths.contains(home.path + "/Library/Application Support/Example/Cache"), "deep support cache missing")
        expect(deepPaths.contains(home.path + "/Library/Containers/com.example.other/Data/Library/Caches/entry"),
               "deep container cache missing")
        let cancelled = CleanupScanControl(mode: .quick)
        cancelled.cancel()
        let stopped = await NativeCore.shared.scanCleanup(homeDirectory: home.path, control: cancelled)
        expect(!stopped.succeeded && stopped.categories.isEmpty, "cancel returned a successful snapshot")
        let budget = CleanupScanControl(mode: .quick, directoryBudget: 0)
        let partial = await NativeCore.shared.scanCleanup(homeDirectory: home.path, control: budget)
        expect(!partial.deferredPaths.isEmpty && partial.categories.isEmpty, "partial sizes offered as complete")
        let missing = CleanupScanWorker.measure(fixture.appendingPathComponent("missing").path,
                                                control: CleanupScanControl(mode: .deep))
        expect(!missing.complete, "missing directory reported as a complete empty scan")

        let links = fixture.appendingPathComponent("hardlinks")
        try fm.createDirectory(at: links, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8192).write(to: links.appendingPathComponent("first"))
        try fm.linkItem(at: links.appendingPathComponent("first"), to: links.appendingPathComponent("second"))
        try fm.createSymbolicLink(at: links.appendingPathComponent("external"), withDestinationURL: outside)
        let measured = CleanupScanWorker.measure(links.path, control: CleanupScanControl(mode: .deep))
        var directoryStat = stat()
        var fileStat = stat()
        lstat(links.path, &directoryStat)
        lstat(links.appendingPathComponent("first").path, &fileStat)
        let expected = UInt64(directoryStat.st_blocks + fileStat.st_blocks) * 512
        expect(measured.complete && measured.files == 1 && measured.bytes == expected,
               "hardlink accounting or symlink exclusion failed")

        // Enough output to exceed a pipe buffer; no real process list is read.
        let watchdog = DispatchWorkItem { exit(2) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 12, execute: watchdog)
        let output = SystemMetrics.commandOutput("/usr/bin/head", arguments: ["-c", "262144", "/dev/zero"])
        watchdog.cancel()
        expect(output?.utf8.count == 262144, "process output deadlocked or was truncated")

        // Repeatable, isolated throughput sample; creation time is excluded.
        let many = fixture.appendingPathComponent("many")
        try fm.createDirectory(at: many, withIntermediateDirectories: true)
        let payload = Data(repeating: 2, count: 1024)
        for index in 0..<10000 { try payload.write(to: many.appendingPathComponent("file-\(index)")) }
        let benchmark = CleanupScanControl(mode: .deep)
        let sized = CleanupScanWorker.measure(many.path, control: benchmark)
        expect(sized.complete && sized.files == 10000, "benchmark did not count all files")
        print(String(format: "PASS: catalog, grouping, deep scan, exclusions, cancellation, partial sizes, hardlinks, pipe output; 10000 files in %.3fs", benchmark.elapsed))
        print(quick.diagnostics)
        print(deep.diagnostics)
    }
}
