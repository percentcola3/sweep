import Foundation

/// 定向风险单测不需要编译完整的多语言表。
final class L10n {
    static let shared = L10n()

    func t(_ key: String) -> String { key }
    func tf(_ key: String, _ arguments: CVarArg...) -> String { key }
}
