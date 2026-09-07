import Foundation

/// 解析引擎与桥接脚本的文本输出。
enum Parsers {
    struct PreviewEntry {
        let section: String
        let path: String
        let bytes: UInt64
    }

    /// 解析兼容桥接脚本的清理预览文本：`=== 分类 ===` 分组，组内每行
    /// `<绝对路径>  # <容量>`。核心 NativeCore 扫描不经过此解析器。
    static func previewEntries(_ content: String) -> [PreviewEntry] {
        guard !content.isEmpty else { return [] }
        var entries: [PreviewEntry] = []
        var section = ""
        for rawLine in content.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("=== "), line.hasSuffix(" ==="), line.count > 8 {
                section = String(line.dropFirst(4).dropLast(4))
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var candidate = line
            var bytes: UInt64 = 0
            if let commentRange = line.range(of: "  # ") {
                candidate = String(line[..<commentRange.lowerBound])
                bytes = ByteFormat.parse(String(line[commentRange.upperBound...]))
            }
            if candidate.hasPrefix("/"), bytes > 0 {
                entries.append(PreviewEntry(section: section, path: candidate, bytes: bytes))
            }
        }
        return entries
    }

    /// 按预览文件的分组聚合成类别。
    static func previewCategories(_ content: String,
                                  excludingPaths: Set<String> = [],
                                  homeDirectory: String = NSHomeDirectory(),
                                  now: Date = Date(),
                                  trashMinimumAgeDays: Int = 30) -> [CleanupCategory] {
        let excluded = excludingPaths.compactMap(normalizedAbsolutePath)
        let entries = deconflictedPreviewEntries(previewEntries(content).filter { entry in
            guard let path = normalizedAbsolutePath(entry.path) else { return false }
            return !excluded.contains { pathsOverlap(path, $0) }
        })
        let recommendedTrashPaths = Set(entries.compactMap { entry -> String? in
            recommendedTrashPath(entry.path, homeDirectory: homeDirectory,
                                 now: now, minimumAgeDays: trashMinimumAgeDays)
                ? normalizedAbsolutePath(entry.path) : nil
        })
        let classifiedEntries = entries.map { entry -> PreviewEntry in
            guard let path = normalizedAbsolutePath(entry.path),
                  recommendedTrashPaths.contains(path) else { return entry }
            return PreviewEntry(section: L10n.shared.t("file.trash"),
                                path: entry.path, bytes: entry.bytes)
        }
        return groupEntries(classifiedEntries) { entry in
            if let path = normalizedAbsolutePath(entry.path),
               recommendedTrashPaths.contains(path) {
                return CleanupRiskPolicy.recommendedTrash()
            }
            return CleanupRiskPolicy.core(section: entry.section, path: entry.path,
                                          homeDirectory: homeDirectory)
        }
    }

    /// 系统扫描：只保留允许清理的前缀路径，按原分组聚合（容量沿用预览的准确值）。
    static func filteredPreviewCategories(_ content: String, allowedPrefixes: [String]) -> [CleanupCategory] {
        groupEntries(deconflictedPreviewEntries(previewEntries(content).filter { entry in
            allowedPrefixes.contains { entry.path.hasPrefix($0) }
        })) { _ in CleanupRiskPolicy.system() }
    }

    /// 解析系统数据预览 TSV：`entry\tbytes\tgroup\trisk\tname\tdetail\tpath`。
    /// 桥接协议的 risk token 是 safe/review；review 在 UI 侧映射为 Warning。
    /// 列数、分组、风险标记或绝对路径不合法的行直接丢弃；同一物理路径
    /// 只保留最大的一条（预览分组互斥，重复行意味着协议异常）。
    static func systemDataEntries(_ text: String) -> [SystemDataEntry] {
        var byPath: [String: SystemDataEntry] = [:]
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 7, parts[0] == "entry",
                  let bytes = UInt64(parts[1]), bytes > 0,
                  let group = SystemDataGroupKind(rawValue: parts[2]),
                  !parts[4].isEmpty,
                  (parts[6] as NSString).isAbsolutePath else { continue }
            let risk: CleanupRisk
            switch parts[3] {
            case "safe": risk = .safe
            case "review": risk = .warning
            default: continue
            }
            let entry = SystemDataEntry(id: UUID(), group: group, risk: risk,
                                         name: parts[4], detail: parts[5],
                                         path: parts[6], bytes: bytes,
                                         selected: risk == .safe)
            if let existing = byPath[entry.path] {
                if existing.bytes >= entry.bytes { continue }
                byPath[entry.path] = entry
            } else {
                order.append(entry.path)
                byPath[entry.path] = entry
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// 解析系统清理执行的摘要：`removed=/failed=/removed_bytes=`。
    static func systemApplySummary(_ text: String) -> (removed: Int, failed: Int, removedBytes: UInt64) {
        var removed = 0
        var failed = 0
        var removedBytes: UInt64 = 0
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "removed": removed = Int(parts[1]) ?? removed
            case "failed": failed = Int(parts[1]) ?? failed
            case "removed_bytes": removedBytes = UInt64(parts[1]) ?? removedBytes
            default: break
            }
        }
        return (removed, failed, removedBytes)
    }

    private struct CategoryBucketKey: Hashable {
        let section: String
        let source: CleanupSource
        let risk: CleanupRisk
        let disposal: CleanupDisposal
        let applyRoute: CleanupApplyRoute
        let activityGuard: CleanupActivityGuard
        let reasonKey: String
    }

    /// 同一 core section 可能同时包含缓存、偏好设置和备份；必须按策略再拆组。
    private static func groupEntries(
        _ entries: [PreviewEntry],
        policy: (PreviewEntry) -> CleanupPolicyDescriptor
    ) -> [CleanupCategory] {
        var order: [CategoryBucketKey] = []
        var buckets: [CategoryBucketKey: CleanupCategory] = [:]
        for entry in entries {
            let descriptor = policy(entry)
            let key = CategoryBucketKey(section: entry.section,
                                        source: descriptor.source,
                                        risk: descriptor.risk,
                                        disposal: descriptor.disposal,
                                        applyRoute: descriptor.applyRoute,
                                        activityGuard: descriptor.activityGuard,
                                        reasonKey: descriptor.reasonKey)
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = makeCategory(name: entry.section, paths: [], bytes: 0,
                                            policy: descriptor)
            }
            buckets[key]?.appendPath(entry.path, bytes: entry.bytes)
        }
        return order.compactMap { buckets[$0] }.filter { !$0.paths.isEmpty }
    }

    /// 解析扫描桥接脚本的 TSV 输出。
    /// purge：`bytes\tpath`；dev / tools / installer：`bytes\tname\tpath`；
    /// ai：`bytes\tkind\tname\tpath`（kind=model 默认不勾选，apply 侧仍会拒绝）；
    /// slim：`bytes\tname\top|path`。
    /// purge 与 slim 的分类名在此映射为当前语言。
    static func specialCategories(_ text: String, family: CleanupFamily) -> [CleanupCategory] {
        var categories: [CleanupCategory] = []
        var acceptedPaths: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            if family == .ai || family == .xcode {
                guard parts.count >= 4 else { continue }
                let bytes = UInt64(parts[0]) ?? 0
                guard bytes > 0 else { continue }
                guard let path = deconflictedPath(parts[3], accepted: &acceptedPaths) else {
                    continue
                }
                let descriptor = family == .ai
                    ? CleanupRiskPolicy.ai(kind: parts[1], path: path)
                    : CleanupRiskPolicy.xcode(kind: parts[1], path: path)
                categories.append(makeCategory(name: parts[2], paths: [path],
                                               bytes: bytes, policy: descriptor))
                continue
            }
            let isPurge = family == .purge
            guard isPurge ? parts.count >= 2 : parts.count >= 3 else { continue }
            let bytes = UInt64(parts[0]) ?? 0
            guard bytes > 0 else { continue }
            if isPurge {
                let rawPath = parts.count >= 6 ? parts[5] : parts[1]
                guard let path = deconflictedPath(rawPath, accepted: &acceptedPaths),
                      path.hasPrefix("/") else { continue }
                let risk = parts.count >= 6
                    ? (CleanupRisk(rawValue: parts[1]) ?? .protected) : .warning
                let runtimeReason: String?
                if parts.count >= 6, parts[3] == "active" {
                    runtimeReason = "cleanup.risk.runningApplication"
                } else if parts.count >= 6, parts[3] != "idle" {
                    runtimeReason = "cleanup.risk.runtimeUnknown"
                } else {
                    runtimeReason = nil
                }
                categories.append(makeCategory(
                    name: L10n.shared.tf("file.purge", (path as NSString).lastPathComponent),
                    paths: [path], bytes: bytes,
                    policy: CleanupRiskPolicy.projectArtifact(
                        risk: risk, runtimeReasonKey: runtimeReason)))
            } else {
                var name = parts[1]
                if family == .slim {
                    if name.hasPrefix("图片重复文件") {
                        let hash = name.components(separatedBy: " · ").last ?? ""
                        name = L10n.shared.t("slim.duplicate") + " · " + hash
                    } else if name == "图片压缩候选" {
                        name = L10n.shared.t("slim.compress")
                    }
                }
                let descriptor: CleanupPolicyDescriptor
                switch family {
                case .dev:
                    guard let path = deconflictedPath(parts[2], accepted: &acceptedPaths) else {
                        continue
                    }
                    descriptor = CleanupRiskPolicy.developerCache(path: path)
                    categories.append(makeCategory(name: name, paths: [path],
                                                   bytes: bytes, policy: descriptor))
                    continue
                case .tools:
                    descriptor = CleanupRiskPolicy.tool()
                case .slim:
                    descriptor = CleanupRiskPolicy.slim()
                case .system:
                    descriptor = CleanupRiskPolicy.system()
                case .clean:
                    descriptor = CleanupRiskPolicy.core(section: name, path: parts[2])
                case .purge:
                    descriptor = CleanupRiskPolicy.projectArtifact()
                case .ai, .xcode:
                    continue
                }
                categories.append(makeCategory(name: name, paths: [parts[2]],
                                               bytes: bytes, policy: descriptor))
            }
        }
        return categories
    }

    /// Trashed-app evidence scanner TSV:
    /// `bytes\tapp name\tbundle id\tabsolute leftover path`.
    /// Results are grouped per app. Exact bundle cache/log leftovers can be
    /// Safe; preferences and user data remain Warning and are filtered out of
    /// the cleanup page by its final candidate policy.
    static func orphanedAppCategories(_ text: String) -> [CleanupCategory] {
        struct Key: Hashable { let name: String; let bundleID: String }
        var order: [Key] = []
        var buckets: [Key: CleanupCategory] = [:]
        var acceptedPaths: [String] = []

        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4,
                  let bytes = UInt64(parts[0]),
                  !parts[1].isEmpty, !parts[2].isEmpty,
                  let path = deconflictedPath(parts[3], accepted: &acceptedPaths),
                  (path as NSString).isAbsolutePath else { continue }
            let descriptor = CleanupRiskPolicy.appLeftover(
                path: path, bundleIdentifier: parts[2])
            let key = Key(name: parts[1], bundleID: parts[2])
            if buckets[key] == nil {
                order.append(key)
                buckets[key] = makeCategory(
                    name: L10n.shared.tf("file.appLeftover", parts[1]),
                    paths: [], bytes: 0, policy: descriptor)
            }
            // Protected and removable paths must not share a category because
            // one category carries a single risk and apply route.
            if buckets[key]?.risk != descriptor.risk {
                let splitKey = Key(name: parts[1] + "#" + descriptor.risk.rawValue,
                                   bundleID: parts[2])
                if buckets[splitKey] == nil {
                    order.append(splitKey)
                    buckets[splitKey] = makeCategory(
                        name: L10n.shared.tf("file.appLeftover", parts[1]),
                        paths: [], bytes: 0, policy: descriptor)
                }
                buckets[splitKey]?.appendPath(path, bytes: bytes)
            } else {
                buckets[key]?.appendPath(path, bytes: bytes)
            }
        }
        return order.compactMap { buckets[$0] }.filter { !$0.paths.isEmpty }
    }

    /// 安装包扫描与开发缓存共用三列 TSV，但安全来源和 apply route 不同。
    /// 完整扫描应直接调用这个 API，不要再借用 `.dev` 解析。
    static func installerCategory(_ text: String) -> CleanupCategory? {
        var paths: [String] = []
        var pathBytes: [String: UInt64] = [:]
        var acceptedPaths: [String] = []
        var bytes: UInt64 = 0
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, (parts[2] as NSString).isAbsolutePath else { continue }
            let pathSize = UInt64(parts[0]) ?? 0
            guard pathSize > 0 else { continue }
            guard let path = deconflictedPath(parts[2], accepted: &acceptedPaths) else { continue }
            paths.append(path)
            pathBytes[path] = pathSize
            bytes &+= pathSize
        }
        guard !paths.isEmpty else { return nil }
        return makeCategory(name: L10n.shared.t("file.installer"), paths: paths, bytes: bytes,
                            pathBytes: pathBytes,
                            policy: CleanupRiskPolicy.installer())
    }

    private static func makeCategory(name: String,
                                     paths: [String],
                                     bytes: UInt64,
                                     pathBytes: [String: UInt64]? = nil,
                                     policy: CleanupPolicyDescriptor) -> CleanupCategory {
        CleanupCategory(name: name, paths: paths, bytes: bytes, pathBytes: pathBytes,
                        source: policy.source, risk: policy.risk,
                        disposal: policy.disposal, applyRoute: policy.applyRoute,
                        activityGuard: policy.activityGuard, reasonKey: policy.reasonKey)
    }

    private static func deconflictedPreviewEntries(_ entries: [PreviewEntry]) -> [PreviewEntry] {
        var accepted: [String] = []
        return entries.compactMap { entry in
            guard let path = deconflictedPath(entry.path, accepted: &accepted) else { return nil }
            return PreviewEntry(section: entry.section, path: path, bytes: entry.bytes)
        }
    }

    /// Preserve scanner order and give each physical subtree one owner. This is
    /// deliberately conservative: a later parent never expands an earlier plan.
    private static func deconflictedPath(_ rawPath: String,
                                         accepted: inout [String]) -> String? {
        guard let path = normalizedAbsolutePath(rawPath) else { return rawPath }
        guard !accepted.contains(where: { pathsOverlap(path, $0) }) else { return nil }
        accepted.append(path)
        return path
    }

    private static func normalizedAbsolutePath(_ path: String) -> String? {
        guard (path as NSString).isAbsolutePath else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }

    /// 调用方可用年龄阈值控制默认选择（清理页传 0，表示用户已经主动
    /// 放入废纸篓的普通顶层条目可直接列出）。App 包和隐藏目录保留给用户
    /// 判断；最终执行还会递归检查模型、会话和数据库标记。
    private static func recommendedTrashPath(_ rawPath: String,
                                             homeDirectory: String,
                                             now: Date,
                                             minimumAgeDays: Int) -> Bool {
        guard minimumAgeDays >= 0,
              let path = normalizedAbsolutePath(rawPath) else { return false }
        let trashRoot = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".Trash", isDirectory: true)
            .standardizedFileURL.path
        guard path.hasPrefix(trashRoot + "/") else { return false }
        let remainder = String(path.dropFirst(trashRoot.count + 1))
        guard !remainder.isEmpty, !remainder.contains("/") else { return false }

        let leaf = URL(fileURLWithPath: path).lastPathComponent
        let lowerLeaf = leaf.lowercased()
        let protectedNames: Set<String> = [
            "cookies", "history", "login data", "web data", "bookmarks",
            "preferences", "secure preferences"
        ]
        let protectedExtensions: Set<String> = ["db", "sqlite", "sqlite3"]
        guard !leaf.hasPrefix("."),
              URL(fileURLWithPath: leaf).pathExtension.lowercased() != "app",
              !protectedNames.contains(lowerLeaf),
              !lowerLeaf.hasSuffix("-wal"), !lowerLeaf.hasSuffix("-shm"),
              !lowerLeaf.hasSuffix("-journal"),
              !protectedExtensions.contains(
                URL(fileURLWithPath: leaf).pathExtension.lowercased()),
              !CleanupRiskPolicy.isSensitiveAutomationPath(path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType != .typeSymbolicLink,
              let modified = attributes[.modificationDate] as? Date else { return false }
        let cutoff = now.addingTimeInterval(-Double(minimumAgeDays) * 86_400)
        return modified <= cutoff
    }

    private static func pathsOverlap(_ lhs: String, _ rhs: String) -> Bool {
        lhs == rhs || lhs.hasPrefix(rhs + "/") || rhs.hasPrefix(lhs + "/")
    }

    /// 解析 apply 脚本的 `removed=/failed=` 摘要。
    static func applySummary(_ text: String) -> (removed: Int, failed: Int) {
        var removed = 0
        var failed = 0
        for line in text.components(separatedBy: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "removed": removed = Int(parts[1]) ?? removed
            case "failed": failed = Int(parts[1]) ?? failed
            default: break
            }
        }
        return (removed, failed)
    }

    /// 解析图片清单 TSV：`bytes\twidth\theight\tpath`。
    static func imageItems(_ text: String) -> [ImageItem] {
        var items: [ImageItem] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4 else { continue }
            items.append(ImageItem(bytes: UInt64(parts[0]) ?? 0,
                                   width: Int(parts[1]) ?? 0,
                                   height: Int(parts[2]) ?? 0,
                                   path: parts[3]))
        }
        return items
    }

    /// 解析开发环境 TSV：`bytes\tkind\tname\tpath`。同一路径出现多次时
    /// 保留 current 记录（nvm 默认版本会与 family 扫描重复）。
    static func devEnvEntries(_ text: String) -> [DevEnvEntry] {
        var byPath: [String: DevEnvEntry] = [:]
        var order: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, parts[3].hasPrefix("/") else { continue }
            let entry = DevEnvEntry(bytes: UInt64(parts[0]) ?? 0,
                                    kind: parts[1], name: parts[2], path: parts[3],
                                    relatedBytes: parts.count > 4 ? UInt64(parts[4]) ?? 0 : 0,
                                    relatedPath: parts.count > 5 && parts[5].hasPrefix("/")
                                        ? parts[5] : nil)
            if let existing = byPath[entry.path] {
                if entry.isCurrent && !existing.isCurrent { byPath[entry.path] = entry }
            } else {
                order.append(entry.path)
                byPath[entry.path] = entry
            }
        }
        return order.compactMap { byPath[$0] }
    }

    /// 专用 AI 内容清单：`bytes\tkind\tname\tpath`。
    static func analyzeAIItems(_ text: String) -> [AnalyzeAIItem] {
        var byPath: [String: AnalyzeAIItem] = [:]
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count == 4,
                  let bytes = UInt64(parts[0]), bytes > 0,
                  let kind = AnalyzeAIItem.Kind(rawValue: parts[1]),
                  !parts[2].isEmpty, parts[3].hasPrefix("/") else { continue }
            let item = AnalyzeAIItem(bytes: bytes, kind: kind,
                                     name: parts[2], path: parts[3])
            if let existing = byPath[item.path], existing.bytes >= item.bytes { continue }
            byPath[item.path] = item
        }
        return byPath.values.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// 解析 APFS 快照桥接输出：`purgeable\tbytes` 与 `snapshot\tname`。
    static func snapshotInfo(_ text: String) -> (purgeable: UInt64, names: [String]) {
        var purgeable: UInt64 = 0
        var names: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "purgeable": purgeable = UInt64(parts[1]) ?? 0
            case "snapshot": names.append(parts[1])
            default: break
            }
        }
        return (purgeable, names)
    }

    /// 解析 `docker system df` 桥接输出：`type\tcount\tsize\treclaimable`。
    static func dockerDfRows(_ text: String) -> [DockerDfRow] {
        var rows: [DockerDfRow] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, !parts[0].isEmpty else { continue }
            rows.append(DockerDfRow(type: parts[0], count: parts[1],
                                    size: parts[2], reclaimable: parts[3]))
        }
        return rows
    }

    /// 解析重复检测桥接输出：`bytes\tdupkey\tpath`，相邻同 key 聚为一组。
    static func duplicateGroups(_ text: String) -> [[AnalyzeEntry]] {
        var groups: [[AnalyzeEntry]] = []
        var current: [AnalyzeEntry] = []
        var currentKey = ""
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3, parts[2].hasPrefix("/") else { continue }
            if parts[1] != currentKey {
                if current.count >= 2 { groups.append(current) }
                current = []
                currentKey = parts[1]
            }
            current.append(AnalyzeEntry(
                name: (parts[2] as NSString).lastPathComponent,
                path: parts[2],
                size: UInt64(parts[0]) ?? 0,
                isDir: false))
        }
        if current.count >= 2 { groups.append(current) }
        return groups
    }

    /// 解析 Shell 配置体检输出：`file\tkind\tdetail\tline`。
    static func shellIssues(_ text: String) -> [ShellIssue] {
        var issues: [ShellIssue] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 4, parts[0].hasPrefix("/") else { continue }
            issues.append(ShellIssue(file: parts[0], kind: parts[1],
                                     detail: parts[2], line: Int(parts[3]) ?? 0))
        }
        return issues
    }

    /// 解析网络体检输出：proxy 行与 hosts 行。
    static func netAudit(_ text: String) -> (proxies: [ProxyIssue], hosts: [String]) {
        var proxies: [ProxyIssue] = []
        var hosts: [String] = []
        for line in text.components(separatedBy: "\n") {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 2 else { continue }
            switch parts[0] {
            case "proxy" where parts.count >= 4:
                proxies.append(ProxyIssue(service: parts[1], kind: parts[2], endpoint: parts[3]))
            case "hosts":
                hosts.append(parts[1])
            default:
                break
            }
        }
        return (proxies, hosts)
    }
}
