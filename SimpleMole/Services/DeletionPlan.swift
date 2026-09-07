import Foundation
import Darwin

/// 将用户确认时看到的路径绑定到当时的文件对象。
struct DeletionPlan {
    struct Item {
        let record: String
        let identity: String
    }

    let items: [Item]

    init(items: [Item]) {
        self.items = items
    }

    init(paths: [String]) {
        items = Self.nonOverlappingPaths(paths).map {
            Item(record: $0, identity: Self.identity(at: $0) ?? "")
        }
    }

    /// 编码记录与实际文件路径不同时使用（例如 `compress|/path/image.png`）。
    init(records: [String], identityPath: (String) -> String?) {
        items = records.map { record in
            let path = identityPath(record) ?? ""
            return Item(record: record, identity: Self.identity(at: path) ?? "")
        }
    }

    /// NUL 分隔的 `<path><identity>` 记录，避免文件名中的空格和换行改变协议。
    var stdinData: Data {
        var data = Data()
        for item in items {
            data.append(contentsOf: item.record.utf8)
            data.append(0)
            data.append(contentsOf: item.identity.utf8)
            data.append(0)
        }
        return data
    }

    /// 与 Mole 的 `stat -f%d:%i:%m` 使用相同格式。
    static func identity(at path: String) -> String? {
        var metadata = stat()
        // BSD `/usr/bin/stat`（Mole 使用的实现）默认也是 lstat 语义。
        guard Darwin.lstat(path, &metadata) == 0 else { return nil }
        return "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mtimespec.tv_sec)"
    }

    static func nonOverlappingPaths(_ paths: [String]) -> [String] {
        var accepted: [(record: String, normalized: String?)] = []
        for path in paths {
            let normalized = (path as NSString).isAbsolutePath
                ? URL(fileURLWithPath: path).standardizedFileURL.path : nil
            if let normalized,
               accepted.contains(where: { existing in
                   guard let other = existing.normalized else { return false }
                   return normalized == other || normalized.hasPrefix(other + "/")
                       || other.hasPrefix(normalized + "/")
               }) {
                continue
            }
            accepted.append((path, normalized))
        }
        return accepted.map(\.record)
    }
}
