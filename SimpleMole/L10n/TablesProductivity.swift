import Foundation

/// 设置、剪贴板历史与截图编辑器新增文案。
enum L10nProductivityTables {
    static func table(for language: AppLanguage) -> [String: String] {
        switch language {
        case .zhHans: return zhHans
        case .zhHant: return zhHant
        case .en: return en
        case .ja: return ja
        case .ko: return ko
        case .de: return de
        case .fr: return fr
        case .es: return es
        case .pt: return pt
        case .it: return it
        case .ru: return ru
        case .tr: return tr
        case .auto: return [:]
        }
    }

    private static let en = values(
        title: "Settings", pages: "Visible pages",
        pagesHint: "Keep at least one page visible. Changes apply immediately.",
        count: "%d items in memory", clear: "Clear history",
        capture: "Take screenshot", permission: "Screen Recording…",
        conflict: "The shortcut is already used by another app.",
        copied: "Copied ✓", failed: "Operation failed").merging([
            "tab.clipboard": "Clipboard",
            "settings.clipboard.capacity": "Maximum recent items",
            "clip.summary": "%d / %d recent · %d pinned",
            "clip.clearUnpinned": "Clear unpinned",
            "clip.copy": "Copy",
            "clip.delete": "Delete",
            "clip.pin": "Pin",
            "clip.unpin": "Unpin",
            "clip.filter": "Filter",
            "clip.filter.all": "All",
            "clip.filter.pinned": "Pinned",
            "clip.filter.text": "Text",
            "clip.filter.url": "URLs",
            "clip.filter.file": "Files",
            "clip.filter.image": "Images",
            "clip.filter.empty": "No matching clipboard entries",
            "clip.kind.text": "Text",
            "clip.kind.url": "URL",
            "clip.kind.file": "File",
            "clip.kind.image": "Image",
            "clip.imageUnavailable": "Image preview unavailable",
            "permissions.title": "Permission Center",
            "permissions.subtitle": "Configure macOS access once, before a feature needs it.",
            "permissions.openCenter": "Permission Center",
            "permissions.drag.hint.disk": "Drag this card into the Full Disk Access list, then turn on its switch",
            "permissions.drag.hint.screen": "Drag this card into the Screen Recording list, then turn on its switch",
            "permissions.disk.notDetected": "Disk access is not active yet. Enable the app switch in System Settings, then return and recheck.",
            "permissions.fullDisk.title": "Full Disk Access",
            "permissions.fullDisk.detail": "Required for full cleaning, disk analysis, and leftover scans. Protected folders are never accessed before authorization.",
            "permissions.screen.title": "Screen recording",
            "permissions.screen.detail": "Optional. Used only by the screenshot shortcut (⌘⌃A) and editor.",
            "permissions.screen.action": "Request access",
            "permissions.screen.restartHint": "Granted but still not working? Screen recording only takes effect after the app quits and reopens. Rebuilt development copies need the grant again.",
            "permissions.screen.restart": "Restart App",
            "permissions.status.required": "Required for full scan",
            "permissions.status.granted": "Granted",
            "permissions.status.optional": "Optional",
            "permissions.openSettings": "Open settings",
            "permissions.openFullDiskSettings": "Open Full Disk Access",
            "permissions.recheck": "Recheck",
            "permissions.noAccessibility": "Accessibility is not requested: the global shortcut uses the Carbon hotkey API.",
            "permissions.footer": "macOS keeps final control of every permission. You can revoke access in System Settings at any time.",
            "permissions.footer.openFullDisk": "Open Full Disk Access, drag the app card into the list, and enable its switch.",
            "permissions.footer.pendingScan": "Once Full Disk Access is detected, ForgeSweep will automatically continue the scan you requested.",
            "permissions.continue": "Continue",
            "permissions.continue.requiresDiskAccess": "Grant Full Disk Access before continuing",
        ]) { _, new in new }

    private static let zhHans = values(
        title: "设置", pages: "显示的功能页",
        pagesHint: "至少保留一个功能页，修改会立即生效。",
        count: "内存中有 %d 条记录", clear: "清空历史",
        capture: "立即截图", permission: "屏幕录制权限…",
        conflict: "快捷键已被其他应用占用。",
        copied: "已复制 ✓", failed: "操作失败").merging([
            "tab.clipboard": "剪贴板",
            "settings.clipboard.capacity": "最近记录上限",
            "clip.summary": "最近 %d / %d 条 · 已置顶 %d 条",
            "clip.clearUnpinned": "清理未置顶",
            "clip.copy": "复制",
            "clip.delete": "删除",
            "clip.pin": "置顶",
            "clip.unpin": "取消置顶",
            "clip.filter": "筛选",
            "clip.filter.all": "全部",
            "clip.filter.pinned": "置顶",
            "clip.filter.text": "文本",
            "clip.filter.url": "网址",
            "clip.filter.file": "文件",
            "clip.filter.image": "图片",
            "clip.filter.empty": "没有符合筛选条件的记录",
            "clip.kind.text": "文本",
            "clip.kind.url": "网址",
            "clip.kind.file": "文件",
            "clip.kind.image": "图片",
            "clip.imageUnavailable": "无法显示图片预览",
            "permissions.title": "权限中心",
            "permissions.subtitle": "在功能首次使用前集中完成 macOS 权限配置。",
            "permissions.openCenter": "权限中心",
            "permissions.drag.hint.disk": "将这张卡片拖入「完全磁盘访问」列表，再打开右侧开关",
            "permissions.drag.hint.screen": "将这张卡片拖入「屏幕录制」列表，再打开右侧开关",
            "permissions.disk.notDetected": "尚未检测到磁盘访问权限。请在系统设置中开启应用右侧开关，再返回重新检测。",
            "permissions.fullDisk.title": "完全磁盘访问",
            "permissions.fullDisk.detail": "全盘清理、磁盘分析和卸载残留扫描必需；授权前不会读取桌面、文稿等受保护目录。",
            "permissions.screen.title": "屏幕录制",
            "permissions.screen.detail": "可选，仅用于截图快捷键（⌘⌃A）和截图编辑器。",
            "permissions.screen.action": "请求授权",
            "permissions.screen.restartHint": "已授权但仍无反应？屏幕录制授权需要退出并重新打开应用后才生效；重新编译过的开发版需要重新授权。",
            "permissions.screen.restart": "重启应用",
            "permissions.status.required": "全盘扫描必需",
            "permissions.status.granted": "已授权",
            "permissions.status.optional": "可选",
            "permissions.openSettings": "打开设置",
            "permissions.openFullDiskSettings": "打开完全磁盘访问",
            "permissions.recheck": "重新检测",
            "permissions.noAccessibility": "无需辅助功能权限：全局快捷键使用 Carbon HotKey API。",
            "permissions.footer": "每项权限最终仍由 macOS 控制，可随时在系统设置中撤销。",
            "permissions.footer.openFullDisk": "打开“完全磁盘访问”，把上方应用卡片拖入列表并开启右侧开关。",
            "permissions.footer.pendingScan": "检测到完全磁盘访问权限后，将自动继续刚才的扫描。",
            "permissions.continue": "继续",
            "permissions.continue.requiresDiskAccess": "请先授予完全磁盘访问权限",
        ]) { _, new in new }

    private static let zhHant = values(
        title: "設定", pages: "顯示的功能頁",
        pagesHint: "至少保留一個功能頁，修改會立即生效。",
        count: "記憶體中有 %d 筆記錄", clear: "清除歷史",
        capture: "立即截圖", permission: "螢幕錄製權限…",
        conflict: "快速鍵已被其他 App 使用。",
        copied: "已複製 ✓", failed: "操作失敗")

    private static let ja = values(
        title: "設定", pages: "表示するページ",
        pagesHint: "少なくとも1ページを表示してください。変更はすぐ反映されます。",
        count: "メモリ内に %d 件", clear: "履歴を消去",
        capture: "スクリーンショット", permission: "画面収録の権限…",
        conflict: "ショートカットは別のアプリで使用中です。",
        copied: "コピー済み ✓", failed: "操作に失敗しました")

    private static let ko = values(
        title: "설정", pages: "표시할 페이지",
        pagesHint: "페이지를 하나 이상 유지해야 합니다. 변경 사항은 즉시 적용됩니다.",
        count: "메모리에 %d개 항목", clear: "기록 지우기",
        capture: "스크린샷 찍기", permission: "화면 기록 권한…",
        conflict: "다른 앱에서 이 단축키를 사용 중입니다.",
        copied: "복사됨 ✓", failed: "작업 실패")

    private static let de = values(
        title: "Einstellungen", pages: "Sichtbare Seiten",
        pagesHint: "Mindestens eine Seite muss sichtbar bleiben. Änderungen gelten sofort.",
        count: "%d Einträge im Speicher", clear: "Verlauf löschen",
        capture: "Screenshot aufnehmen", permission: "Bildschirmaufnahme…",
        conflict: "Das Tastenkürzel wird bereits von einer anderen App verwendet.",
        copied: "Kopiert ✓", failed: "Vorgang fehlgeschlagen")

    private static let fr = values(
        title: "Réglages", pages: "Pages visibles",
        pagesHint: "Gardez au moins une page visible. Les changements sont immédiats.",
        count: "%d éléments en mémoire", clear: "Effacer l’historique",
        capture: "Prendre une capture", permission: "Enregistrement de l’écran…",
        conflict: "Le raccourci est déjà utilisé par une autre app.",
        copied: "Copié ✓", failed: "Échec de l’opération")

    private static let es = values(
        title: "Ajustes", pages: "Páginas visibles",
        pagesHint: "Mantén al menos una página visible. Los cambios se aplican al instante.",
        count: "%d elementos en memoria", clear: "Borrar historial",
        capture: "Hacer captura", permission: "Grabación de pantalla…",
        conflict: "Otra app ya usa este atajo.",
        copied: "Copiado ✓", failed: "La operación falló")

    private static let pt = values(
        title: "Ajustes", pages: "Páginas visíveis",
        pagesHint: "Mantenha pelo menos uma página visível. As alterações são imediatas.",
        count: "%d itens na memória", clear: "Limpar histórico",
        capture: "Capturar tela", permission: "Gravação da tela…",
        conflict: "O atalho já está sendo usado por outro app.",
        copied: "Copiado ✓", failed: "Falha na operação")

    private static let it = values(
        title: "Impostazioni", pages: "Pagine visibili",
        pagesHint: "Mantieni visibile almeno una pagina. Le modifiche sono immediate.",
        count: "%d elementi in memoria", clear: "Cancella cronologia",
        capture: "Acquisisci schermata", permission: "Registrazione schermo…",
        conflict: "La scorciatoia è già usata da un’altra app.",
        copied: "Copiato ✓", failed: "Operazione non riuscita")

    private static let ru = values(
        title: "Настройки", pages: "Видимые разделы",
        pagesHint: "Оставьте видимым хотя бы один раздел. Изменения применяются сразу.",
        count: "В памяти: %d", clear: "Очистить историю",
        capture: "Сделать снимок", permission: "Запись экрана…",
        conflict: "Сочетание клавиш уже занято другим приложением.",
        copied: "Скопировано ✓", failed: "Операция не выполнена")

    private static let tr = values(
        title: "Ayarlar", pages: "Görünür sayfalar",
        pagesHint: "En az bir sayfa görünür kalmalıdır. Değişiklikler hemen uygulanır.",
        count: "Bellekte %d öğe", clear: "Geçmişi temizle",
        capture: "Ekran görüntüsü al", permission: "Ekran Kaydı…",
        conflict: "Kısayol başka bir uygulama tarafından kullanılıyor.",
        copied: "Kopyalandı ✓", failed: "İşlem başarısız")

    private static func values(title: String, pages: String, pagesHint: String,
                               count: String, clear: String, capture: String,
                               permission: String, conflict: String,
                               copied: String, failed: String) -> [String: String] {
        [
            "settings.title": title,
            "settings.pages": pages,
            "settings.pages.hint": pagesHint,
            "settings.clipboard.count": count,
            "settings.clipboard.clear": clear,
            "settings.screenshot.capture": capture,
            "settings.screenshot.permission": permission,
            "settings.screenshot.conflict": conflict,
            "shot.copied": copied,
            "shot.failed": failed,
        ]
    }
}
