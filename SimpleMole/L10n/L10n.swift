import Foundation
import Combine
import SwiftUI
import os

/// 应用语言。`.auto` 跟随系统，其余为固定语言。
enum AppLanguage: String, CaseIterable, Identifiable {
    case auto
    case zhHans = "zh-Hans"
    case zhHant = "zh-Hant"
    case en
    case ja
    case ko
    case de
    case fr
    case es
    case pt
    case it
    case ru
    case tr

    var id: String { rawValue }

    /// 菜单里显示的语言自称（用各自语言书写）。
    var displayName: String {
        switch self {
        case .auto: return String.localizedDefault("language.auto")
        case .zhHans: return "简体中文"
        case .zhHant: return "繁體中文"
        case .en: return "English"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .es: return "Español"
        case .pt: return "Português"
        case .it: return "Italiano"
        case .ru: return "Русский"
        case .tr: return "Türkçe"
        }
    }
}

/// 轻量国际化：语言表内置于代码（适配 swiftc 直编构建），
/// 缺失键回退 English，再回退键名本身。切换语言即时刷新 UI。
final class L10n: ObservableObject {
    static let shared = L10n()
    static let storageKey = "SMLanguage"

    @Published private(set) var language: AppLanguage
    /// 解析后的实际语言（auto 时为系统匹配结果）。
    private(set) var resolved: AppLanguage
    // 扫描线程也会取文案；切换语言时只替换缓存，避免并发读写字典。
    private let currentTable: OSAllocatedUnfairLock<[String: String]>
    private static let englishTable = table(for: .en)

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey).flatMap(AppLanguage.init(rawValue:))
        let chosen = stored ?? .auto
        language = chosen
        let actual = Self.resolve(chosen)
        resolved = actual
        currentTable = OSAllocatedUnfairLock(initialState:
            actual == .en ? Self.englishTable : Self.table(for: actual))
    }

    /// 切换语言并持久化。
    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        updateResolvedLanguage(Self.resolve(newLanguage))
        language = newLanguage
        UserDefaults.standard.set(newLanguage.rawValue, forKey: Self.storageKey)
    }

    /// 系统偏好语言变化时重新解析（auto 模式）。
    func refreshIfAuto() {
        guard language == .auto else { return }
        let next = Self.resolve(.auto)
        if next != resolved {
            updateResolvedLanguage(next)
            objectWillChange.send()
        }
    }

    private func updateResolvedLanguage(_ next: AppLanguage) {
        guard next != resolved else { return }
        let table = next == .en ? Self.englishTable : Self.table(for: next)
        currentTable.withLock { $0 = table }
        resolved = next
    }

    /// 取当前语言文案；缺失时回退 English，再回退键名。
    func t(_ key: String) -> String {
        currentTable.withLock { $0[key] } ?? Self.englishTable[key] ?? key
    }

    /// 带格式化参数的文案（占位符用 %@ / %d / %ld）。
    func tf(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: Locale.current, arguments: arguments)
    }

    // MARK: - 解析

    private static func resolve(_ choice: AppLanguage) -> AppLanguage {
        guard choice == .auto else { return choice }
        var preferred = UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []
        if preferred.isEmpty {
            preferred = [Locale.preferredLanguages.first ?? "en"]
        }
        for identifier in preferred {
            let normalized = normalize(identifier)
            if let matched = match(normalized) { return matched }
        }
        return .en
    }

    private static func normalize(_ identifier: String) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private static func match(_ identifier: String) -> AppLanguage? {
        // 区域与文字变体归一：pt-BR → pt、zh-CN/zh-Hans-x → zh-Hans 等。
        if identifier.hasPrefix("zh") {
            if identifier.contains("hant") || identifier.contains("tw") || identifier.contains("hk")
                || identifier.contains("mo") {
                return .zhHant
            }
            return .zhHans
        }
        let base = String(identifier.split(separator: "-").first ?? "")
        return AppLanguage(rawValue: base)
    }

    private static func table(for language: AppLanguage) -> [String: String] {
        let base: [String: String]
        switch language {
        case .zhHans: base = L10nTables.zhHans
        case .zhHant: base = L10nTables.zhHant
        case .en: base = L10nTables.en
        case .ja: base = L10nTables.ja
        case .ko: base = L10nTables.ko
        case .de: base = L10nTables.de
        case .fr: base = L10nTables.fr
        case .es: base = L10nTables.es
        case .pt: base = L10nTables.pt
        case .it: base = L10nTables.it
        case .ru: base = L10nTables.ru
        case .tr: base = L10nTables.tr
        case .auto: return [:]
        }
        let withAutoCleanup = base.merging(L10nAutoCleanupTables.table(for: language)) {
            _, featureValue in featureValue
        }
        let withRoadmap = withAutoCleanup.merging(L10nRoadmapTables.table(for: language)) {
            _, featureValue in featureValue
        }
        let withUninstallQueue = withRoadmap.merging(
            L10nUninstallQueueTables.table(for: language)) { _, featureValue in featureValue }
        let withProductivity = withUninstallQueue.merging(
            L10nProductivityTables.table(for: language)) { _, featureValue in featureValue }
        return withProductivity.merging(L10nTrafficTables.table(for: language)) {
            _, featureValue in featureValue
        }
    }
}

// MARK: - 兼容旧式本地化占位

extension String {
    /// L10n 表加载前的极少数启动文案（如语言菜单自身）。
    static func localizedDefault(_ key: String) -> String {
        let language = L10n.shared.resolved
        if language == .zhHans || language == .zhHant { return "自动（跟随系统）" }
        if language == .ja { return "自動（システムに従う）" }
        if language == .ko { return "자동 (시스템 따르기)" }
        if language == .de { return "Automatisch (System)" }
        if language == .fr { return "Automatique (système)" }
        if language == .es { return "Automático (sistema)" }
        if language == .pt { return "Automático (sistema)" }
        if language == .it { return "Automatico (sistema)" }
        if language == .ru { return "Автоматически (как в системе)" }
        if language == .tr { return "Otomatik (sisteme göre)" }
        return "Auto (follow system)"
    }
}

// MARK: - 视图辅助

/// 放在任意视图上即可在语言切换时触发刷新。
struct L10nObserver: ViewModifier {
    @ObservedObject private var l10n = L10n.shared
    func body(content: Content) -> some View { content }
}

extension View {
    /// 订阅语言变化；同时在场景激活时重新解析系统语言（auto 模式）。
    func localized() -> some View {
        modifier(L10nObserver())
            .onAppear { L10n.shared.refreshIfAuto() }
    }
}
