import Foundation

/// Uninstall queue copy is kept in a feature table so every locale receives
/// the same state vocabulary without making the base navigation table harder
/// to audit.  Queue labels are intentionally short because they are rendered
/// inline in app rows as well as in the compact queue panel.
enum L10nUninstallQueueTables {
    static let en: [String: String] = [
        "uninstall.loading": "Preparing app list…",
        "uninstall.queue.title": "Uninstall queue",
        "uninstall.queue.summary": "%d active · %d queued · %d recent",
        "uninstall.queue.dismiss": "Dismiss finished",
        "uninstall.queue.cancel": "Cancel",
        "uninstall.queue.waiting": "Queued · #%d",
        "uninstall.queue.queued": "Queued",
        "uninstall.queue.preparing": "Preparing",
        "uninstall.queue.running": "Removing…",
        "uninstall.queue.succeeded": "Completed",
        "uninstall.queue.failed": "Failed · try again",
        "uninstall.queue.retry": "Retry",
        "uninstall.queue.confirm": "After confirmation, requests are added to the queue and processed in order in the background. You can cancel queued requests; macOS may ask for administrator authorization separately.",
        "uninstall.queue.add": "Add to uninstall queue",
        "uninstall.queue.permissionLost": "Disk access authorization is no longer available. Authorize again before adding this app.",
    ]

    static let zhHans: [String: String] = [
        "uninstall.loading": "正在准备应用列表…",
        "uninstall.queue.title": "卸载队列",
        "uninstall.queue.summary": "%d 个进行中 · %d 个排队 · %d 条最近记录",
        "uninstall.queue.dismiss": "清除已完成",
        "uninstall.queue.cancel": "取消排队",
        "uninstall.queue.waiting": "排队中 · 第 %d 位",
        "uninstall.queue.queued": "排队中",
        "uninstall.queue.preparing": "准备中",
        "uninstall.queue.running": "清理中…",
        "uninstall.queue.succeeded": "已完成",
        "uninstall.queue.failed": "失败 · 可重试",
        "uninstall.queue.retry": "重试卸载",
        "uninstall.queue.confirm": "确认后会加入队列，按顺序在后台处理。排队期间可以取消；需要管理员权限时，macOS 会单独请求授权。",
        "uninstall.queue.add": "加入卸载队列",
        "uninstall.queue.permissionLost": "磁盘访问授权已失效，请重新授权后再添加此应用。",
    ]

    static let zhHant: [String: String] = [
        "uninstall.loading": "正在準備應用程式列表…",
        "uninstall.queue.title": "解除安裝佇列",
        "uninstall.queue.summary": "%d 個進行中 · %d 個排隊 · %d 筆最近記錄",
        "uninstall.queue.dismiss": "清除已完成",
        "uninstall.queue.cancel": "取消排隊",
        "uninstall.queue.waiting": "排隊中 · 第 %d 位",
        "uninstall.queue.queued": "排隊中",
        "uninstall.queue.preparing": "準備中",
        "uninstall.queue.running": "清理中…",
        "uninstall.queue.succeeded": "已完成",
        "uninstall.queue.failed": "失敗 · 可重試",
        "uninstall.queue.retry": "重試解除安裝",
        "uninstall.queue.confirm": "確認後會加入佇列，依序在背景處理。排隊期間可以取消；需要管理員權限時，macOS 會另外要求授權。",
        "uninstall.queue.add": "加入解除安裝佇列",
        "uninstall.queue.permissionLost": "磁碟存取授權已失效，請重新授權後再加入此應用程式。",
    ]

    static let ja: [String: String] = [
        "uninstall.loading": "アプリ一覧を準備中…",
        "uninstall.queue.title": "アンインストール待ち行列",
        "uninstall.queue.summary": "%d 件実行中 · %d 件待機中 · 最近 %d 件",
        "uninstall.queue.dismiss": "完了項目を閉じる",
        "uninstall.queue.cancel": "待機を取り消す",
        "uninstall.queue.waiting": "待機中 · #%d",
        "uninstall.queue.queued": "待機中",
        "uninstall.queue.preparing": "準備中",
        "uninstall.queue.running": "削除中…",
        "uninstall.queue.succeeded": "完了",
        "uninstall.queue.failed": "失敗 · 再試行できます",
        "uninstall.queue.retry": "再試行",
        "uninstall.queue.confirm": "確認後にキューへ追加し、順番にバックグラウンドで処理します。待機中は取り消せます。管理者権限が必要な場合は macOS が別途確認します。",
        "uninstall.queue.add": "アンインストール待ち行列に追加",
        "uninstall.queue.permissionLost": "ディスクアクセスの許可が失効しました。もう一度許可してからアプリを追加してください。",
    ]

    static let ko: [String: String] = [
        "uninstall.loading": "앱 목록 준비 중…",
        "uninstall.queue.title": "앱 삭제 대기열",
        "uninstall.queue.summary": "%d개 실행 중 · %d개 대기 · 최근 %d개",
        "uninstall.queue.dismiss": "완료 항목 닫기",
        "uninstall.queue.cancel": "대기 취소",
        "uninstall.queue.waiting": "대기 중 · #%d",
        "uninstall.queue.queued": "대기 중",
        "uninstall.queue.preparing": "준비 중",
        "uninstall.queue.running": "제거 중…",
        "uninstall.queue.succeeded": "완료",
        "uninstall.queue.failed": "실패 · 다시 시도",
        "uninstall.queue.retry": "다시 시도",
        "uninstall.queue.confirm": "확인하면 대기열에 추가되어 순서대로 백그라운드에서 처리됩니다. 대기 중에는 취소할 수 있으며, 관리자 권한이 필요하면 macOS가 별도로 요청합니다.",
        "uninstall.queue.add": "삭제 대기열에 추가",
        "uninstall.queue.permissionLost": "디스크 접근 권한이 만료되었습니다. 다시 허용한 후 앱을 추가하세요.",
    ]

    static let de: [String: String] = [
        "uninstall.loading": "App-Liste wird vorbereitet…",
        "uninstall.queue.title": "Deinstallationswarteschlange",
        "uninstall.queue.summary": "%d aktiv · %d warten · %d zuletzt",
        "uninstall.queue.dismiss": "Erledigte schließen",
        "uninstall.queue.cancel": "Warten abbrechen",
        "uninstall.queue.waiting": "Wartet · Nr. %d",
        "uninstall.queue.queued": "Wartet",
        "uninstall.queue.preparing": "Wird vorbereitet",
        "uninstall.queue.running": "Wird entfernt…",
        "uninstall.queue.succeeded": "Abgeschlossen",
        "uninstall.queue.failed": "Fehlgeschlagen · erneut versuchen",
        "uninstall.queue.retry": "Erneut versuchen",
        "uninstall.queue.confirm": "Nach der Bestätigung wird der Auftrag in die Warteschlange aufgenommen und im Hintergrund der Reihe nach ausgeführt. Wartende Aufträge können abgebrochen werden; macOS fragt Admin-Rechte bei Bedarf separat ab.",
        "uninstall.queue.add": "Zur Deinstallationswarteschlange",
        "uninstall.queue.permissionLost": "Die Festplattenzugriffsfreigabe ist nicht mehr gültig. Erlaube den Zugriff erneut, bevor du diese App hinzufügst.",
    ]

    static let fr: [String: String] = [
        "uninstall.loading": "Préparation de la liste des apps…",
        "uninstall.queue.title": "File de désinstallation",
        "uninstall.queue.summary": "%d actif(s) · %d en attente · %d récent(s)",
        "uninstall.queue.dismiss": "Fermer les éléments terminés",
        "uninstall.queue.cancel": "Annuler l’attente",
        "uninstall.queue.waiting": "En attente · n° %d",
        "uninstall.queue.queued": "En attente",
        "uninstall.queue.preparing": "Préparation",
        "uninstall.queue.running": "Suppression…",
        "uninstall.queue.succeeded": "Terminé",
        "uninstall.queue.failed": "Échec · réessayer",
        "uninstall.queue.retry": "Réessayer",
        "uninstall.queue.confirm": "Après confirmation, la demande rejoint la file et est traitée dans l’ordre en arrière-plan. Vous pouvez annuler une demande en attente ; macOS demandera séparément les droits administrateur si nécessaire.",
        "uninstall.queue.add": "Ajouter à la file de désinstallation",
        "uninstall.queue.permissionLost": "L’autorisation d’accès au disque n’est plus valide. Autorisez-la à nouveau avant d’ajouter cette app.",
    ]

    static let es: [String: String] = [
        "uninstall.loading": "Preparando la lista de apps…",
        "uninstall.queue.title": "Cola de desinstalación",
        "uninstall.queue.summary": "%d activa(s) · %d en cola · %d recientes",
        "uninstall.queue.dismiss": "Cerrar completadas",
        "uninstall.queue.cancel": "Cancelar espera",
        "uninstall.queue.waiting": "En cola · n.º %d",
        "uninstall.queue.queued": "En cola",
        "uninstall.queue.preparing": "Preparando",
        "uninstall.queue.running": "Eliminando…",
        "uninstall.queue.succeeded": "Completado",
        "uninstall.queue.failed": "Error · reintentar",
        "uninstall.queue.retry": "Reintentar",
        "uninstall.queue.confirm": "Tras confirmar, la solicitud entra en la cola y se procesa en orden en segundo plano. Puedes cancelar las solicitudes en espera; macOS pedirá autorización de administrador por separado si hace falta.",
        "uninstall.queue.add": "Añadir a la cola de desinstalación",
        "uninstall.queue.permissionLost": "La autorización de acceso al disco ya no está disponible. Autorízala de nuevo antes de añadir esta app.",
    ]

    static let pt: [String: String] = [
        "uninstall.loading": "Preparando a lista de apps…",
        "uninstall.queue.title": "Fila de desinstalação",
        "uninstall.queue.summary": "%d ativa(s) · %d na fila · %d recentes",
        "uninstall.queue.dismiss": "Fechar concluídas",
        "uninstall.queue.cancel": "Cancelar espera",
        "uninstall.queue.waiting": "Na fila · nº %d",
        "uninstall.queue.queued": "Na fila",
        "uninstall.queue.preparing": "Preparando",
        "uninstall.queue.running": "Removendo…",
        "uninstall.queue.succeeded": "Concluído",
        "uninstall.queue.failed": "Falha · tentar novamente",
        "uninstall.queue.retry": "Tentar novamente",
        "uninstall.queue.confirm": "Após a confirmação, o pedido entra na fila e é processado em ordem em segundo plano. Você pode cancelar pedidos em espera; o macOS solicitará autorização de administrador separadamente quando necessário.",
        "uninstall.queue.add": "Adicionar à fila de desinstalação",
        "uninstall.queue.permissionLost": "A autorização de acesso ao disco não está mais disponível. Autorize novamente antes de adicionar este app.",
    ]

    static let it: [String: String] = [
        "uninstall.loading": "Preparazione dell’elenco delle app…",
        "uninstall.queue.title": "Coda di disinstallazione",
        "uninstall.queue.summary": "%d attivo/i · %d in coda · %d recenti",
        "uninstall.queue.dismiss": "Chiudi completati",
        "uninstall.queue.cancel": "Annulla attesa",
        "uninstall.queue.waiting": "In coda · n. %d",
        "uninstall.queue.queued": "In coda",
        "uninstall.queue.preparing": "Preparazione",
        "uninstall.queue.running": "Rimozione…",
        "uninstall.queue.succeeded": "Completato",
        "uninstall.queue.failed": "Operazione non riuscita · riprova",
        "uninstall.queue.retry": "Riprova",
        "uninstall.queue.confirm": "Dopo la conferma, la richiesta viene aggiunta alla coda ed eseguita in ordine in background. Le richieste in attesa possono essere annullate; macOS chiederà separatamente l’autorizzazione di amministratore se necessaria.",
        "uninstall.queue.add": "Aggiungi alla coda di disinstallazione",
        "uninstall.queue.permissionLost": "L’autorizzazione per l’accesso al disco non è più disponibile. Autorizza di nuovo prima di aggiungere questa app.",
    ]

    static let ru: [String: String] = [
        "uninstall.loading": "Подготовка списка приложений…",
        "uninstall.queue.title": "Очередь удаления",
        "uninstall.queue.summary": "%d выполняется · %d в очереди · %d последних",
        "uninstall.queue.dismiss": "Скрыть завершённые",
        "uninstall.queue.cancel": "Отменить ожидание",
        "uninstall.queue.waiting": "В очереди · № %d",
        "uninstall.queue.queued": "В очереди",
        "uninstall.queue.preparing": "Подготовка",
        "uninstall.queue.running": "Удаление…",
        "uninstall.queue.succeeded": "Завершено",
        "uninstall.queue.failed": "Ошибка · повторить",
        "uninstall.queue.retry": "Повторить",
        "uninstall.queue.confirm": "После подтверждения запрос попадёт в очередь и будет обработан по порядку в фоне. Ожидающие запросы можно отменить; при необходимости macOS отдельно запросит права администратора.",
        "uninstall.queue.add": "Добавить в очередь удаления",
        "uninstall.queue.permissionLost": "Разрешение на доступ к диску больше недоступно. Разрешите доступ снова перед добавлением приложения.",
    ]

    static let tr: [String: String] = [
        "uninstall.loading": "Uygulama listesi hazırlanıyor…",
        "uninstall.queue.title": "Kaldırma kuyruğu",
        "uninstall.queue.summary": "%d etkin · %d sırada · %d son kayıt",
        "uninstall.queue.dismiss": "Tamamlananları kapat",
        "uninstall.queue.cancel": "Beklemeyi iptal et",
        "uninstall.queue.waiting": "Sırada · #%d",
        "uninstall.queue.queued": "Sırada",
        "uninstall.queue.preparing": "Hazırlanıyor",
        "uninstall.queue.running": "Kaldırılıyor…",
        "uninstall.queue.succeeded": "Tamamlandı",
        "uninstall.queue.failed": "Başarısız · yeniden dene",
        "uninstall.queue.retry": "Yeniden dene",
        "uninstall.queue.confirm": "Onaydan sonra istek kuyruğa eklenir ve arka planda sırayla işlenir. Bekleyen istekleri iptal edebilirsiniz; gerekirse macOS yönetici yetkisini ayrıca ister.",
        "uninstall.queue.add": "Kaldırma kuyruğuna ekle",
        "uninstall.queue.permissionLost": "Disk erişimi yetkisi artık kullanılamıyor. Bu uygulamayı eklemeden önce yeniden izin verin.",
    ]

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
}
