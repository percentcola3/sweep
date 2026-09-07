import Foundation

/// Pure display projection. Called only when inventory/search changes, on the
/// inventory presentation queue, not on every metrics tick or tab animation.
enum UninstallListProjection {
    static func apps(_ apps: [UninstallApp], plans: [String: UninstallPlan],
                     query: String) -> [UninstallApp] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        let totals = Dictionary(matches.map {
            ($0.id, plans[$0.id]?.space.totalBytes ?? ByteFormat.parse($0.size))
        }, uniquingKeysWith: { first, _ in first })
        return matches.sorted { lhs, rhs in
            let lhsBytes = totals[lhs.id] ?? 0
            let rhsBytes = totals[rhs.id] ?? 0
            if lhsBytes != rhsBytes { return lhsBytes > rhsBytes }
            let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
            if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
            return lhs.id < rhs.id
        }
    }
}
