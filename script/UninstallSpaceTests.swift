import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct UninstallSpaceTests {
    static func main() {
        let files = [
            UninstallFile(bytes: 100, label: "app", path: "/Applications/Test.app"),
            UninstallFile(bytes: 30, label: "related", path: "/Users/test/Library/Caches/com.test"),
            UninstallFile(bytes: 20, label: "related", path: "/Users/test/Library/Caches/com.test/Code Cache"),
            UninstallFile(bytes: 10, label: "related", path: "/Users/test/Library/Application Support/Test"),
            UninstallFile(bytes: 50, label: "review", path: "/Library/Test.review"),
            UninstallFile(bytes: 60, label: "manual", path: "Test")
        ]
        let breakdown = UninstallSpaceBreakdown(files: files,
                                                homeDirectory: "/Users/test")
        expect(breakdown.appBytes == 100, "app bundle must be counted once")
        expect(breakdown.cacheBytes == 30, "cache parent must cover its child")
        expect(breakdown.dataBytes == 10, "app data must remain separate from cache")
        expect(breakdown.totalBytes == 140, "review/manual rows must not enter reclaimable total")

        let duplicatePath = UninstallSpaceBreakdown(files: [
            UninstallFile(bytes: 75, label: "app", path: "/Applications/Same.app"),
            UninstallFile(bytes: 999, label: "related", path: "/Applications/Same.app")
        ])
        expect(duplicatePath.appBytes == 75 && duplicatePath.totalBytes == 75,
               "same-path app row must win over a duplicate related row")
        expect(UninstallFile(bytes: 75, label: "app", path: "/Applications/Same.app").id !=
               UninstallFile(bytes: 999, label: "related", path: "/Applications/Same.app").id,
               "same-path rows with different roles need unique SwiftUI identities")

        expect(UninstallFile(bytes: 1, label: "related",
                             path: "/Users/test/.cache/pip/http").isCache(homeDirectory: "/Users/test"),
               "explicit developer cache roots must be classified as cache")
        expect(UninstallFile(bytes: 1, label: "related",
                             path: "/Users/test/Library/Containers/id/Data/tmp/item")
                .isCache(homeDirectory: "/Users/test"),
               "container tmp must be classified as cache")
        expect(UninstallFile(bytes: 1, label: "related",
                             path: "/Users/test/Library/Containers/id/Data/Library/Caches/item")
                .isCache(homeDirectory: "/Users/test"),
               "container Library/Caches must be classified as cache")
        expect(UninstallFile(bytes: 1, label: "related",
                             path: "/Users/test/Library/Group Containers/group.id/Library/Caches/item")
                .isCache(homeDirectory: "/Users/test"),
               "group-container Library/Caches must be classified as cache")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/Library/CachesBackup/id")
                .isCache(homeDirectory: "/Users/test"),
               "cache path matching must respect component boundaries")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/Code/Data/tmp")
                .isCache(homeDirectory: "/Users/test"),
               "ordinary project Data/tmp must remain app data")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/.cache/lm-studio/models/model.bin")
                .isCache(homeDirectory: "/Users/test"),
               "protected model data must never be presented as cleanable cache")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/Library/Containers/com.docker.docker/Data/tmp/item")
                .isCache(homeDirectory: "/Users/test"),
               "protected Docker data must never be presented as cleanable cache")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/Library/Application Support/Test")
                .isCache(homeDirectory: "/Users/test"),
               "Application Support must remain app data")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/Library/Containers/com.test")
                .isCache(homeDirectory: "/Users/test"),
               "containers must not be presented as cache")
        expect(!UninstallFile(bytes: 1, label: "related",
                              path: "/Users/test/Library/WebKit/com.test")
                .isCache(homeDirectory: "/Users/test"),
               "WebKit state must not be presented as safely regenerable cache")

        let saturated = UninstallSpaceBreakdown(files: [
            UninstallFile(bytes: .max, label: "app", path: "/Applications/Huge.app"),
            UninstallFile(bytes: 1, label: "related", path: "/Users/test/.cache/huge")
        ])
        expect(saturated.totalBytes == .max, "space totals must saturate instead of overflowing")

        let fixture = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("simplemole-uninstall-cache-\(UUID().uuidString)")
        let appURL = fixture.appendingPathComponent("Fixture.app")
        let cacheURL = fixture.appendingPathComponent("inventory.json")
        try? FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        let fixtureApp = UninstallApp(name: "Fixture", bundleID: "com.example.fixture",
                                      source: "App", path: appURL.path, size: "1 B")
        let fixturePlan = UninstallPlan(
            files: [UninstallFile(bytes: 1, label: "app", path: appURL.path)],
            needsAdmin: false, isBrewCask: false, caskToken: "-",
            includesProtectedAppData: false, scannedAt: Date())
        let planData = try! JSONEncoder().encode(fixturePlan)
        let decodedPlan = try! JSONDecoder().decode(UninstallPlan.self, from: planData)
        expect(decodedPlan.space == fixturePlan.space,
               "decoded plans must reconstruct the cached space summary")
        let planJSON = try! JSONSerialization.jsonObject(with: planData) as! [String: Any]
        expect(planJSON["space"] == nil,
               "derived space must not alter the persisted inventory schema")

        let smallBundle = UninstallApp(name: "With data", bundleID: "com.example.withdata",
            source: "App", path: "/Applications/WithData.app", size: "10 B",
            appIdentity: "fixture", infoIdentity: "fixture")
        let largeBundle = UninstallApp(name: "Large bundle", bundleID: "com.example.large",
            source: "App", path: "/Applications/Large.app", size: "100 B",
            appIdentity: "fixture", infoIdentity: "fixture")
        let largePlan = UninstallPlan(files: [
            .init(bytes: 10, label: "app", path: smallBundle.path),
            .init(bytes: 200, label: "related", path: "/Users/test/Library/Application Support/WithData")
        ], needsAdmin: false, isBrewCask: false, caskToken: "-",
           includesProtectedAppData: false, scannedAt: Date())
        let plans = [smallBundle.id: largePlan]
        expect(UninstallListProjection.apps([largeBundle, smallBundle], plans: plans, query: "")
            .map(\.id) == [smallBundle.id, largeBundle.id],
            "background projection must sort by app plus data, with bundle-size fallback")
        expect(UninstallListProjection.apps([smallBundle, largeBundle], plans: plans,
                                             query: "  COM.EXAMPLE.LARGE\n") == [largeBundle],
               "background projection must preserve trimmed, case-insensitive bundle search")
        UninstallInventoryCache.save([.init(app: fixtureApp, plan: fixturePlan)], to: cacheURL)
        expect(UninstallInventoryCache.restore(from: cacheURL).count == 1,
               "valid uninstall inventory must survive app restart")
        try? FileManager.default.removeItem(at: appURL)
        expect(UninstallInventoryCache.restore(from: cacheURL).isEmpty,
               "cache restore must discard an externally uninstalled app")
        try? FileManager.default.removeItem(at: fixture)

        print("Uninstall space tests passed")
    }
}
