#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/forgesweep-tests.XXXXXX")"
RUNTIME_DIR="$TEST_ROOT/runtime"
PASSED=0
AUTO_CLEANUP_FIXTURE=""

cleanup() {
    rm -rf "$TEST_ROOT"
    case "$AUTO_CLEANUP_FIXTURE" in
        "$ROOT_DIR"/.auto-cleanup-planner-tests.*)
            rm -rf -- "$AUTO_CLEANUP_FIXTURE"
            ;;
    esac
}
trap cleanup EXIT

pass() {
    PASSED=$((PASSED + 1))
    printf 'ok %d - %s\n' "$PASSED" "$1"
}

fail() {
    printf 'not ok - %s\n' "$1" >&2
    exit 1
}

assert_status() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    [[ "$actual" -eq "$expected" ]] || fail "$message (expected $expected, got $actual)"
}

stage_bridge_runtime() {
    [[ -d "$MOLE_SRC/lib/core" ]] || fail "Mole library not found at $MOLE_SRC/lib"
    bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$MOLE_SRC" "$RUNTIME_DIR"
}

test_shell_syntax() {
    local file
    for file in "$ROOT_DIR"/bridge/*.sh "$ROOT_DIR"/script/*.sh; do
        bash -n "$file" || fail "shell syntax: ${file#"$ROOT_DIR/"}"
    done
    pass "shell syntax"
}

test_native_core_ownership_contract() {
    local app_state="$ROOT_DIR/SimpleMole/AppState.swift"
    local native_core="$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    local system_metrics="$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift"
    local build_script="$ROOT_DIR/script/build.sh"

    /usr/bin/grep -Fq 'NativeCore.shared.scanCleanup(progress:' "$app_state" || \
        fail "clean does not use NativeCore progress scanner"
    /usr/bin/grep -Fq 'NativeCore.shared.applyCleanup' "$app_state" || \
        fail "clean apply does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.scanInstalledApps' "$app_state" || \
        fail "uninstall inventory does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.uninstallPlan' "$app_state" || \
        fail "uninstall preview does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.applyUninstall' "$app_state" || \
        fail "uninstall apply does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.scanAnalyze' "$app_state" || \
        fail "analyze does not use NativeCore"
    /usr/bin/grep -Fq 'NativeCore.shared.runOptimize' "$app_state" || \
        fail "optimize does not use NativeCore"
    /usr/bin/grep -Fq 'metrics = SystemMetrics.sample()' "$app_state" || \
        fail "status sampling does not use SystemMetrics"

    if /usr/bin/grep -Eq 'MoleEngine|vendor/mole|bin/(clean|uninstall|analyze|optimize|status)\.sh|analyze-go|status-go' \
        "$native_core" "$system_metrics"; then
        fail "native core still references the Mole router, bridges, or Go helpers"
    fi
    if /usr/bin/grep -Eq 'FORGESWEEP_LEGACY_ORPHAN_BRIDGE|app_orphan_scan\.sh|app_uninstall_(list|preview|apply)\.sh' \
        "$app_state"; then
        fail "AppState still exposes a legacy Mole clean or uninstall route"
    fi
    if /usr/bin/grep -Eq 'cp .*bin/(mole|clean\.sh|uninstall\.sh|analyze-go|status-go)' \
        "$build_script"; then
        fail "build still packages a Mole core entrypoint"
    fi

    pass "native clean, uninstall, analyze, optimize and status ownership"
}

test_timeout_fallback() {
    bash "$ROOT_DIR/script/TimeoutFallbackTests.sh" || \
        fail "Perl timeout fallback performance and safety"
    pass "Perl timeout fallback performance and safety"
}

test_plists() {
    local found=0
    local plist
    while IFS= read -r -d '' plist; do
        found=1
        plutil -lint "$plist" >/dev/null || fail "plist: ${plist#"$ROOT_DIR/"}"
    done < <(find "$ROOT_DIR/SimpleMole" -type f -name '*.plist' -print0)
    [[ "$found" -eq 1 ]] || fail "no source plist found"
    pass "plist validation"
}

test_brand_contract() {
    local app_delegate="$ROOT_DIR/SimpleMole/AppDelegate.swift"
    local info_plist="$ROOT_DIR/SimpleMole/Support/Info.plist"

    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "$info_plist")" == "ForgeSweep" ]] || \
        fail "bundle name is not ForgeSweep"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$info_plist")" == "ForgeSweep" ]] || \
        fail "bundle display name is not ForgeSweep"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")" == "com.forgesweep.app" ]] || \
        fail "bundle identifier still uses the previous brand"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$info_plist")" == "ForgeSweep" ]] || \
        fail "bundle executable is not ForgeSweep"
    /usr/bin/grep -Fq 'appMenuItem.title = "ForgeSweep"' "$app_delegate" || \
        fail "system app menu does not use the ForgeSweep name"
    if /usr/bin/grep -Fq 'appMenuItem.image' "$app_delegate"; then
        fail "system app menu still displays a brand icon"
    fi

    pass "ForgeSweep brand and icon-free system menu contract"
}

test_tab_motion_contract() {
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local main_window="$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    local app_state="$ROOT_DIR/SimpleMole/AppState.swift"

    /usr/bin/grep -Fq 'withAnimation(selectionAnimation)' "$components" || \
        fail "tab glass selection is not driven by an explicit animation transaction"
    /usr/bin/grep -Fq '.glassEffectID(index, in: selectionNamespace)' "$components" || \
        fail "tab glass effects do not have per-item identities"
    /usr/bin/grep -Fq 'interpolate(from, to, amount)' "$components" || \
        fail "Reduce Transparency tab motion skips progress interpolation"
    /usr/bin/grep -Fq 'withAnimation(animation)' "$main_window" || \
        fail "tab page replacement is not driven by an explicit animation transaction"
    /usr/bin/grep -Fq 'self.selectedTab == tab' "$app_state" || \
        fail "tab loading work is not deferred and stale-selection guarded"

    pass "tab glass and page motion contract"
}

test_control_motion_contract() {
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local analyze="$ROOT_DIR/SimpleMole/Views/AnalyzeTabView.swift"
    local cleanup="$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"
    local dev_env="$ROOT_DIR/SimpleMole/Views/DevEnvTabView.swift"
    local uninstall="$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"

    /usr/bin/grep -Fq 'static let press = Animation' "$components" || \
        fail "ordinary controls do not share a short press animation"
    /usr/bin/grep -Fq 'struct MoleSelectableRowButtonStyle: ButtonStyle' "$components" || \
        fail "selectable detail rows do not share a button style"
    /usr/bin/grep -Fq 'struct MoleIconButtonStyle: ButtonStyle' "$components" || \
        fail "detail disclosure actions do not share an icon button style"
    /usr/bin/grep -Fq 'struct MolePlainButtonStyle: ButtonStyle' "$components" || \
        fail "surface-free buttons have no shared press feedback"
    /usr/bin/grep -Fq '.buttonStyle(MoleSelectableRowButtonStyle' "$analyze" || \
        fail "disk analysis rows bypass the selectable-row interaction"
    /usr/bin/grep -Fq '.buttonStyle(MoleSelectableRowButtonStyle' "$dev_env" || \
        fail "development environment rows bypass the selectable-row interaction"
    /usr/bin/grep -Fq '.buttonStyle(MolePlainButtonStyle' "$cleanup" || \
        fail "cleanup detail titles still bypass Button semantics"
    /usr/bin/grep -Fq '.buttonStyle(MoleIconButtonStyle' "$uninstall" || \
        fail "uninstall disclosure action lacks press feedback"
    if /usr/bin/grep -Fq 'onTapGesture { state.toggleDupSelection(member) }' "$analyze"; then
        fail "duplicate rows still register overlapping selection gestures"
    fi

    pass "ordinary buttons and selectable-row motion contract"
}

test_header_layout_contract() {
    local main_window="$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    local components="$ROOT_DIR/SimpleMole/Views/Components.swift"
    local icon="$ROOT_DIR/SimpleMole/Support/HeaderBrandIcon.png"

    /usr/bin/grep -Fq 'HeaderBrandIconView(size: 20,' "$main_window" || \
        fail "title-bar brand icon is not using the compact optical size"
    /usr/bin/grep -Fq 'isSearching: state.isScanning' "$main_window" || \
        fail "title-bar mascot does not react to cleanup scanning"
    /usr/bin/grep -Fq '.frame(height: 28)' "$main_window" || \
        fail "title-bar controls do not have a stable vertical alignment slot"
    /usr/bin/grep -Fq '.padding(.top, 2)' "$main_window" || \
        fail "title-bar controls can touch the top window edge"
    /usr/bin/grep -Fq '.offset(y: 4)' "$main_window" || \
        fail "title-bar glass actions lack optical top-edge correction"
    /usr/bin/grep -Fq '.frame(width: 32, height: 24)' "$components" || \
        fail "title-bar action buttons are oversized for the title region"
    /usr/bin/grep -Fq 'Canvas { context, size in' "$components" || \
        fail "title-bar mascot is not rendered as an animatable vector"
    /usr/bin/grep -Fq 'MascotAnimationContext(reduceMotion: reduceMotion' "$components" || \
        fail "title-bar mascot animation ignores reduced-motion lifecycle"
    /usr/bin/grep -Fq 'MoleLogoMark(winkOpen: winkOpen, gazeX: gazeX, gazeY: gazeY)' "$components" || \
        fail "title-bar mascot does not use the single-eye wink state"
    /usr/bin/grep -Fq '.onContinuousHover { phase in' "$components" || \
        fail "title-bar mascot eyes do not follow pointer movement"
    /usr/bin/grep -Fq 'SearchMagnifier(size: size' "$components" || \
        fail "title-bar mascot has no scanning magnifier state"
    /usr/bin/grep -Fq 'ConfettiBurst(progress: confettiProgress)' "$components" || \
        fail "title-bar mascot has no scan-completion celebration"
    /usr/bin/grep -Fq 'private func performSpin() async -> Bool' "$components" || \
        fail "title-bar mascot idle animation has no low-frequency spin"
    /usr/bin/grep -Fq 'Bundle.main.url(forResource: "HeaderBrandIcon"' "$components" || \
        fail "title-bar mascot does not reuse the rounded brand artwork"
    if /usr/bin/grep -Fq 'peekAmount' "$components"; then
        fail "title-bar mascot still contains the removed peek animation"
    fi
    /usr/bin/grep -Fq 'struct MoleSwitchToggleStyle: ToggleStyle' "$components" || \
        fail "switch controls do not share the animated brand interaction"
    /usr/bin/grep -Fq 'static var molePanelReveal' "$components" || \
        fail "expandable panels do not share the reveal transition"
    [[ -f "$icon" ]] || fail "transparent title-bar brand icon is missing"

    pass "title-bar icon and control alignment contract"
}

test_process_icon_contract() {
    local component="$ROOT_DIR/SimpleMole/Views/ProcessAppIcon.swift"
    local processes="$ROOT_DIR/SimpleMole/Views/ProcessesTabView.swift"
    local quick_panel="$ROOT_DIR/SimpleMole/Views/QuickPanelView.swift"

    [[ -f "$component" ]] || fail "shared process app icon component is missing"
    /usr/bin/grep -Fq 'NSRunningApplication(processIdentifier: row.pid)' "$component" || \
        fail "process icons are not resolved from the running application"
    /usr/bin/grep -Fq '.task(id: row.signalToken)' "$component" || \
        fail "process icons are not refreshed across PID reuse"
    /usr/bin/grep -Fq 'RuntimeStore.nativeStartIdentity(for: application) == row.startIdentity' "$component" || \
        fail "native process icons are not bound to the application launch identity"
    /usr/bin/grep -Fq 'ProcessAppIcon(row: row,' "$processes" || \
        fail "process cleanup does not render real application icons"
    /usr/bin/grep -Fq 'ProcessAppIcon(row: row,' "$quick_panel" || \
        fail "quick panel does not reuse the process icon component"
    if /usr/bin/grep -Fq 'image.size =' "$component" "$quick_panel"; then
        fail "process icon rendering mutates shared NSImage dimensions"
    fi

    pass "process application icon identity and fallback contract"
}

test_productivity_feature_contract() {
    local main_window="$ROOT_DIR/SimpleMole/Views/MainWindowView.swift"
    local app_state="$ROOT_DIR/SimpleMole/AppState.swift"
    local cleanup_view="$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift"
    local app_delegate="$ROOT_DIR/SimpleMole/AppDelegate.swift"
    local screenshot_service="$ROOT_DIR/SimpleMole/Services/ScreenShotService.swift"
    local screenshot_editor="$ROOT_DIR/SimpleMole/Views/ScreenshotEditorView.swift"
    local clipboard="$ROOT_DIR/SimpleMole/Services/ClipboardHistoryManager.swift"
    local clipboard_view="$ROOT_DIR/SimpleMole/Views/ClipboardHistoryTabView.swift"
    local permission_center="$ROOT_DIR/SimpleMole/Services/PermissionCenter.swift"
    local authorization_coordinator="$ROOT_DIR/SimpleMole/Services/AuthorizationCoordinator.swift"
    local permission_view="$ROOT_DIR/SimpleMole/Views/PermissionCenterView.swift"
    local mole_engine="$ROOT_DIR/SimpleMole/Services/MoleEngine.swift"
    local analyze_view="$ROOT_DIR/SimpleMole/Views/AnalyzeTabView.swift"
    local quick_panel="$ROOT_DIR/SimpleMole/Views/QuickPanelView.swift"
    local models="$ROOT_DIR/SimpleMole/Models.swift"
    local system_metrics="$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift"

    /usr/bin/grep -Fq 'if state.showSettingsSheet {' "$main_window" || \
        fail "settings button state is not connected to a presented panel"
    /usr/bin/grep -Fq 'state.requestScanAccess(.quickOptimize)' \
        "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift" || \
        fail "main cleanup page does not expose Quick Clean"
    /usr/bin/grep -Fq 'requestScanAccess(.deepCleanupScan)' "$cleanup_view" || \
        fail "cleanup has no explicit deep scan entry"
    if /usr/bin/grep -Fq '"bin/app_dev_scan.sh"' "$app_state"; then
        fail "unified cleanup still launches a duplicate developer-cache scan"
    fi
    /usr/bin/grep -Fq 'cleanupOrphanNames(home: home, control: control)' \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" || fail "cleanup lost orphan correlation"
    /usr/bin/grep -Fq 'state.requestQuickOptimizeFromQuickPanel()' "$quick_panel" || \
        fail "quick panel does not use the feedback-aware Quick Clean entry point"
    /usr/bin/grep -Fq 'func requestQuickOptimizeFromQuickPanel()' "$app_state" || \
        fail "quick panel Quick Clean has no busy feedback path"
    if /usr/bin/grep -Fq '.disabled(state.isBusy)' "$quick_panel"; then
        fail "quick panel Quick Clean is still silently disabled by unrelated work"
    fi
    if /usr/bin/grep -Fq 'clipboardManager' "$quick_panel"; then
        fail "quick panel still renders clipboard history"
    fi
    /usr/bin/grep -Fq 'ByteFormat.memoryShort(state.metrics.memoryTotalBytes)' "$quick_panel" || \
        fail "quick panel physical memory still uses decimal disk formatting"
    /usr/bin/grep -Fq 'static func memoryShort(_ bytes: UInt64)' "$models" || \
        fail "memory has no hardware-capacity formatter"
    /usr/bin/grep -Fq 'internalPages: UInt64(info.internal_page_count)' "$system_metrics" || \
        fail "memory usage still counts inactive file cache as occupied memory"
    /usr/bin/grep -Fq 'min(rawBytes, totalBytes)' "$system_metrics" || \
        fail "memory usage is not capped at physical memory"
    bash "$ROOT_DIR/script/test_cleanup_manual_trigger.sh" || \
        fail "cleanup manual-trigger lifecycle contract"
    /usr/bin/grep -Fq 'ForEach(category.pathsByDescendingSize, id: \.self)' \
        "$ROOT_DIR/SimpleMole/Views/CleanupTabView.swift" || \
        fail "expanded cleanup children are not selectable and sorted by size"
    /usr/bin/grep -Fq 'categories.compactMap(\.selectedSubset)' "$app_state" || \
        fail "cleanup apply still submits whole categories instead of selected children"
    /usr/bin/grep -Fq '.sorted(by: CleanupCategory.sizeDescending)' "$app_state" || \
        fail "cleanup categories are not sorted by descending size"
    /usr/bin/grep -Fq 'let eligibleCount = eligible.reduce' "$app_state" || \
        fail "cleanup progress does not count the immutable eligible plan"
    /usr/bin/grep -Fq 'statusText = l10n.tf("status.processing", eligibleCount)' "$app_state" || \
        fail "cleanup progress still reports the pre-policy request count"
    /usr/bin/grep -Fq 'selectionEnabled: state.cleanupScanComplete' "$cleanup_view" || \
        fail "cleanup category selection is not routed through a shared applying-state gate"
    /usr/bin/grep -Fq '&& !state.isApplying)' "$cleanup_view" || \
        fail "cleanup category and child selection remain mutable during apply"
    /usr/bin/grep -Fq '.disabled(!state.cleanupScanComplete || state.isApplying)' "$cleanup_view" || \
        fail "cleanup group selection remains mutable during apply"
    /usr/bin/grep -Fq '.transition(.moleFloatingPanel)' "$main_window" || \
        fail "settings and header panels do not share an animated transition"
    /usr/bin/grep -Fq 'headerFloatingPanel' "$main_window" || \
        fail "header menus still bypass the animated in-window panel"
    /usr/bin/grep -Fq 'state.visiblePages.map' "$main_window" || \
        fail "visible page settings and tab labels use different data sources"
    /usr/bin/grep -Fq '!self.isCapturingScreenshot' "$app_delegate" || \
        fail "screenshot hotkey can start overlapping capture processes"
    /usr/bin/grep -Fq 'self.editorWindow?.isVisible != true' "$app_delegate" || \
        fail "closed screenshot editor still blocks future captures"
    /usr/bin/grep -Fq 'com.forgesweep.screenshot.' "$screenshot_service" || \
        fail "screenshot capture does not use a private temporary directory"
    /usr/bin/grep -Fq 'removeItem(at: directory)' "$screenshot_service" || \
        fail "screenshot temporary directory is not cleaned"
    /usr/bin/grep -Fq 'private var exportSize' "$screenshot_editor" || \
        fail "screenshot export still renders only at preview size"
    /usr/bin/grep -Fq 'MosaicCache.shared.clear()' "$app_delegate" || \
        fail "closing the screenshot editor retains the source image cache"
    /usr/bin/grep -Fq 'private let maxTotalBytes' "$clipboard" || \
        fail "clipboard image history has no total memory bound"
    /usr/bin/grep -Fq 'org.nspasteboard.ConcealedType' "$clipboard" || \
        fail "clipboard history records concealed password-manager content"
    /usr/bin/grep -Fq 'case text, url, file, image' "$clipboard" || \
        fail "clipboard history does not classify text, URL, file and image entries"
    /usr/bin/grep -Fq 'SMClipboardHistoryCapacity' "$clipboard" || \
        fail "clipboard history capacity is not persisted"
    /usr/bin/grep -Fq 'clipboard-history.plist' "$clipboard" || \
        fail "clipboard entries are not persisted across app launches"
    /usr/bin/grep -Fq 'PropertyListEncoder()' "$clipboard" || \
        fail "clipboard history has no on-disk archive"
    /usr/bin/grep -Fq 'entries.lastIndex(where: { !$0.isPinned })' "$clipboard" || \
        fail "clipboard capacity cleanup can remove pinned entries"
    /usr/bin/grep -Fq 'case .clipboard: ClipboardHistoryTabView' "$main_window" || \
        fail "enabled clipboard history is not rendered as a standalone tab"
    /usr/bin/grep -Fq 'if clipboardHistoryEnabled { pages.append(.clipboard) }' "$app_state" || \
        fail "clipboard tab visibility is not controlled by the feature switch"
    /usr/bin/grep -Fq 'enum ProtectedOperation' "$authorization_coordinator" || \
        fail "protected scans do not use a persistent typed operation"
    /usr/bin/grep -Fq 'final class AuthorizationCoordinator' "$authorization_coordinator" || \
        fail "scan authorization has no central coordinator"
    /usr/bin/grep -Fq 'func requestScanAccess(_ operation: ProtectedOperation)' "$app_state" || \
        fail "protected scan entry points do not share the typed permission gate"
    /usr/bin/grep -Fq 'authorizationCoordinator.storePending(operation)' "$app_state" || \
        fail "denied scan intent is not persisted before opening the permission center"
    /usr/bin/grep -Fq 'func refreshAuthorizationAndResume()' "$app_state" || \
        fail "authorized scans cannot resume after returning from System Settings"
    /usr/bin/grep -Fq 'permissions.status.required' "$permission_view" || \
        fail "Full Disk Access is not presented as required for protected scans"
    /usr/bin/grep -Fq '.disabled(isWaitingForDiskAccess)' "$permission_view" || \
        fail "permission continue can execute a pending scan before authorization"
    if /usr/bin/grep -Fq 'SMScanAccessAsked' "$app_state"; then
        fail "scan access still treats a dismissed prompt as valid authorization"
    fi
    /usr/bin/grep -Fq 'extraEnvironment: [String: String] = [:]' "$mole_engine" || \
        fail "bridge runner cannot receive a scoped scan capability"
    /usr/bin/grep -Fq 'FORGESWEEP_FULL_DISK_AUTHORIZED' "$app_state" || \
        fail "authorized child processes do not receive the scoped scan capability"
    /usr/bin/grep -Fq 'guard permissionCenter.fullDiskAccessGranted else { return [:] }' \
        "$app_state" || fail "scan capability can be minted before authorization"
    /usr/bin/grep -Fq 'scanEnvironment["FORGESWEEP_FULL_DISK_AUTHORIZED"] == "1"' \
        "$app_state" || fail "protected scan entry points do not fail closed"
    /usr/bin/grep -Fq 'extraEnvironment: scanEnvironment' "$app_state" || \
        fail "protected scan calls do not pass the verified capability environment"
    /usr/bin/grep -Fq 'CGPreflightScreenCaptureAccess()' "$permission_center" || \
        fail "screen recording permission has no public preflight check"
    /usr/bin/grep -Fq 'CGRequestScreenCaptureAccess()' "$permission_center" || \
        fail "screen recording permission is not requested through Core Graphics"
    /usr/bin/grep -Fq 'fullDiskAccessGranted = Self.canOpenProtectedScanLocation()' "$permission_center" || \
        fail "full disk access is not refreshed from actual protected data access"
    /usr/bin/grep -Fq 'O_RDONLY | O_CLOEXEC' "$permission_center" || \
        fail "full disk access detection does not probe a protected scan location"
    /usr/bin/grep -Fq 'com.apple.TCC/TCC.db' "$permission_center" || \
        fail "full disk access detection is not using the non-interactive TCC probe"
    if /usr/bin/grep -Fq '/Library/Containers/' "$permission_center"; then
        fail "permission refresh still probes another App container and can trigger a system prompt"
    fi
    /usr/bin/grep -Fq 'com.apple.settings.PrivacySecurity.extension' "$permission_center" || \
        fail "permission settings still use only the legacy pre-macOS 13 deep link"
    /usr/bin/grep -Fq 'NSItemProvider(object: Bundle.main.bundleURL as NSURL)' "$permission_view" || \
        fail "the app cannot be dragged into a macOS permission list"
    /usr/bin/grep -Fq 'dragProvider: permissions.fullDiskAccessGranted ? nil : applicationDragProvider' \
        "$permission_view" || fail "Full Disk Access does not own its conditional drag source"
    /usr/bin/grep -Fq 'ConditionalDragModifier(provider: dragProvider' "$permission_view" || \
        fail "permission cards do not apply drag behavior conditionally"
    if /usr/bin/grep -Fq 'draggableApplication' "$permission_view"; then
        fail "permission center still renders a fixed first draggable app card"
    fi
    if /usr/bin/grep -Eq 'NSApplication\.didBecomeActiveNotification|\.onChange\(of: permissions\.fullDiskAccessGranted\)' \
        "$permission_view"; then
        fail "permission view still resumes protected work from view lifecycle callbacks"
    fi
    if /usr/bin/grep -Fq '.onAppear { permissions.refresh() }' "$permission_view"; then
        fail "permission view still owns authorization refresh lifecycle"
    fi
    /usr/bin/grep -Fq 'Button(l10n.t(hasPendingAction' "$permission_view" || \
        fail "permission view lost the explicit Continue button callback"
    local defaults_line publish_line
    defaults_line=$(/usr/bin/grep -nF 'defaults.set(data, forKey: Self.pendingOperationKey)' \
        "$authorization_coordinator" | /usr/bin/cut -d: -f1)
    publish_line=$(/usr/bin/grep -nF 'pendingOperation = operation' \
        "$authorization_coordinator" | /usr/bin/tail -n 1 | /usr/bin/cut -d: -f1)
    [[ -n "$defaults_line" && -n "$publish_line" && "$defaults_line" -lt "$publish_line" ]] || \
        fail "pending authorization is published before its durable write"
    if /usr/bin/grep -Eq 'homeFolderRow|appManagementRow' "$permission_view"; then
        fail "the initial permission center still shows duplicate disk or on-demand app permissions"
    fi
    /usr/bin/grep -Fq 'PermissionCenterView(state: state)' "$main_window" || \
        fail "the unified permission center is not presented by the main window"
    /usr/bin/grep -Fq 'permissionCenter.screenRecordingGranted' "$app_delegate" || \
        fail "the screenshot hotkey bypasses the unified permission preflight"
    /usr/bin/grep -Fq 'ClipboardFilterButtonStyle(isSelected: filter == item)' "$clipboard_view" || \
        fail "clipboard type filters do not use the themed icon capsules"
    /usr/bin/grep -Fq 'Label(l10n.t("clip.clearUnpinned"), systemImage: "trash.fill")' "$clipboard_view" || \
        fail "clipboard cleanup action is missing its themed icon"
    /usr/bin/grep -Fq '.labelStyle(.titleAndIcon)' "$clipboard_view" || \
        fail "clipboard cleanup action can collapse to icon-only layout"
    /usr/bin/grep -Fq '.fixedSize(horizontal: true, vertical: false)' "$clipboard_view" || \
        fail "clipboard cleanup action does not preserve its localized title width"
    /usr/bin/grep -Fq '.buttonStyle(PrimaryButtonStyle())' "$clipboard_view" || \
        fail "clipboard cleanup action does not use the primary theme style"
    /usr/bin/grep -Fq 'minHeight: 84, maxHeight: 84' "$clipboard_view" || \
        fail "clipboard card preview is not bounded against long-content overflow"
    /usr/bin/grep -Fq '.frame(height: 182, alignment: .topLeading)' "$clipboard_view" || \
        fail "clipboard cards do not keep a stable action-bar layout"
    if /usr/bin/grep -Fq '.textSelection(.enabled)' "$clipboard_view"; then
        fail "selectable clipboard previews can escape their line limit and overlap actions"
    fi
    if /usr/bin/grep -Fq '.pickerStyle(.segmented)' "$clipboard_view"; then
        fail "clipboard type filters still use the system segmented control"
    fi
    if /usr/bin/grep -Fq 'l10n.t("clip.hint")' "$clipboard_view"; then
        fail "clipboard history still renders explanatory copy"
    fi
    /usr/bin/grep -A28 -Fq 'guard permissionCenter.fullDiskAccessGranted else {' "$app_state" || \
        fail "background automation can still trigger protected-folder permission prompts"
    /usr/bin/grep -Fq 'auto.status.diskPermissionRequired' "$app_state" || \
        fail "skipped background scans do not expose their permission state"
    if /usr/bin/sed -n '/NSApplication.didBecomeActiveNotification/,/store(in: &observables)/p' \
        "$app_delegate" | /usr/bin/grep -Fq 'runScheduledAutoCleanup'; then
        fail "every app activation still launches a background filesystem scan"
    fi
    /usr/bin/grep -Fq 'startAnalyze(displayPath: "/", overview: true)' "$app_state" || \
        fail "disk analysis does not start from the native machine-wide overview"
    /usr/bin/grep -Fq '.filter { $0.size > 0 }' "$app_state" || \
        fail "disk cleanup/analysis still displays zero-byte results"
    /usr/bin/grep -Fq '.sorted(by: AnalyzeEntry.analysisOrder)' "$app_state" || \
        fail "disk analysis results are not size ordered"
    /usr/bin/grep -Fq '.prefix(10)' "$app_state" || \
        fail "disk analysis is not limited to Top 10 results"
    /usr/bin/grep -Fq 'CleanupCategory.safeCleanupCandidates(from:' "$app_state" || \
        fail "disk cleanup does not centrally exclude Warning and Protected results"
    /usr/bin/grep -Fq 'environment["SIMPLEMOLE_DELETE_MODE"] = "permanent"' "$app_state" || \
        fail "disk cleanup does not explicitly request permanent deletion"
    /usr/bin/grep -Fq 'confirm.cleanupPermanent.title' "$app_state" || \
        fail "permanent cleanup lacks an irreversible-action confirmation"
    /usr/bin/grep -Fq 'guard entry.canCleanDirectly else { return }' "$app_state" || \
        fail "disk analysis selection does not fail closed"
    /usr/bin/grep -Fq 'state.openAnalyzeEntry(entry)' "$analyze_view" || \
        fail "apps and drill-down rows are not routed by analysis policy"
    /usr/bin/grep -Fq 'Label(l10n.t("analyze.advanced"), systemImage: "ellipsis.circle")' \
        "$analyze_view" || fail "advanced disk scopes are not consolidated"
    if /usr/bin/grep -Fq 'private var quickRoots' "$analyze_view"; then
        fail "disk analysis still exposes confusing directory tabs"
    fi

    pass "settings, screenshot and clipboard lifecycle contracts"
}

test_scan_access_boundary() {
    local home="$TEST_ROOT/scan-access-home"
    local stub_dir="$TEST_ROOT/scan-access-bin"
    local helper="$RUNTIME_DIR/bin/app_scan_access.sh"
    local safe_installer="$home/Public/safe.dmg"
    local protected_installer="$home/Downloads/protected.dmg"
    local protected_image="$home/Pictures/protected.png"
    local safe_ai="$home/.cache/puppeteer/cache.bin"
    local codex_cache="$home/Library/Caches/Codex/Default/Cache"
    local ai_session="$home/.claude/projects/session.jsonl"
    local protected_ai="$home/Library/Application Support/Code/Cache/cache.bin"
    local outside_ai="$TEST_ROOT/scan-access-outside"
    local output="" rc=0

    mkdir -p "$home/Public" "$home/Downloads" "$home/Desktop" "$home/Documents" \
        "$home/Pictures" "$home/.cache/puppeteer" \
        "$home/Library/Application Support/Code/Cache" "$codex_cache" \
        "$(dirname "$ai_session")" "$stub_dir"
    printf 'safe\n' > "$safe_installer"
    printf 'protected\n' > "$protected_installer"
    /bin/dd if=/dev/zero of="$protected_image" bs=1048576 count=3 2>/dev/null
    printf 'safe-ai\n' > "$safe_ai"
    printf 'codex-cache\n' > "$codex_cache/cache.bin"
    printf 'session\n' > "$ai_session"
    printf 'protected-ai\n' > "$protected_ai"

    if env HOME="$home" bash -c 'source "$1"; forgesweep_scan_path_allowed "$HOME/Documents"' \
        _ "$helper"; then
        fail "protected Documents root was accepted without Full Disk Access"
    fi
    env HOME="$home" bash -c 'source "$1"; forgesweep_scan_path_allowed "$HOME/.cache"' \
        _ "$helper" || fail "ordinary dot-cache path was incorrectly permission-gated"
    env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash -c 'source "$1"; forgesweep_scan_path_allowed "$HOME/Documents"' \
        _ "$helper" || fail "authorized protected root was rejected"

    output=$(env HOME="$home" TMPDIR="$TEST_ROOT" \
        bash "$RUNTIME_DIR/bin/app_installer_scan.sh") || \
        fail "permission-filtered installer scan failed"
    [[ "$output" == *"$safe_installer"* ]] || \
        fail "installer scan dropped an unprotected root"
    [[ "$output" != *"$protected_installer"* ]] || \
        fail "installer scan entered Downloads without authorization"
    output=$(env HOME="$home" TMPDIR="$TEST_ROOT" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_installer_scan.sh") || \
        fail "authorized installer scan failed"
    [[ "$output" == *"$protected_installer"* ]] || \
        fail "authorized installer scan did not include Downloads"

    output=$(env HOME="$home" TMPDIR="$TEST_ROOT" \
        bash "$RUNTIME_DIR/bin/app_slim_scan.sh") || \
        fail "permission-filtered slim scan failed"
    [[ -z "$output" ]] || fail "slim scan entered Pictures without authorization"

    printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$MOLE_TEST_IMAGE_PATH"' > "$stub_dir/mdfind"
    chmod +x "$stub_dir/mdfind"
    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" MOLE_TEST_IMAGE_PATH="$protected_image" \
        bash "$RUNTIME_DIR/bin/app_image_scan.sh" "$home" 20 2>&1)
    rc=$?
    set -e
    assert_status 77 "$rc" "whole-Home image scan did not fail closed"
    [[ "$output" == *"Full Disk Access is required"* ]] || \
        fail "whole-Home image scan did not explain its permission failure"
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" MOLE_TEST_IMAGE_PATH="$protected_image" \
        FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_image_scan.sh" "$home" 20) || \
        fail "authorized image inventory failed"
    [[ "$output" == *"$protected_image"* ]] || \
        fail "authorized image inventory did not include protected content"

    output=$(env HOME="$home" bash "$RUNTIME_DIR/bin/app_ai_scan.sh") || \
        fail "permission-filtered AI scan failed"
    [[ "$output" == *"${safe_ai%/*}"* ]] || fail "AI scan dropped an unprotected cache"
    [[ "$output" == *"$codex_cache"* ]] || fail "AI scan dropped the Codex cache"
    [[ "$output" == *"${ai_session%/*}"* ]] || fail "full AI scan dropped session inventory"
    [[ "$output" != *"${protected_ai%/*}"* ]] || \
        fail "AI scan entered another App's Application Support without authorization"
    output=$(env HOME="$home" bash "$RUNTIME_DIR/bin/app_ai_scan.sh" --safe-only) || \
        fail "safe-only AI scan failed"
    [[ "$output" == *"$codex_cache"* ]] || fail "safe-only AI scan dropped the Codex cache"
    [[ "$output" != *"${ai_session%/*}"* ]] || fail "safe-only AI scan exposed session history"
    output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_ai_scan.sh") || fail "authorized AI scan failed"
    [[ "$output" == *"${protected_ai%/*}"* ]] || \
        fail "authorized AI scan did not include Application Support"

    # Electron AI clients and their XDG caches expose only explicit,
    # rebuildable leaves.
    local antigravity_cache="$home/Library/Application Support/Antigravity/Cache"
    local filo_cache="$home/Library/Application Support/Filo/production/Code Cache"
    local claude_cache="$home/Library/Application Support/Claude/sentry"
    local qoder_cache="$home/Library/Application Support/Qoder/CachedData"
    local prisma_cache="$home/.cache/prisma"
    local opencode_cache="$home/.cache/opencode"
    mkdir -p "$antigravity_cache" "$filo_cache" "$claude_cache" \
        "$qoder_cache" "$prisma_cache" "$opencode_cache"
    printf 'antigravity\n' > "$antigravity_cache/item"
    printf 'filo\n' > "$filo_cache/item"
    printf 'claude\n' > "$claude_cache/item"
    printf 'qoder\n' > "$qoder_cache/item"
    printf 'prisma\n' > "$prisma_cache/item"
    printf 'opencode\n' > "$opencode_cache/item"
    output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_ai_scan.sh" --safe-only) || \
        fail "safe-only AI scan failed for Electron/XDG cache leaves"
    for expected in "$antigravity_cache" "$filo_cache" "$claude_cache" \
        "$qoder_cache" "$prisma_cache" "$opencode_cache"; do
        [[ "$output" == *"$expected"* ]] || \
            fail "safe-only AI scan dropped cache leaf: $expected"
    done

    # A catalogued AI root that is redirected through a symlink must be
    # omitted rather than sized through to the outside target.
    mkdir -p "$outside_ai"
    printf 'outside\n' > "$outside_ai/cache.bin"
    rm -rf "$codex_cache"
    ln -s "$outside_ai" "$codex_cache"
    output=$(env HOME="$home" bash "$RUNTIME_DIR/bin/app_ai_scan.sh" --safe-only) || \
        fail "safe-only AI scan failed on a symlinked root"
    [[ "$output" != *"$codex_cache"* && "$output" != *"$outside_ai"* ]] || \
        fail "AI scan followed a symlinked cache root"

    for scanner in app_dup_scan.sh app_env_scan.sh app_installer_scan.sh \
        app_project_activity.sh app_project_radar.sh app_purge_scan.sh \
        app_slim_scan.sh; do
        /usr/bin/grep -Fq 'app_scan_access.sh' "$ROOT_DIR/bridge/$scanner" || \
            fail "$scanner bypasses the shared protected-path boundary"
    done
    /usr/bin/grep -Fq 'du -skP' "$ROOT_DIR/bridge/app_ai_scan.sh" || \
        fail "AI scan does not use physical, non-following size accounting"
    /usr/bin/grep -Fq 'Codex desktop cache' "$ROOT_DIR/bridge/app_ai_scan.sh" || \
        fail "AI scan does not catalog the Codex desktop cache"
    /usr/bin/grep -Fq -- '--safe-only' "$ROOT_DIR/bridge/app_ai_scan.sh" || \
        fail "AI scan does not expose an explicit safe-only mode"
    /usr/bin/grep -Fq 'simplemole_ai_path_is_physical' \
        "$ROOT_DIR/bridge/app_ai_apply.sh" || \
        fail "AI apply lacks the physical-path guard"
    pass "protected scan roots fail closed until Full Disk Access is verified"
}

test_xcode_scan_boundary() {
    local home="$TEST_ROOT/xcode-scan-home"
    local outside="$TEST_ROOT/xcode-scan-outside"
    local derived="$home/Library/Developer/Xcode/DerivedData"
    local module_cache="$home/Library/Caches/com.apple.dt.Xcode"
    local output="" rc=0 identity="" plan="$TEST_ROOT/xcode-scan-plan"

    mkdir -p "$derived/AppBuild" "$module_cache" "$outside"
    printf 'derived-data\n' > "$derived/AppBuild/object.o"
    printf 'outside\n' > "$outside/object.o"

    output=$(env HOME="$home" USER="$(id -un)" LOGNAME="$(id -un)" \
        TMPDIR="$TEST_ROOT" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        bash "$RUNTIME_DIR/bin/app_xcode_scan.sh") || \
        fail "Xcode cache scan failed on a user-owned Developer root"
    [[ "$output" == *"$derived"* ]] || \
        fail "Xcode scan did not emit non-empty DerivedData"
    [[ "$output" != *"$module_cache"* ]] || \
        fail "Xcode scan emitted an empty module-cache row"

    # A symlinked root must be omitted before du can follow it. This protects
    # both the inventory and the later identity-bound delete plan.
    rm -rf -- "$derived"
    ln -s "$outside" "$derived"
    output=$(env HOME="$home" USER="$(id -un)" LOGNAME="$(id -un)" \
        TMPDIR="$TEST_ROOT" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        bash "$RUNTIME_DIR/bin/app_xcode_scan.sh") || \
        fail "Xcode scan failed while ignoring a symlinked root"
    [[ "$output" != *"$derived"* && "$output" != *"$outside"* ]] || \
        fail "Xcode scan followed a symlinked cache root"

    identity=$(/usr/bin/stat -f '%d:%i:%m' "$derived") || \
        fail "Xcode symlink fixture has no filesystem identity"
    printf '%s\0%s\0' "$derived" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$TEST_ROOT/xcode-trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_xcode_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -L "$derived" && -e "$outside/object.o" && \
        "$output" == *"failed=1"* ]] || \
        fail "Xcode apply followed a symlinked cache root: $output"

    /usr/bin/grep -Fq 'app_scan_access.sh' \
        "$ROOT_DIR/bridge/app_xcode_scan.sh" || \
        fail "Xcode scanner bypasses the shared protected-path boundary"
    /usr/bin/grep -Fq 'xcode_scan_path_is_physical' \
        "$ROOT_DIR/bridge/app_xcode_scan.sh" || \
        fail "Xcode scanner lacks a physical-path guard"
    /usr/bin/grep -Fq 'simplemole_xcode_path_is_physical' \
        "$ROOT_DIR/bridge/app_xcode_apply.sh" || \
        fail "Xcode apply lacks a physical-path guard"
    /usr/bin/grep -Fq 'du -skP' "$ROOT_DIR/bridge/app_xcode_scan.sh" || \
        fail "Xcode scanner does not use non-following size accounting"

    pass "Xcode cache scan, zero-byte filtering and symlink boundary"
}

test_developer_scan_boundary() {
    local home="$TEST_ROOT/developer-scan-home"
    local outside="$TEST_ROOT/developer-scan-outside"
    local output=""

    /usr/bin/grep -Fq 'app_scan_access.sh' "$ROOT_DIR/bridge/app_dev_scan.sh" || \
        fail "developer-cache scan bypasses the shared protected-path boundary"
    /usr/bin/grep -Fq 'forgesweep_scan_path_is_physical "$path"' \
        "$ROOT_DIR/bridge/app_dev_scan.sh" || \
        fail "developer-cache scan lacks the physical-path guard"
    /usr/bin/grep -Fq 'forgesweep_scan_path_is_physical "$candidate"' \
        "$ROOT_DIR/bridge/app_dev_apply.sh" || \
        fail "developer-cache apply lacks the physical-path guard"

    mkdir -p "$home/.npm" "$home/.cache/pip" "$home/.config/mole" "$outside"
    printf 'npm-cache\n' > "$home/.npm/index"
    printf 'pip-cache\n' > "$home/.cache/pip/index"
    output=$(env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
        XDG_CACHE_HOME="$home/.cache" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        bash "$RUNTIME_DIR/bin/app_dev_scan.sh") || \
        fail "developer-cache scan failed on ordinary user caches"
    [[ "$output" == *$'\t'$home/.npm* ]] || \
        fail "developer-cache scan dropped an ordinary npm cache: $output"
    [[ "$output" == *$'\t'$home/.cache/pip* ]] || \
        fail "developer-cache scan dropped an ordinary pip cache: $output"

    # A configured cache root redirected through a symlink must be omitted;
    # neither the link nor its outside target may reach the size inventory.
    rm -rf "$home/.npm"
    printf 'outside-cache\n' > "$outside/index"
    ln -s "$outside" "$home/.npm"
    output=$(env HOME="$home" XDG_CONFIG_HOME="$home/.config" \
        XDG_CACHE_HOME="$home/.cache" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        bash "$RUNTIME_DIR/bin/app_dev_scan.sh") || \
        fail "developer-cache scan failed on a redirected cache root"
    [[ "$output" != *"$home/.npm"* && "$output" != *"$outside"* ]] || \
        fail "developer-cache scan followed a symlinked cache root: $output"

    # The shared helper rejects the same redirected path independently of the
    # scanner, so future bridges cannot accidentally re-enable traversal.
    if env HOME="$home" bash -c 'source "$1"; forgesweep_scan_path_is_physical "$HOME/.npm"' \
        _ "$RUNTIME_DIR/bin/app_scan_access.sh"; then
        fail "physical-path helper accepted a symlinked developer cache"
    fi
    pass "developer-cache scan and apply physical-path boundary"
}

test_analyze_ai_inventory() {
    local home="$TEST_ROOT/analyze-ai-home"
    local trash="$TEST_ROOT/analyze-ai-trash"
    local plan="$TEST_ROOT/analyze-ai-plan"
    local skill="$home/.codex/skills/custom"
    local system_skill="$home/.codex/skills/.system"
    local shared_source="$home/shared/source-skill"
    local shared_link="$home/.agents/skills/shared"
    local mcp_cache="$home/.cache/devin/cli/mcp"
    local config="$home/.codex/config.toml"
    local output="" identity="" rc=0

    mkdir -p "$skill" "$system_skill" "$shared_source" \
        "${shared_link%/*}" "$mcp_cache" "${config%/*}" \
        "$home/.config/mole" "$trash"
    printf '%s\n' '# custom skill' > "$skill/SKILL.md"
    printf '%s\n' '# built in' > "$system_skill/SKILL.md"
    printf '%s\n' '# shared skill' > "$shared_source/SKILL.md"
    printf '%s\n' 'cache' > "$mcp_cache/data"
    printf '%s\n' '[mcp_servers.secret]' > "$config"
    ln -s "$shared_source" "$shared_link"

    set +e
    output=$(env HOME="$home" bash "$RUNTIME_DIR/bin/app_analyze_ai_inventory.sh" 2>&1)
    rc=$?
    set -e
    assert_status 77 "$rc" "AI inventory did not require the verified FDA capability"

    output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_analyze_ai_inventory.sh") || \
        fail "authorized AI Skill/MCP inventory failed"
    [[ "$output" == *$'\tskill\tCodex · custom\t'* ]] || \
        fail "AI inventory did not emit a user Skill: $output"
    [[ "$output" == *$'\tskill_link\tAgents · shared\t'* ]] || \
        fail "AI inventory did not preserve a shared Skill link: $output"
    [[ "$output" == *$'\tmcp_cache\tDevin MCP cache\t'* ]] || \
        fail "AI inventory did not emit a known MCP cache: $output"
    [[ "$output" != *"$system_skill"* && "$output" != *"$config"* ]] || \
        fail "AI inventory exposed a built-in Skill or shared MCP configuration"

    identity=$(/usr/bin/stat -f '%d:%i:%m' "$skill")
    printf '%s\0%s\0' "$skill" "$identity" > "$plan"
    output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_analyze_ai_apply.sh" < "$plan") || \
        fail "manual AI Skill cleanup rejected an approved current identity"
    [[ ! -e "$skill" && "$output" == *"removed=1"* ]] || \
        fail "manual AI Skill cleanup did not move the selected Skill to Trash: $output"

    identity=$(/usr/bin/stat -f '%d:%i:%m' "$shared_link")
    printf '%s\0%s\0' "$shared_link" "$identity" > "$plan"
    output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_analyze_ai_apply.sh" < "$plan") || \
        fail "manual shared Skill cleanup rejected a leaf symlink"
    [[ ! -L "$shared_link" && -f "$shared_source/SKILL.md" ]] || \
        fail "shared Skill cleanup removed the link target instead of only the selected link"

    for target in "$system_skill" "$config"; do
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
        printf '%s\0%s\0' "$target" "$identity" > "$plan"
        set +e
        output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
            MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
            MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
            MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_analyze_ai_apply.sh" < "$plan" 2>&1)
        rc=$?
        set -e
        [[ "$rc" -ne 0 && -e "$target" ]] || \
            fail "AI inventory cleanup accepted protected/config path: $target"
    done

    mkdir -p "$home/.claude/skills/automatic"
    printf '%s\n' '# manual only' > "$home/.claude/skills/automatic/SKILL.md"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$home/.claude/skills/automatic")
    printf '%s\0%s\0' "$home/.claude/skills/automatic" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        SIMPLEMOLE_EXECUTION_MODE=quickClean MOLE_TEST_MODE=1 \
        MOLE_TEST_NO_AUTH=1 MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_analyze_ai_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -f "$home/.claude/skills/automatic/SKILL.md" ]] || \
        fail "Quick Clean was allowed to remove a manually managed AI Skill"

    pass "AI Skill and MCP inventory selection, Trash and path safety"
}

test_system_preview_protocol() {
    local fixture_root="$TEST_ROOT/system-preview-fixture"
    local fixtures="$TEST_ROOT/system-preview-fixtures.sh"
    local output="" line lines=0

    mkdir -p "$fixture_root/logs" "$fixture_root/reports"
    printf 'old log\n' > "$fixture_root/logs/old.log"
    printf 'report\n' > "$fixture_root/reports/crash.report"
    /usr/bin/touch -t 202001010000 \
        "$fixture_root/logs/old.log" "$fixture_root/reports/crash.report"
    cat > "$fixtures" <<EOF
scan_file_group logs safe 0 "" "$fixture_root/logs"
scan_file_group reports safe 0 "" "$fixture_root/reports"
scan_entry_group caches safe 0 "$fixture_root/logs"
EOF

    # "&& break" 作为 emit_sorted 循环体最后一条语句会把循环状态置 1，
    # 函数返回后在 set -e 下杀死脚本：提权扫描授权后永远拿不到结果。
    output=$(env SM_SYSTEM_PREVIEW_FIXTURES="$fixtures" \
        SM_SYSTEM_PREVIEW_MAX_ROWS=400 TMPDIR="$TEST_ROOT" \
        bash "$RUNTIME_DIR/bin/app_system_preview.sh" "$(id -un)" "$HOME") || \
        fail "system preview exited non-zero with under-cap fixture rows"
    while IFS= read -r line; do
        lines=$((lines + 1))
        [[ "$line" == entry$'\t'* ]] || fail "system preview emitted a malformed line"
    done <<< "$output"
    [[ "$lines" -ge 2 ]] || fail "system preview dropped fixture rows"

    output=$(env TMPDIR="$TEST_ROOT" \
        bash "$RUNTIME_DIR/bin/app_system_preview.sh" "$(id -un)" "$HOME") || \
        fail "system preview failed on the machine's real roots"
    pass "system preview protocol survives under-cap groups"
}

test_signing_policy_contract() {
    local package_script="$ROOT_DIR/script/package_dmg.sh"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC' "$ROOT_DIR/script/build.sh" || \
        fail "build does not require an explicit ad-hoc opt-in"
    /usr/bin/grep -Fq 'Apple Development:' "$ROOT_DIR/script/build.sh" || \
        fail "build does not prefer a stable Apple Development identity"
    /usr/bin/grep -Fq 'Ad-hoc GUI builds do not provide a stable identity' \
        "$ROOT_DIR/script/build.sh" || fail "build does not explain TCC identity persistence"
    /usr/bin/grep -Fq 'TeamIdentifier' "$ROOT_DIR/script/build.sh" || \
        fail "build does not validate its stable signing team"
    /usr/bin/grep -Fq 'Developer ID Application certificate' "$ROOT_DIR/script/release.sh" || \
        fail "release accepts a non-Developer-ID signing identity"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC=0' "$ROOT_DIR/script/release.sh" || \
        fail "release can opt into ad-hoc signing"
    /usr/bin/grep -Fq 'SM_ALLOW_ADHOC="${SM_ALLOW_ADHOC:-0}"' \
        "$ROOT_DIR/script/build_and_run.sh" || \
        fail "build_and_run does not preserve the explicit signing policy"
    [[ -f "$package_script" ]] || fail "open-source DMG packaging script is missing"
    /usr/bin/grep -Fq 'SIGN_IDENTITY="${SM_CODESIGN_IDENTITY:--}"' \
        "$package_script" || fail "DMG packaging does not default to ad-hoc signing"
    /usr/bin/grep -Fq 'ALLOW_ADHOC="${SM_ALLOW_ADHOC:-1}"' \
        "$package_script" || fail "DMG packaging does not explicitly allow ad-hoc signing"
    /usr/bin/grep -Fq '/usr/bin/hdiutil create' "$package_script" || \
        fail "DMG packaging does not create a disk image"
    pass "stable development signing and Developer ID release contracts"
}

test_gc_runner() {
    local home="$TEST_ROOT/gc-home"
    local stub_dir="$TEST_ROOT/gc-bin"
    local args_file="$TEST_ROOT/gc-args"
    local output rc args
    mkdir -p "$home" "$stub_dir"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\0" "$@" > "$MOLE_TEST_ARGS_FILE"' \
        'exit "${MOLE_TEST_COMMAND_RC:-0}"' > "$stub_dir/go"
    chmod +x "$stub_dir/go"

    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" \
        MOLE_TEST_ARGS_FILE="$args_file" MOLE_TEST_COMMAND_RC=0 \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_gc_run.sh" go-build 2>&1)
    rc=$?
    set -e
    assert_status 0 "$rc" "gc runner did not execute the whitelisted command"
    args=$(tr '\0' '\n' < "$args_file")
    [[ "$args" == $'clean\n-cache' ]] || fail "gc runner passed unexpected arguments: $args"

    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" \
        MOLE_TEST_ARGS_FILE="$args_file" MOLE_TEST_COMMAND_RC=37 \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_gc_run.sh" go-build 2>&1)
    rc=$?
    set -e
    assert_status 37 "$rc" "gc runner did not preserve command exit status"

    set +e
    output=$(env HOME="$home" PATH="$stub_dir:$PATH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_gc_run.sh" not-allowed 2>&1)
    rc=$?
    set -e
    assert_status 2 "$rc" "gc runner accepted an unknown command id"
    [[ "$output" == *"unknown gc id"* ]] || fail "gc runner did not explain unknown command rejection"
    pass "gc runner dispatch and exit status"
}

test_node_cache_inventory() {
    local home="$TEST_ROOT/node-cache-home"
    local stub_dir="$TEST_ROOT/node-cache-bin"
    local output id
    mkdir -p "$home/.npm/_cacache" "$home/Library/pnpm/store/v10" \
        "$home/.yarn/cache" "$stub_dir"
    printf 'npm-cache' > "$home/.npm/_cacache/index"
    printf 'pnpm-cache' > "$home/Library/pnpm/store/v10/index"
    printf 'yarn-cache' > "$home/.yarn/cache/index"
    for id in npm pnpm yarn; do
        printf '#!/bin/sh\nexit 0\n' > "$stub_dir/$id"
        chmod +x "$stub_dir/$id"
    done

    output=$(env HOME="$home" PATH="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        bash "$RUNTIME_DIR/bin/app_gc_scan.sh") || fail "node cache inventory failed"
    for id in npm pnpm yarn; do
        [[ "$(printf '%s\n' "$output" | awk -F '\t' -v id="$id" \
            '$1 == id { print (($3 + 0) > 0 ? "sized" : "empty"); exit }')" == "sized" ]] || \
            fail "$id shared cache size was not reported: $output"
    done
    pass "nvm global-package and Node shared-cache inventory"
}

test_runtime_store_aggregation() {
    local arch binary module_cache
    arch="$(uname -m)"
    binary="$TEST_ROOT/runtime-store-tests"
    module_cache="$TEST_ROOT/runtime-store-module-cache"
    mkdir -p "$module_cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        -framework AppKit -framework IOKit \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/SystemMetrics.swift" \
        "$ROOT_DIR/SimpleMole/Services/RuntimeStore.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/RuntimeStoreTests.swift" \
        -o "$binary" || fail "compile runtime store aggregation tests"
    "$binary" || fail "runtime store aggregation tests"
    pass "application-level CPU and memory aggregation"
}

assert_single_final_runtime_guard() {
    local home="$1"
    local script="$2"
    local target="$3"
    local label="$4"
    local plan="$TEST_ROOT/single-final-guard-plan"
    local guard_log="$TEST_ROOT/single-final-guard.log"
    local identity output

    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target") || \
        fail "$label fixture has no identity"
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    : > "$guard_log"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle SIMPLEMOLE_DELETE_MODE=permanent \
        SIMPLEMOLE_TEST_FINAL_GUARD_LOG="$guard_log" \
        MOLE_DELETE_LOG="$TEST_ROOT/single-final-guard-deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/$script" < "$plan") || \
        fail "$label rejected an idle target at its final deletion edge: $output"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "$label did not complete through its final runtime guard: $output"
    [[ "$(wc -l < "$guard_log" | tr -d ' ')" == "1" ]] || \
        fail "$label repeated its runtime guard before the final deletion edge"
}

test_identity_bound_apply() {
    local home="$TEST_ROOT/apply-home"
    local trash="$TEST_ROOT/trash"
    local plan="$TEST_ROOT/apply-plan"
    local target identity stale_identity stale_mtime output rc
    mkdir -p "$home/Library/Caches/simple-mole-test" "$trash"

    target="$home/Library/Caches/simple-mole-test/current item.cache"
    printf 'current\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || fail "identity-bound apply rejected a current identity"
    [[ ! -e "$target" ]] || fail "identity-bound apply left the approved target in place"
    [[ "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "identity-bound apply returned unexpected counters: $output"
    [[ -n "$(find "$trash" -mindepth 1 -print -quit)" ]] || \
        fail "cleanup bridge default no longer uses recoverable Trash"

    # Recommended Trash candidates are handled as top-level items only; the
    # final sink rejects database families even when a stale plan tries to
    # submit them as ordinary files.
    mkdir -p "$home/.Trash"
    target="$home/.Trash/old-recording.mov"
    printf 'recording\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$trash" \
        MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || \
        fail "Trash candidate was rejected at the final cleanup edge"
    [[ ! -e "$target" && "$output" == *"removed=1"* ]] || \
        fail "ordinary Trash candidate was not permanently removed"

    target="$home/.Trash/old-history.db"
    printf 'database\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$trash" \
        MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "Trash database candidate crossed the final safety guard"

    # Disk cleanup opts into permanent deletion explicitly. It must not create
    # a Trash copy, while the bridge default above remains recoverable.
    local permanent_trash="$TEST_ROOT/permanent-trash"
    mkdir -p "$permanent_trash"
    target="$home/Library/Caches/simple-mole-test/permanent item.cache"
    printf 'permanent\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle SIMPLEMOLE_DELETE_MODE=permanent \
        MOLE_TEST_TRASH_DIR="$permanent_trash" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || \
        fail "disk cleanup permanent mode rejected a valid target"
    [[ ! -e "$target" && -z "$(find "$permanent_trash" -mindepth 1 -print -quit)" ]] || \
        fail "disk cleanup permanent mode created a Trash copy"
    /usr/bin/grep -Fq $'\tpermanent\t' "$TEST_ROOT/deletions.log" || \
        fail "permanent cleanup was not recorded in the deletion audit log"

    target="$home/Library/Caches/simple-mole-test/invalid mode.cache"
    printf 'keep\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_DELETE_MODE=unknown MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"invalid cleanup delete mode"* ]] || \
        fail "cleanup bridge accepted an invalid delete mode: $output"

    target="$home/Library/Caches/simple-mole-test/stale item.cache"
    printf 'stale\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    stale_mtime=$((${identity##*:} + 1))
    stale_identity="${identity%:*}:$stale_mtime"
    printf '%s\0%s\0' "$target" "$stale_identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 ]] || fail "identity-bound apply accepted a stale identity"
    [[ -e "$target" ]] || fail "identity-bound apply removed a stale-identity target"
    [[ "$output" == *"failed=1"* ]] || fail "stale identity was not reported as failed: $output"

    # A reverse-DNS cache owner is rechecked at the final deletion sink. Both
    # an active owner and an unavailable process snapshot must fail closed.
    target="$home/Library/Caches/com.example.Editor/active item.cache"
    mkdir -p "${target%/*}"
    printf 'active owner\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=active SIMPLEMOLE_DELETE_MODE=permanent \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/active-final-guard.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "generic cleanup ignored an active reverse-DNS cache owner: $output"
    /usr/bin/grep -Fq $'\tfinal-guard\t' "$TEST_ROOT/active-final-guard.log" || \
        fail "active owner was not rejected by the mutation-edge guard"

    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=unknown MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "generic cleanup treated an unknown reverse-DNS owner as idle: $output"

    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan") || \
        fail "generic cleanup rejected a conclusively idle reverse-DNS cache owner"
    [[ ! -e "$target" && "$output" == *"removed=1"* ]] || \
        fail "generic cleanup did not remove an idle reverse-DNS cache: $output"

    # Use a non-bundle cache root here so Mole's independent live-bundle
    # policy does not require a real process table in the shell sandbox. The
    # route guard still exercises its path-open branch and is counted below.
    target="$home/Library/Caches/simple-guard-cache/rebuild.cache"
    mkdir -p "${target%/*}"
    printf 'single guard\n' > "$target"
    assert_single_final_runtime_guard "$home" app_apply.sh "$target" \
        "generic cleanup"

    target="$home/Library/Caches/com.example.ModelTool/rebuild-cache"
    mkdir -p "$target"
    printf 'model\n' > "$target/weights.safetensors"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_EXECUTION_MODE=automatic MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/weights.safetensors" && \
       "$output" == *"failed=1"* ]] ||
        fail "automatic Quick Clean accepted a model nested in a Safe cache: $output"

    target="$home/Library/Caches/com.example.SessionTool/rebuild-cache"
    mkdir -p "$target/sessions"
    printf 'conversation\n' > "$target/sessions/current.json"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_EXECUTION_MODE=quickClean MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$trash" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/sessions/current.json" && \
       "$output" == *"failed=1"* ]] ||
        fail "automatic Quick Clean accepted a generic user-session directory: $output"

    target="$home/Library/DiagnosticReports/active.crash"
    mkdir -p "${target%/*}"
    printf 'diagnostic\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=active MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] ||
        fail "generic Warning cleanup ignored an open target: $output"
    pass "cleanup plan path and identity binding"
}

test_auto_cleanup_apply() {
    local home
    local trash="$TEST_ROOT/auto-trash"
    local plan="$TEST_ROOT/auto-plan"
    local root target identity stale_identity output rc actual link_target
    home="$(cd "$TEST_ROOT" && pwd -P)/auto-home"
    mkdir -p "$home/.config/mole" "$trash"

    run_auto_apply_fixture() {
        env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            MOLE_TEST_LSOF_STATE=idle \
            MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/auto-deletions.log" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_auto_apply.sh" < "$plan"
    }

    write_auto_plan() {
        local plan_root="$1" plan_path="$2" plan_identity="$3"
        local plan_token="${4:-safe-trash-v4}"
        local newest=0 item item_mtime authorized_root_identity
        authorized_root_identity=$(/usr/bin/stat -f '%d:%i:%B' "$plan_root") || \
            fail "could not identify auto-cleanup rule root"
        if [[ -d "$plan_path" && ! -L "$plan_path" ]]; then
            while IFS= read -r -d '' item; do
                [[ "$item" == "$plan_path" || ! -L "$item" ]] || continue
                item_mtime=$(/usr/bin/stat -f '%m' "$item") || fail "could not stat auto-plan fixture"
                (( item_mtime > newest )) && newest="$item_mtime"
            done < <(/usr/bin/find -P "$plan_path" -xdev -print0)
        else
            newest=$(/usr/bin/stat -f '%m' "$plan_path") || fail "could not stat auto-plan fixture"
        fi
        printf '%s\0%s\0%s\0%s\0%s\0%s\0' \
            "$plan_root" "$authorized_root_identity" "$plan_path" \
            "$plan_identity" "$newest" "$plan_token" > "$plan"
    }

    # A current direct child reaches the final Trash deletion sink.
    root="$home/current-root"
    target="$root/current.cache"
    mkdir -p "$root"
    printf 'current\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    output=$(run_auto_apply_fixture) || fail "automatic cleanup rejected a current direct child"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "automatic cleanup did not remove a current direct child: $output"

    # A nested descendant is outside the direct-child contract.
    root="$home/nested-root"
    target="$root/nested/item.cache"
    mkdir -p "${target%/*}"
    printf 'nested\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a non-direct child: $output"

    # Preview/apply identity changes fail closed.
    root="$home/stale-root"
    target="$root/stale.cache"
    mkdir -p "$root"
    printf 'stale\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    stale_identity="${identity%:*}:$(( ${identity##*:} + 1 ))"
    write_auto_plan "$root" "$target" "$stale_identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a stale identity: $output"

    # HOME itself can never become a disposable rule root.
    target="$home/home-child.cache"
    printf 'home\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$home" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted HOME as a rule root: $output"

    # The configured root itself must not be a symlink.
    actual="$home/actual-root"
    root="$home/root-link"
    target="$root/link-root-item.cache"
    mkdir -p "$actual"
    printf 'linked root\n' > "$actual/link-root-item.cache"
    ln -s "$actual" "$root"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$actual/link-root-item.cache" && "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a symlink rule root: $output"

    # Symlinks in any ancestor of the configured root are rejected too.
    actual="$home/actual-parent"
    root="$home/parent-link/managed"
    target="$root/ancestor-link-item.cache"
    mkdir -p "$actual/managed"
    printf 'linked ancestor\n' > "$actual/managed/ancestor-link-item.cache"
    ln -s "$actual" "$home/parent-link"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$actual/managed/ancestor-link-item.cache" && \
        "$output" == *"failed=1"* ]] || \
        fail "automatic cleanup accepted a symlinked root ancestor: $output"

    # Whitelisted children are reported as skipped and kept.
    root="$home/whitelist-root"
    target="$root/keep.cache"
    mkdir -p "$root"
    printf 'keep\n' > "$target"
    printf '%s\n' "$target" > "$home/.config/mole/whitelist"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    output=$(run_auto_apply_fixture) || fail "automatic cleanup failed on a whitelisted child"
    [[ -e "$target" && "$output" == *"removed=0"* && \
        "$output" == *"skipped=1"* && "$output" == *"failed=0"* ]] || \
        fail "automatic cleanup did not preserve a whitelisted child: $output"

    # A direct symlink child is moved as a link; its target is never followed.
    root="$home/symlink-child-root"
    link_target="$home/symlink-target"
    target="$root/rebuildable-link"
    mkdir -p "$root" "$link_target"
    printf 'target data\n' > "$link_target/item"
    ln -s "$link_target" "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    output=$(run_auto_apply_fixture) || fail "automatic cleanup rejected a direct symlink child"
    [[ ! -L "$target" && -e "$link_target/item" && "$output" == *"removed=1"* ]] || \
        fail "automatic cleanup followed or retained a direct symlink child: $output"

    # Project/session/model markers make an otherwise authorized item Protected.
    root="$home/protected-content-root"
    target="$root/project-snapshot"
    mkdir -p "$target"
    printf '{}\n' > "$target/package.json"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/package.json" && "$output" == *"protected"* ]] || \
        fail "automatic cleanup accepted protected project content: $output"

    # Model payloads are protected even when their parent directory has a
    # generic cache name rather than a recognizable `models` component.
    root="$home/protected-model-root"
    target="$root/rebuild-cache"
    mkdir -p "$target"
    printf 'model\n' > "$target/weights.gguf"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/weights.gguf" && "$output" == *"protected model"* ]] || \
        fail "automatic cleanup accepted a model outside a named model directory: $output"

    root="$home/protected-session-root"
    target="$root/generic-cache"
    mkdir -p "$target/.gemini/tmp"
    printf 'session\n' > "$target/.gemini/tmp/history.jsonl"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/.gemini/tmp/history.jsonl" && \
        "$output" == *"session"* ]] || \
        fail "automatic cleanup accepted a Gemini user session: $output"

    # Running/open and unknown open-file states both fail closed.
    root="$home/open-root"
    target="$root/active.cache"
    mkdir -p "$root"
    printf 'active\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_LSOF_STATE=open MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_auto_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"in use"* ]] || \
        fail "automatic cleanup accepted an open item: $output"

    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_LSOF_STATE=unknown MOLE_TEST_TRASH_DIR="$trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_auto_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"verify"* ]] || \
        fail "automatic cleanup accepted an unknown open-file state: $output"

    # Consent is bound to the directory object, not only its pathname.
    root="$home/replaced-authorization-root"
    target="$root/generated.cache"
    mkdir -p "$root"
    printf 'same candidate\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    mv "$target" "$home/generated.cache.staged"
    rmdir "$root"
    mkdir -p "$root"
    mv "$home/generated.cache.staged" "$target"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"changed after authorization"* ]] || \
        fail "automatic cleanup let a replacement root inherit authorization: $output"

    # A nested write may leave the top-level directory identity unchanged.
    # The recursive freshness token must still invalidate the plan.
    root="$home/freshness-root"
    target="$root/generated-output"
    mkdir -p "$target/nested"
    printf 'old\n' > "$target/nested/data.cache"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity"
    /usr/bin/touch -t 203001010000 "$target/nested/data.cache"
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/nested/data.cache" &&
        "$output" == *"changed after planning"* ]] || \
        fail "automatic cleanup ignored a nested write after planning: $output"

    # Old callers without the current Safe authorization token cannot execute.
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    write_auto_plan "$root" "$target" "$identity" safe-trash-v2
    set +e
    output=$(run_auto_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"renewed Safe authorization"* ]] || \
        fail "automatic cleanup accepted a stale safety authorization: $output"

    pass "automatic cleanup Safe, runtime, root, identity, whitelist and symlink guards"
}

test_installer_apply() {
    local home trash plan target identity output rc outside state trash_before
    home="$(cd "$TEST_ROOT" && pwd -P)/installer-home"
    trash="$TEST_ROOT/installer-trash"
    plan="$TEST_ROOT/installer-plan"
    mkdir -p "$home/.config/mole" "$home/Downloads" "$home/Desktop" "$trash"

    run_installer_apply_fixture() {
        local delete_mode="${1:-trash}" process_state="${2:-idle}"
        env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            SIMPLEMOLE_DELETE_MODE="$delete_mode" MOLE_TEST_PROCESS_STATE="$process_state" \
            MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/installer-deletions.log" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_installer_apply.sh" < "$plan"
    }

    target="$home/Downloads/Tool.DMG"
    printf 'installer\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(run_installer_apply_fixture) || fail "installer apply rejected an allowed current file"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "installer apply did not Trash an allowed file: $output"
    [[ "$(find "$trash" -type f | wc -l | tr -d ' ')" == "1" ]] || \
        fail "recoverable installer apply did not use the isolated Trash fixture"

    target="$home/Downloads/Permanent.pkg"
    printf 'permanent installer\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    trash_before=$(find "$trash" -type f | wc -l | tr -d ' ')
    output=$(run_installer_apply_fixture permanent) || \
        fail "permanent installer apply rejected an allowed current file: $output"
    [[ ! -e "$target" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "permanent installer apply did not delete the selected file: $output"
    [[ "$(find "$trash" -type f | wc -l | tr -d ' ')" == "$trash_before" ]] || \
        fail "permanent installer apply incorrectly moved the file to Trash"
    /usr/bin/grep -Fq $'\tpermanent\t' "$TEST_ROOT/installer-deletions.log" || \
        fail "permanent installer apply did not reach the permanent deletion sink"

    # A mounted/open installer, or an unavailable process snapshot, must stay
    # in place even after the user confirmed permanent deletion.
    for state in active unknown; do
        target="$home/Downloads/$state.dmg"
        printf '%s installer\n' "$state" > "$target"
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
        printf '%s\0%s\0' "$target" "$identity" > "$plan"
        set +e
        output=$(run_installer_apply_fixture permanent "$state" 2>&1)
        rc=$?
        set -e
        [[ "$rc" -eq 0 && -e "$target" && "$output" == *"removed=0"* && \
            "$output" == *"skipped=1"* && "$output" == *"failed=0"* ]] || \
            fail "permanent installer apply ignored $state runtime state: $output"
        [[ "$(find "$trash" -type f | wc -l | tr -d ' ')" == "$trash_before" ]] || \
            fail "runtime-protected installer was moved to Trash"
        /usr/bin/grep -F $'\tfinal-guard\t' "$TEST_ROOT/installer-deletions.log" | \
            /usr/bin/grep -Fq "$target" || \
            fail "$state installer was not protected at the final deletion edge"
    done

    outside="$home/not-allowed"
    target="$outside/Outside.dmg"
    mkdir -p "$outside"
    printf 'outside\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "permanent installer apply accepted a file outside configured roots: $output"

    target="$home/Downloads/notes.txt"
    printf 'not an installer\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "installer apply accepted an unsupported extension: $output"

    target="$home/Downloads/plain.zip"
    printf 'not a zip archive\n' > "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "installer apply accepted a non-installer zip: $output"

    target="$home/Downloads/stale.pkg"
    printf 'stale\n' > "$target"
    identity=$(stale_identity_for "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target" && "$output" == *"failed=1"* ]] || \
        fail "permanent installer apply accepted a stale identity: $output"

    target="$home/Downloads/keep.xip"
    printf 'keep\n' > "$target"
    printf '%s\n' "$target" > "$home/.config/mole/whitelist"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(run_installer_apply_fixture permanent) || fail "installer apply failed on a whitelisted file"
    [[ -e "$target" && "$output" == *"skipped=1"* && "$output" == *"failed=0"* ]] || \
        fail "installer apply did not preserve a whitelisted file: $output"
    : > "$home/.config/mole/whitelist"

    target="$home/Downloads/link.dmg"
    printf 'target\n' > "$outside/link-target.dmg"
    ln -s "$outside/link-target.dmg" "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -L "$target" && -e "$outside/link-target.dmg" && \
        "$output" == *"failed=1"* ]] || \
        fail "installer apply accepted a symlink leaf: $output"

    mkdir -p "$home/Desktop" "$outside/escaped-parent"
    ln -s "$outside/escaped-parent" "$home/Desktop/escape"
    target="$home/Desktop/escape/Escaped.iso"
    printf 'escape\n' > "$outside/escaped-parent/Escaped.iso"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(run_installer_apply_fixture permanent 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$outside/escaped-parent/Escaped.iso" && \
        "$output" == *"failed=1"* ]] || \
        fail "installer apply followed a symlinked ancestor outside its root: $output"

    pass "installer apply permanent/Trash modes, runtime, root, type, identity, whitelist and symlink guards"
}

test_packaged_apply_layout() {
    local home="$TEST_ROOT/layout-home"
    local output
    [[ -d "$ROOT_DIR/vendor/mole/lib" ]] || \
        fail "vendored bridge support libraries are incomplete"
    [[ -s "$ROOT_DIR/vendor/mole/LICENSE" && -s "$ROOT_DIR/vendor/mole/UPSTREAM_COMMIT" ]] || \
        fail "vendored Mole license or audited revision is missing"
    /usr/bin/grep -Fq 'MOLE_SRC="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"' \
        "$ROOT_DIR/script/build.sh" || \
        fail "build still depends on an external sibling Mole checkout"
    mkdir -p "$home"

    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$TEST_ROOT/layout-trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_dev_apply.sh" < /dev/null) || \
        fail "packaged dev apply could not load Mole libraries"
    [[ "$output" == *"failed=0"* ]] || fail "unexpected dev apply result: $output"

    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$TEST_ROOT/layout-trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_purge_apply.sh" < /dev/null) || \
        fail "packaged purge apply could not load Mole libraries"
    [[ "$output" == *"failed=0"* ]] || fail "unexpected purge apply result: $output"

    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$TEST_ROOT/layout-trash" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_installer_apply.sh" < /dev/null) || \
        fail "packaged installer apply could not load Mole libraries"
    [[ "$output" == *"failed=0"* ]] || fail "unexpected installer apply result: $output"
    pass "packaged apply resource layout"
}

stale_identity_for() {
    local identity
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$1") || return 1
    printf '%s:%s\n' "${identity%:*}" "$(( ${identity##*:} + 1 ))"
}

assert_special_stale_identity_rejected() {
    local script="$1"
    local record="$2"
    local target="$3"
    local label="$4"
    local plan="$TEST_ROOT/special-plan"
    local identity output rc
    identity=$(stale_identity_for "$target") || fail "$label fixture has no identity"
    printf '%s\0%s\0' "$record" "$identity" > "$plan"

    set +e
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" MOLE_DELETE_LOG="$TEST_ROOT/special-deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/$script" < "$plan" 2>&1)
    rc=$?
    set -e

    [[ "$rc" -ne 0 ]] || fail "$label accepted a stale identity"
    [[ -e "$target" || -L "$target" ]] || fail "$label removed a stale-identity target"
    [[ "$output" == *"failed=1"* ]] || fail "$label did not report identity failure: $output"
}

test_special_apply_identity_binding() {
    SPECIAL_HOME="$TEST_ROOT/special-home"
    SPECIAL_TRASH="$TEST_ROOT/special-trash"
    export SPECIAL_HOME SPECIAL_TRASH
    local plan="$TEST_ROOT/special-plan"
    local target identity output
    mkdir -p "$SPECIAL_HOME/.config/mole" "$SPECIAL_TRASH"

    # Current identities still reach the final Mole deletion sink.
    target="$SPECIAL_HOME/.npm"
    mkdir -p "$target"
    printf 'cache\n' > "$target/item"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" MOLE_DELETE_LOG="$TEST_ROOT/special-deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_dev_apply.sh" < "$plan") || \
        fail "dev cleanup rejected a current identity"
    [[ ! -e "$target" && "$output" == *"removed=1"* ]] || \
        fail "dev cleanup did not remove the identity-bound target: $output"

    mkdir -p "$SPECIAL_HOME/.npm"
    printf 'single guard\n' > "$SPECIAL_HOME/.npm/item"
    assert_single_final_runtime_guard "$SPECIAL_HOME" app_dev_apply.sh \
        "$SPECIAL_HOME/.npm" "developer cleanup"

    # Quick/automatic specialized routes recursively enforce the same hard
    # model/session boundary as the generic cleanup sink.
    mkdir -p "$target/sessions"
    printf 'session\n' > "$target/sessions/current.json"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        SIMPLEMOLE_EXECUTION_MODE=quickClean MOLE_TEST_PROCESS_STATE=idle \
        MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_dev_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/sessions/current.json" ]] || \
        fail "Quick Clean developer route accepted nested session content: $output"

    # Final bridges recheck the owning process immediately before deletion.
    mkdir -p "$target"
    printf 'active cache\n' > "$target/item"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=active MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MOLE_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_dev_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/item" && "$output" == *"failed=1"* ]] || \
        fail "dev cleanup ignored an active owner: $output"

    # Developer scan also routes known reverse-DNS app caches through this
    # bridge, so those paths need the same owner-specific final recheck.
    target="$SPECIAL_HOME/Library/Caches/com.openai.chat"
    mkdir -p "$target"
    printf 'active app cache\n' > "$target/item"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=active MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_dev_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/item" && "$output" == *"failed=1"* ]] || \
        fail "dev cleanup ignored an active reverse-DNS cache owner: $output"

    # Every specialized bridge must reject the same path with a stale identity.
    assert_special_stale_identity_rejected \
        app_dev_apply.sh "$SPECIAL_HOME/.npm" "$SPECIAL_HOME/.npm" "dev cleanup"

    mkdir -p "$SPECIAL_HOME/.claude/statsig"
    assert_special_stale_identity_rejected \
        app_ai_apply.sh "$SPECIAL_HOME/.claude/statsig" \
        "$SPECIAL_HOME/.claude/statsig" "AI cleanup"

    # Codex Desktop's audited Chromium leaf is an explicit AI-safe route; the
    # surrounding profile contains durable browser state and stays excluded.
    target="$SPECIAL_HOME/Library/Caches/Codex/Default/Cache"
    mkdir -p "$target"
    printf 'codex cache\n' > "$target/item"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$plan") || \
        fail "AI cleanup rejected the allowlisted Codex cache"
    [[ ! -e "$target" && "$output" == *"removed=1"* ]] || \
        fail "AI cleanup did not remove the allowlisted Codex cache: $output"

    # The expanded Electron/XDG leaves must use the same identity-bound apply
    # route, including a path with a space in its name.
    local ai_leaf
    for ai_leaf in \
        "$SPECIAL_HOME/Library/Application Support/Antigravity/Cache" \
        "$SPECIAL_HOME/Library/Application Support/Filo/production/Code Cache" \
        "$SPECIAL_HOME/Library/Application Support/Claude/sentry" \
        "$SPECIAL_HOME/Library/Application Support/Qoder/CachedData" \
        "$SPECIAL_HOME/.cache/prisma" "$SPECIAL_HOME/.cache/opencode"; do
        mkdir -p "$ai_leaf"
        printf 'ai cache\n' > "$ai_leaf/item"
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$ai_leaf")
        printf '%s\0%s\0' "$ai_leaf" "$identity" > "$plan"
        output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$plan") || \
            fail "AI cleanup rejected expanded cache leaf: $ai_leaf"
        [[ ! -e "$ai_leaf" && "$output" == *"removed=1"* ]] || \
            fail "AI cleanup did not remove expanded cache leaf: $ai_leaf ($output)"
    done

    # The same allowlist must not become a symlink escape hatch.
    local ai_outside="$TEST_ROOT/special-ai-outside"
    mkdir -p "$ai_outside"
    printf 'outside\n' > "$ai_outside/item"
    ln -s "$ai_outside" "$target"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -L "$target" && -e "$ai_outside/item" && \
        "$output" == *"failed=1"* ]] || \
        fail "AI cleanup followed a symlinked Codex cache root: $output"

    mkdir -p "$SPECIAL_HOME/.claude/statsig"
    printf 'single guard\n' > "$SPECIAL_HOME/.claude/statsig/item"
    assert_single_final_runtime_guard "$SPECIAL_HOME" app_ai_apply.sh \
        "$SPECIAL_HOME/.claude/statsig" "AI cleanup"

    target="$SPECIAL_HOME/.codex/sessions/current"
    mkdir -p "$target"
    printf 'conversation\n' > "$target/session.jsonl"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$plan") || \
        fail "AI cleanup failed while refusing session history"
    [[ -e "$target/session.jsonl" && "$output" == *"skipped=1"* ]] || \
        fail "AI cleanup accepted session history: $output"

    target="$SPECIAL_HOME/.gemini/tmp"
    mkdir -p "$target"
    printf 'gemini session\n' > "$target/history.jsonl"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$target")
    printf '%s\0%s\0' "$target" "$identity" > "$plan"
    set +e
    output=$(env HOME="$SPECIAL_HOME" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_PROCESS_STATE=idle MOLE_TEST_TRASH_DIR="$SPECIAL_TRASH" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -e "$target/history.jsonl" && "$output" == *"failed=1"* ]] || \
        fail "AI cleanup accepted Gemini temporary session data: $output"

    mkdir -p "$SPECIAL_HOME/Library/Developer/Xcode/DerivedData/AppBuild"
    assert_special_stale_identity_rejected \
        app_xcode_apply.sh "$SPECIAL_HOME/Library/Developer/Xcode/DerivedData/AppBuild" \
        "$SPECIAL_HOME/Library/Developer/Xcode/DerivedData/AppBuild" "Xcode cleanup"

    mkdir -p "$SPECIAL_HOME/Library/Developer/Xcode/DerivedData/SingleGuard"
    printf 'single guard\n' > \
        "$SPECIAL_HOME/Library/Developer/Xcode/DerivedData/SingleGuard/item"
    assert_single_final_runtime_guard "$SPECIAL_HOME" app_xcode_apply.sh \
        "$SPECIAL_HOME/Library/Developer/Xcode/DerivedData/SingleGuard" "Xcode cleanup"

    mkdir -p "$SPECIAL_HOME/Code/project/node_modules"
    printf '%s\n' "$SPECIAL_HOME/Code" > "$SPECIAL_HOME/.config/mole/purge_paths"
    assert_special_stale_identity_rejected \
        app_purge_apply.sh "$SPECIAL_HOME/Code/project/node_modules" \
        "$SPECIAL_HOME/Code/project/node_modules" "project purge"

    mkdir -p "$SPECIAL_HOME/Pictures"
    printf 'image\n' > "$SPECIAL_HOME/Pictures/stale.png"
    assert_special_stale_identity_rejected \
        app_slim_apply.sh "duplicate|$SPECIAL_HOME/Pictures/stale.png" \
        "$SPECIAL_HOME/Pictures/stale.png" "image slimming"

    pass "specialized cleanup path and identity binding"
}

test_uninstall_space_breakdown() {
    local native_core="$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    /usr/bin/grep -Fq 'bytes: self.directorySize(appURL), label: "app"' \
        "$native_core" || fail "native uninstall plan does not size the app bundle separately"
    /usr/bin/grep -q 'uninstall.action' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "uninstall list action is not wired to the uninstall label"
    /usr/bin/grep -Fq 'return matches.sorted' "$ROOT_DIR/SimpleMole/Services/UninstallListProjection.swift" || \
        fail "uninstall list is not sorted by estimated reclaimable bytes"
    /usr/bin/grep -Fq 'scheduler: uninstallPresentationQueue' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "uninstall list sorting is not moved off the UI actor"
    /usr/bin/grep -Fq 'let space: UninstallSpaceBreakdown' "$ROOT_DIR/SimpleMole/Models.swift" || \
        fail "uninstall space is still recomputed during rendering"
    /usr/bin/grep -Fq '.task(id: isActive)' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "uninstall loading is not cancelled on navigation"
    if /usr/bin/grep -Fq 'NSWorkspace.shared.icon(forFile:' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"; then
        fail "uninstall icon lookup still runs inside the SwiftUI task"
    fi
    /usr/bin/grep -Fq 'UninstallFileDrawer(files: plan.files)' \
        "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "uninstall details are not available as an inline drawer"
    /usr/bin/grep -Fq 'onUninstall: { state.previewUninstall(app) }' \
        "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift" || \
        fail "first-level uninstall action is not wired directly"
    if /usr/bin/grep -Fq 'UninstallDetailView' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"; then
        fail "obsolete second-level uninstall page still exists"
    fi
    if /usr/bin/grep -q 'uninstall.preview"' "$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"; then
        fail "uninstall list still exposes the preview label"
    fi
    /usr/bin/grep -Fq 'NativeCore.shared.scanInstalledApps' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "AppState does not use the native app inventory"
    /usr/bin/grep -Fq 'startUninstallInventoryMonitoring(includeProtectedPaths: false)' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "external installs and uninstalls do not trigger an inventory refresh"
    /usr/bin/grep -Fq 'startUninstallInventoryMonitoring(includeProtectedPaths: true)' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "Trash inventory monitoring is not activated after Full Disk Access"
    /usr/bin/grep -Fq 'uninstallInventoryWatchedPaths.contains(path)' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "inventory filesystem watchers are not idempotent"
    /usr/bin/grep -Fq 'UninstallInventoryCache.restoreInBackground()' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "uninstall inventory is not restored across app launches"
    /usr/bin/grep -Fq 'withTaskGroup' "$ROOT_DIR/SimpleMole/AppState.swift" || \
        fail "new and changed apps are not enriched in bounded background batches"
    /usr/bin/grep -Fq 'DeletionPlan.identity(at: app.path + "/Contents/Info.plist") == app.infoIdentity' \
        "$native_core" || fail "native uninstall does not bind the app Info.plist identity"
    /usr/bin/grep -Fq 'candidate.path != appURL.path' "$native_core" || \
        fail "native uninstall does not protect same-Bundle-ID sibling installs"
    /usr/bin/grep -Fq 'self.relatedUninstallCandidates(' "$native_core" || \
        fail "native uninstall does not build an exact related-file plan"

    local key copy_count
    for key in uninstall.action uninstall.space.cache uninstall.space.data uninstall.space.total uninstall.loading; do
        copy_count=$(/usr/bin/grep -h "\"$key\":" \
            "$ROOT_DIR"/SimpleMole/L10n/Tables*.swift | /usr/bin/wc -l | tr -d ' ')
        [[ "$copy_count" == "12" ]] || \
            fail "$key is missing from a locale ($copy_count/12)"
    done

    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        local arch binary module_cache
        arch="$(uname -m)"
        binary="$TEST_ROOT/uninstall-space-tests"
        module_cache="$TEST_ROOT/uninstall-space-module-cache"
        mkdir -p "$module_cache"
        swiftc -target "$arch-apple-macos13.0" \
            -module-cache-path "$module_cache" \
            "$ROOT_DIR/SimpleMole/Models.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
            "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
            "$ROOT_DIR/SimpleMole/Services/UninstallInventoryCache.swift" \
            "$ROOT_DIR/SimpleMole/Services/UninstallListProjection.swift" \
            "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
            "$ROOT_DIR/script/UninstallSpaceTests.swift" \
            -o "$binary" || fail "compile uninstall space tests"
        "$binary" || fail "uninstall space tests"
    fi

    pass "uninstall action, non-overlapping space breakdown and locale contract"
}

test_native_cask_uninstall_contract() {
    local native_core="$ROOT_DIR/SimpleMole/Services/NativeCore.swift"
    /usr/bin/grep -Fq 'private func nativeBrewCaskToken(for app: UninstallApp)' \
        "$native_core" || fail "native uninstall does not resolve Homebrew casks"
    /usr/bin/grep -Fq 'runCommand(brew, ["uninstall", "--cask", "--force", plan.caskToken])' \
        "$native_core" || fail "native cask uninstall does not use the reviewed token"
    /usr/bin/grep -Fq 'result.removed + 1' "$native_core" || \
        fail "native cask uninstall does not count an app removed by Homebrew"
    /usr/bin/grep -Fq '^[A-Za-z0-9@._+/-]+$' "$native_core" || \
        fail "native cask uninstall does not validate the token"
    if /usr/bin/sed -n '/func applyUninstall(/,/\/\/ MARK: Optimize/p' \
        "$native_core" | /usr/bin/grep -q 'autoremove'; then
        fail "native cask uninstall runs unreviewed brew autoremove"
    fi
    if /usr/bin/sed -n '/func previewUninstall(_ app:/,/func uninstallJob(for app:/p' \
        "$ROOT_DIR/SimpleMole/AppState.swift" | /usr/bin/grep -q 'confirmation = Confirmation'; then
        fail "uninstall action still inserts an application confirmation dialog"
    fi
    pass "native Homebrew cask discovery, token validation and uninstall"
}

test_uninstall_queue() {
    local state_source="$ROOT_DIR/SimpleMole/AppState.swift"
    local view_source="$ROOT_DIR/SimpleMole/Views/UninstallTabView.swift"
    if /usr/bin/grep -Eq 'isDisabled: state\.(isUninstalling|isPreviewingUninstall)|disabled\(state\.isUninstalling' \
        "$view_source"; then
        fail "one uninstall still disables every application row"
    fi
    /usr/bin/grep -Fq 'job.state.isPending || job.state.isActive' "$view_source" || \
        fail "uninstall row does not render the current app queue state"
    /usr/bin/grep -Fq 'state.cancelQueuedUninstall(id: job.id)' "$view_source" || \
        fail "pending uninstall cancellation is not exposed in the UI"
    /usr/bin/grep -Fq 'uninstallQueue.enqueue(app: app, plan: plan)' "$state_source" || \
        fail "uninstall confirmation does not enqueue its captured request"
    /usr/bin/grep -Fq 'let target = job.app' "$state_source" || \
        fail "uninstall worker does not use the queued application identity"
    /usr/bin/grep -Fq 'NativeCore.shared.applyUninstall(target, plan: plan,' "$state_source" || \
        fail "uninstall worker does not pass its captured target and plan to NativeCore"
    if /usr/bin/grep -Eq 'var uninstall(Target|Files|NeedsAdmin|IsBrewCask|CaskToken|IncludesProtectedAppData)' \
        "$state_source"; then
        fail "mutable row selection can still overwrite a queued uninstall request"
    fi
    /usr/bin/grep -Fq 'uninstallQueue.startNext(blocked: blocked)' "$state_source" || \
        fail "uninstall worker bypasses the queue's exclusive start"
    /usr/bin/grep -Fq 'isBusyExcludingUninstall || confirmation != nil || isDispatchingConfirmation' \
        "$state_source" || fail "uninstall worker is not gated against other writes and confirmations"
    /usr/bin/grep -Fq 'state.runConfirmation(accepted)' \
        "$ROOT_DIR/SimpleMole/Views/MainWindowView.swift" || \
        fail "confirmation dispatch bypasses the asynchronous operation gate"
    /usr/bin/grep -Fq 'guard !isStoppingUninstallQueue, !blocked,' "$state_source" || \
        fail "queue wakeups can start another uninstall while the app is terminating"
    /usr/bin/awk '
        /func applicationWillTerminate/ { inside = 1 }
        inside && /stopUninstallQueueForTermination/ { stopped = 1 }
        inside && /MoleEngine.shared.cancelAll/ {
            if (!stopped) exit 1
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$ROOT_DIR/SimpleMole/AppDelegate.swift" || \
        fail "app termination must close the queue before cancelling active subprocesses"
    /usr/bin/grep -Fq 'DeletionPlan.identity(at: app.path) == app.appIdentity' \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" || \
        fail "queued native uninstall no longer revalidates the app identity"
    /usr/bin/grep -Fq 'messages: result.messages + ["The application bundle was not removed."]' \
        "$ROOT_DIR/SimpleMole/Services/NativeCore.swift" || \
        fail "native uninstall can report success while the app bundle still exists"

    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        local arch binary module_cache
        arch="$(uname -m)"
        binary="$TEST_ROOT/uninstall-queue-tests"
        module_cache="$TEST_ROOT/uninstall-queue-module-cache"
        mkdir -p "$module_cache"
        swiftc -target "$arch-apple-macos13.0" \
            -module-cache-path "$module_cache" \
            "$ROOT_DIR/SimpleMole/Models.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
            "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
            "$ROOT_DIR/SimpleMole/Services/UninstallQueue.swift" \
            "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
            "$ROOT_DIR/script/UninstallQueueTests.swift" \
            -o "$binary" || fail "compile uninstall queue tests"
        "$binary" || fail "uninstall queue tests"
    fi

    pass "uninstall FIFO, immutable requests, cancellation and asynchronous single worker"
}

test_cleanup_process_probe_batching() {
    # shellcheck disable=SC1090
    source "$RUNTIME_DIR/lib/core/common.sh"
    # shellcheck disable=SC1090
    source "$RUNTIME_DIR/bin/app_runtime_guard.sh"

    local pgrep_calls=0 pgrep_pattern="" state=0
    pgrep() {
        pgrep_calls=$((pgrep_calls + 1))
        pgrep_pattern="${2:-}"
        return 1
    }

    MOLE_TEST_MODE=0 simplemole_any_process_state \
        node beam.smp "Google Chrome" 'tool+worker' || state=$?
    unset -f pgrep

    [[ "$state" -eq 1 ]] || fail "batched process probe did not report idle"
    [[ "$pgrep_calls" -eq 1 ]] || \
        fail "process guard launched pgrep $pgrep_calls times instead of once"
    [[ "$pgrep_pattern" == 'node|beam\.smp|Google Chrome|tool\+worker' ]] || \
        fail "process guard did not escape its combined pgrep pattern: $pgrep_pattern"

    local stub_dir="$TEST_ROOT/cleanup-runtime-stubs"
    local candidate="$TEST_ROOT/cleanup-runtime-target"
    local idle_candidate="$TEST_ROOT/cleanup-runtime-idle"
    local lsof_args="$TEST_ROOT/cleanup-runtime-lsof.args"
    local previous_path="$PATH"
    mkdir -p "$stub_dir" "$candidate" "$idle_candidate"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\n" "$*" >> "$SM_TEST_LSOF_ARGS"' \
        'if [[ "${SM_TEST_LSOF_ERROR:-0}" == "1" ]]; then printf "denied\n" >&2; exit 1; fi' \
        'printf "p1\nn%s/unrelated\np2\nn%s/open-file\n" "$SM_TEST_UNRELATED" "$SM_TEST_OPEN_ROOT"' \
        > "$stub_dir/lsof"
    chmod +x "$stub_dir/lsof"
    export PATH="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin"
    export SM_TEST_LSOF_ARGS="$lsof_args"
    export SM_TEST_UNRELATED="$TEST_ROOT/unrelated"
    export SM_TEST_OPEN_ROOT="$candidate"
    export SM_TEST_LSOF_ERROR=0
    : > "$lsof_args"

    state=0
    MOLE_TEST_MODE=0 simplemole_path_open_state "$candidate" || state=$?
    [[ "$state" -eq 0 ]] || fail "global lsof snapshot missed an open cleanup path"
    [[ "$(< "$lsof_args")" == '-nP -Fpn' ]] || \
        fail "cleanup path guard still uses recursive lsof: $(< "$lsof_args")"

    state=0
    MOLE_TEST_MODE=0 simplemole_path_open_state "$idle_candidate" || state=$?
    [[ "$state" -eq 1 ]] || fail "global lsof snapshot did not report an idle cleanup path"
    [[ "$(wc -l < "$lsof_args" | tr -d ' ')" -eq 1 ]] || \
        fail "cleanup path guard launched more than one lsof snapshot per batch"

    export SM_TEST_LSOF_ERROR=1
    SIMPLEMOLE_OPEN_SNAPSHOT_STATE="unprepared"
    SIMPLEMOLE_OPEN_SNAPSHOT_FILE=""
    : > "$lsof_args"
    state=0
    MOLE_TEST_MODE=0 simplemole_path_open_state "$candidate" || state=$?
    [[ "$state" -eq 2 ]] || fail "cleanup path guard did not fail closed on lsof error"

    # AI cleanup must inspect the selected cache subtree, not merely ask
    # whether any known AI/IDE process exists.  An unrelated active process
    # (simulated by pgrep below) must not suppress an idle cache; an open file
    # underneath that cache must still fail closed.
    local ai_home="$TEST_ROOT/ai-guard-home"
    local ai_target="$ai_home/.claude/statsig"
    local ai_trash="$TEST_ROOT/ai-guard-trash"
    local ai_plan="$TEST_ROOT/ai-guard-plan"
    local ai_log="$TEST_ROOT/ai-guard-deletions.log"
    local ai_output="" ai_identity="" ai_rc=0
    mkdir -p "$ai_target" "$ai_trash"
    printf 'cache\n' > "$ai_target/item"
    ai_identity=$(/usr/bin/stat -f '%d:%i:%m' "$ai_target")
    printf '%s\0%s\0' "$ai_target" "$ai_identity" > "$ai_plan"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$stub_dir/pgrep"
    chmod +x "$stub_dir/pgrep"
    export SM_TEST_LSOF_ERROR=0
    export SM_TEST_OPEN_ROOT="$TEST_ROOT/unrelated-ai-cache"
    ai_output=$(env HOME="$ai_home" PATH="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$ai_trash" \
        MOLE_DELETE_LOG="$ai_log" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$ai_plan") || \
        fail "AI cleanup let an unrelated active process block an idle cache: $ai_output"
    [[ ! -e "$ai_target" && "$ai_output" == *"removed=1"* ]] || \
        fail "AI cleanup did not remove an idle cache with an unrelated process active: $ai_output"

    mkdir -p "$ai_target"
    printf 'active cache\n' > "$ai_target/item"
    ai_identity=$(/usr/bin/stat -f '%d:%i:%m' "$ai_target")
    printf '%s\0%s\0' "$ai_target" "$ai_identity" > "$ai_plan"
    export SM_TEST_OPEN_ROOT="$ai_target"
    set +e
    ai_output=$(env HOME="$ai_home" PATH="$stub_dir:/usr/bin:/bin:/usr/sbin:/sbin" \
        MOLE_TEST_MODE=0 MOLE_TEST_NO_AUTH=1 MOLE_TEST_TRASH_DIR="$ai_trash" \
        MOLE_DELETE_LOG="$ai_log" MO_TIMEOUT_INITIALIZED=1 \
        MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_ai_apply.sh" < "$ai_plan" 2>&1)
    ai_rc=$?
    set -e
    [[ "$ai_rc" -ne 0 && -e "$ai_target/item" && "$ai_output" == *"failed=1"* ]] || \
        fail "AI cleanup ignored an open file in the selected cache: $ai_output"

    PATH="$previous_path"
    unset SM_TEST_LSOF_ARGS SM_TEST_UNRELATED SM_TEST_OPEN_ROOT SM_TEST_LSOF_ERROR
    pass "cleanup guards batch process and open-file probes without recursive lsof"
}

test_runtime_process_identity_binding() {
    local stub_dir="$TEST_ROOT/runtime-stubs"
    local signal_log="$TEST_ROOT/runtime-signals.log"
    local start="Wed_Aug_27_12:34:56_2026"
    local current_uid output rc
    current_uid="$(id -u)"
    mkdir -p "$stub_dir"

    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == "-axo" ]]; then' \
        '    case "$2" in' \
        '        pid=,ppid=,uid=,lstart=,state=,etime=,pcpu=,pmem=,comm=,args=)' \
        '            printf "4321 4100 %s Wed Aug 27 12:34:56 2026 S 00:10 1.2 0.3 /tmp/tool /tmp/tool --serve\\n" "${MOLE_TEST_UID}"' \
        '            ;;' \
        '        pid=,ppid=)' \
        '            [[ "${MOLE_TEST_TREE_PROBE_FAIL:-0}" != "1" ]] || exit 2' \
        '            printf "4100 1\\n4321 4100\\n4322 4321\\n"' \
        '            ;;' \
        '    esac' \
        'elif [[ "$1" == "-p" ]]; then' \
        '    pid="$2"' \
        '    second=56; ppid=4100; uid="${MOLE_TEST_STALE_UID:-${MOLE_TEST_UID}}"' \
        '    state="${MOLE_TEST_STALE_STATE:-S}"; comm="${MOLE_TEST_STALE_COMM:-/tmp/tool}"' \
        '    signal_count=0' \
        '    [[ -f "${MOLE_TEST_SIGNAL_LOG}" ]] && signal_count=$(wc -l < "${MOLE_TEST_SIGNAL_LOG}" | tr -d " ")' \
        '    if [[ "$pid" == "4100" ]]; then' \
        '        second=54; ppid=1; state=S; comm=/Applications/Parent.app/Contents/MacOS/Parent' \
        '    elif [[ "$pid" == "4322" ]]; then' \
        '        second=55; ppid=4321; state=S; comm=/tmp/child' \
        '    fi' \
        '    [[ "${MOLE_TEST_REUSED_PID:-}" == "$pid" ]] && second=57' \
        '    if [[ "$pid" == "4321" && "${MOLE_TEST_ZOMBIE_REAP:-0}" == "1" && "$signal_count" -ge 1 ]]; then exit 1; fi' \
        '    if [[ "$pid" == "4321" && "${MOLE_TEST_EXIT_AFTER_KILL:-0}" == "1" && "$signal_count" -ge 2 ]]; then exit 1; fi' \
        '    case "${4:-}" in' \
        '        lstart=) printf "Wed Aug 27 12:34:%s 2026\\n" "$second" ;;' \
        '        ppid=,uid=,lstart=,state=,comm=)' \
        '            printf "%s %s Wed Aug 27 12:34:%s 2026 %s %s\\n" "$ppid" "$uid" "$second" "$state" "$comm" ;;' \
        '    esac' \
        'fi' > "$stub_dir/ps"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ "${2:-}" == "ForgeSweep" && -n "${MOLE_TEST_FORGESWEEP_PID:-}" ]] && printf "%s\\n" "$MOLE_TEST_FORGESWEEP_PID"' \
        'exit 0' > "$stub_dir/pgrep"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >> "$MOLE_TEST_SIGNAL_LOG"' > "$stub_dir/kill"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "p4321\\nctool\\nn127.0.0.1:8080\\n"' > "$stub_dir/lsof"
    chmod +x "$stub_dir/ps" "$stub_dir/pgrep" "$stub_dir/kill" "$stub_dir/lsof"

    run_runtime_fixture() {
        env MOLE_TEST_MODE=1 \
            MOLE_TEST_PS_BIN="$stub_dir/ps" \
            MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
            MOLE_TEST_KILL_BIN="$stub_dir/kill" \
            MOLE_TEST_LSOF_BIN="$stub_dir/lsof" \
            MOLE_TEST_SIGNAL_LOG="$signal_log" \
            MOLE_TEST_UID="$current_uid" \
            MOLE_TEST_REUSED_PID="${MOLE_TEST_REUSED_PID:-}" \
            MOLE_TEST_FORGESWEEP_PID="${MOLE_TEST_FORGESWEEP_PID:-}" \
            MOLE_TEST_STALE_UID="${MOLE_TEST_STALE_UID:-}" \
            MOLE_TEST_STALE_STATE="${MOLE_TEST_STALE_STATE:-}" \
            MOLE_TEST_STALE_COMM="${MOLE_TEST_STALE_COMM:-}" \
            MOLE_TEST_ZOMBIE_REAP="${MOLE_TEST_ZOMBIE_REAP:-0}" \
            MOLE_TEST_EXIT_AFTER_KILL="${MOLE_TEST_EXIT_AFTER_KILL:-0}" \
            bash "$RUNTIME_DIR/bin/app_runtime.sh" "$@"
    }

    output=$(run_runtime_fixture processes) || fail "runtime process scan failed"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' '$1 == 4321 {print $2 ":" $3 ":" $4 ":" $5 ":" $6 ":" $9}')" == \
        "4100:$current_uid:$start:S:00:10:/tmp/tool" ]] || \
        fail "runtime scan omitted the safe process schema: $output"
    output=$(run_runtime_fixture ports) || fail "runtime port scan failed"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' '$1 == 8080 {print $2 ":" $3}')" == "4321:$start" ]] || \
        fail "runtime port scan omitted the stable process identity: $output"

    printf '' > "$signal_log"
    run_runtime_fixture kill-pid "4321|$start" >/dev/null || \
        fail "runtime kill-pid rejected a matching identity"
    [[ "$(sed -n '1p' "$signal_log")" == "-TERM 4321" ]] || \
        fail "runtime kill-pid did not signal the confirmed process"

    printf '' > "$signal_log"
    set +e
    output=$(MOLE_TEST_REUSED_PID=4321 run_runtime_fixture kill-pid "4321|$start" 2>&1)
    rc=$?
    set -e
    assert_status 4 "$rc" "runtime kill-pid accepted a reused PID"
    [[ ! -s "$signal_log" ]] || fail "runtime kill-pid signalled a reused PID"

    printf '' > "$signal_log"
    run_runtime_fixture kill-group "4321|$start" >/dev/null || \
        fail "runtime kill-group rejected a matching root identity"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-TERM 4322 -TERM 4321 " ]] || \
        fail "runtime kill-group did not signal the confirmed tree leaf-first"

    printf '' > "$signal_log"
    set +e
    output=$(MOLE_TEST_FORGESWEEP_PID=4322 run_runtime_fixture kill-group "4321|$start" 2>&1)
    rc=$?
    set -e
    assert_status 3 "$rc" "runtime kill-group accepted a tree containing ForgeSweep"
    [[ ! -s "$signal_log" ]] || fail "runtime kill-group signalled before self-protection completed"

    printf '' > "$signal_log"
    MOLE_TEST_STALE_STATE=Z MOLE_TEST_ZOMBIE_REAP=1 \
        run_runtime_fixture cleanup-stale "4321|$start|4100|$current_uid" >/dev/null || \
        fail "runtime cleanup-stale did not allow a safe zombie reap request"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-CHLD 4100 " ]] || \
        fail "runtime cleanup-stale signalled a zombie instead of notifying its parent"

    printf '' > "$signal_log"
    MOLE_TEST_STALE_STATE=Z MOLE_TEST_STALE_COMM='<defunct>' MOLE_TEST_ZOMBIE_REAP=1 \
        run_runtime_fixture cleanup-stale "4321|$start|4100|$current_uid" >/dev/null || \
        fail "runtime cleanup-stale rejected macOS defunct zombie output"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-CHLD 4100 " ]] || \
        fail "runtime cleanup-stale used an unsafe signal for defunct zombie output"

    printf '' > "$signal_log"
    set +e
    output=$(MOLE_TEST_STALE_STATE=Z run_runtime_fixture cleanup-stale \
        "4321|$start|4100|$current_uid" 2>&1)
    rc=$?
    set -e
    assert_status 6 "$rc" "runtime cleanup-stale did not report an unreaped zombie"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-CHLD 4100 " ]] || \
        fail "runtime cleanup-stale used a terminating signal for an unreaped zombie"

    printf '' > "$signal_log"
    MOLE_TEST_STALE_STATE=E MOLE_TEST_EXIT_AFTER_KILL=1 \
        run_runtime_fixture cleanup-stale "4321|$start|4100|$current_uid" >/dev/null || \
        fail "runtime cleanup-stale rejected a verified exiting process"
    [[ "$(tr '\n' ' ' < "$signal_log")" == "-TERM 4321 -KILL 4321 " ]] || \
        fail "runtime cleanup-stale did not escalate a persistent exiting process"

    assert_stale_rejected_without_signal() {
        local expected_status="$1" message="$2"
        shift 2
        printf '' > "$signal_log"
        set +e
        output=$(env "$@" bash "$RUNTIME_DIR/bin/app_runtime.sh" cleanup-stale \
            "4321|$start|4100|${MOLE_TEST_TOKEN_UID:-$current_uid}" 2>&1)
        rc=$?
        set -e
        assert_status "$expected_status" "$rc" "$message"
        [[ ! -s "$signal_log" ]] || fail "$message emitted a signal"
    }

    assert_stale_rejected_without_signal 5 "runtime cleanup-stale accepted a normal process" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=S

    MOLE_TEST_TOKEN_UID=$((current_uid + 1)) \
        assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted another user's process" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_UID=$((current_uid + 1)) MOLE_TEST_STALE_STATE=E
    unset MOLE_TEST_TOKEN_UID

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted a system executable" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_STALE_COMM=/System/Library/CoreServices/tool

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted a reused PID" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_REUSED_PID=4321

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale accepted the ForgeSweep tree" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_FORGESWEEP_PID=4321

    assert_stale_rejected_without_signal 3 "runtime cleanup-stale ignored an unavailable self-tree probe" \
        MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" MOLE_TEST_PGREP_BIN="$stub_dir/pgrep" \
        MOLE_TEST_KILL_BIN="$stub_dir/kill" MOLE_TEST_SIGNAL_LOG="$signal_log" MOLE_TEST_UID="$current_uid" \
        MOLE_TEST_STALE_STATE=E MOLE_TEST_TREE_PROBE_FAIL=1

    pass "runtime PID binding, stale-state cleanup, and process-tree protection"
}

test_netmon_bridge() {
    local helper="$RUNTIME_DIR/bin/app_netmon.sh"
    local stub_dir="$TEST_ROOT/netmon-stub"
    local fixture_cfg="$TEST_ROOT/netmon-clash.yaml"
    local output="" rc=0

    mkdir -p "$stub_dir"

    # nettop：空格/点号进程名和 PID 数字后缀必须分开处理。
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "time\\tinterface\\tstate\\tbytes_in\\tbytes_out\\n"' \
        'printf "10:00:00.000001 launchd.1\\t\\t\\t0\\t0\\t0\\t0\\t0\\n"' \
        'printf "10:00:00.000002 Google Chrome Helper.123\\t\\t\\t100\\t200\\t0\\t0\\t0\\n"' \
        'printf "10:00:00.000003 kernel_task.0\\t\\t\\t9\\t9\\t0\\t0\\t0\\n"' \
        'printf "10:00:00.000004 weird.pidX\\t\\t\\t1\\t2\\n"' \
        'printf "10:00:00.000005 com.apple.WebKit.456\\t\\t\\t300\\t400\\n"' \
        'printf "10:00:00.000006 worker.2.789\\t\\t\\t500\\t600\\n"' \
        > "$stub_dir/nettop"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        '[[ " $* " == *" -FpcnP "* ]] || exit 2' \
        'printf "p1131\\ncD-Chat\\nf10\\nPTCP\\nn127.0.0.1:1->221.229.52.251:80\\n"' \
        'printf "p1138\\ncTencentMeeting\\nf20\\nPUDP\\nn[fe80::1]:1->[2606:4700::1]:8080\\n"' \
        'printf "p999\\ncListener\\nf30\\nPTCP\\nn*:9090\\n"' \
        > "$stub_dir/lsof"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [[ "$1" == "-n" ]]; then shift; fi' \
        'if [[ "${1:-}" == "get" ]]; then' \
        '    address="${@: -1}"' \
        '    if [[ "$address" == "8.8.8.8" ]]; then printf "   interface: en0\\n"' \
        '    elif [[ "$address" == "2606:4700::1" ]]; then exit 0' \
        '    else printf "   interface: utun9\\n"; fi' \
        'fi' \
        > "$stub_dir/route"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >> "$MOLE_TEST_CURL_ARGS"' \
        'cat "${MOLE_TEST_CURL_BODY:-/dev/null}"' \
        > "$stub_dir/curl"
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'printf "/Applications/Clash Verge.app/Contents/MacOS/verge-mihomo -d /tmp/verge-data -f %s -ext-ctl-unix /tmp/verge/verge-mihomo.sock\\n" "$MOLE_TEST_CLASH_CFG"' \
        > "$stub_dir/ps"
    printf '%s\n' \
        "external-controller: ''" \
        'external-controller-unix: /tmp/verge/verge-mihomo.sock' \
        'secret: testsecret' \
        'mixed-port: 7897' \
        'socks-port: 7891' \
        'port: 7890' \
        > "$fixture_cfg"
    chmod +x "$stub_dir"/*

    output=$(env MOLE_TEST_MODE=1 MOLE_TEST_NETTOP_BIN="$stub_dir/nettop" \
        bash "$helper" bytes) || fail "netmon bytes mode failed"
    [[ "$output" == *"proc"$'\t'"123"$'\t'"100"$'\t'"200"$'\t'"Google Chrome Helper"* ]] || \
        fail "netmon bytes dropped the spaced process name: $output"
    [[ "$output" == *"proc"$'\t'"1"$'\t'"0"$'\t'"0"$'\t'"launchd"* ]] || \
        fail "netmon bytes dropped the pid-1 daemon row: $output"
    [[ "$output" != *"kernel_task"* && "$output" != *"weird"* ]] || \
        fail "netmon bytes accepted invalid pid rows: $output"
    [[ "$output" == *"proc"$'\t'"456"$'\t'"300"$'\t'"400"$'\t'"com.apple.WebKit"* ]] || \
        fail "netmon bytes dropped the dotted process name: $output"
    [[ "$output" == *"proc"$'\t'"789"$'\t'"500"$'\t'"600"$'\t'"worker.2"* ]] || \
        fail "netmon bytes used a process-name component as PID: $output"

    output=$(env MOLE_TEST_MODE=1 MOLE_TEST_LSOF_BIN="$stub_dir/lsof" \
        bash "$helper" flows) || fail "netmon flows mode failed"
    [[ "$output" == *"flow"$'\t'"1131"$'\t'"D-Chat"$'\t'"TCP"$'\t'"127.0.0.1:1"$'\t'"221.229.52.251:80"* ]] || \
        fail "netmon flows lost the connected TCP row: $output"
    [[ "$output" == *"UDP"$'\t'"[fe80::1]:1"$'\t'"[2606:4700::1]:8080"* ]] || \
        fail "netmon flows lost the UDP protocol or IPv6 endpoint: $output"
    [[ "$output" != *":9090"* ]] || fail "netmon flows kept a listener row: $output"

    output=$(printf '8.8.8.8\n2606:4700::1\nnot-an-ip\n10.0.0.1\n' \
        | env MOLE_TEST_MODE=1 MOLE_TEST_ROUTE_BIN="$stub_dir/route" \
            bash "$helper" routes) || fail "netmon routes mode failed"
    [[ "$output" == *"route"$'\t'"8.8.8.8"$'\t'"en0"* ]] || \
        fail "netmon routes missed the en0 lookup: $output"
    [[ "$output" == *"route"$'\t'"2606:4700::1"$'\t'"unknown"* ]] || \
        fail "netmon routes did not fail closed on unrouted v6: $output"
    [[ "$output" == *"route"$'\t'"10.0.0.1"$'\t'"utun9"* ]] || \
        fail "netmon routes missed the utun lookup: $output"
    [[ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" == "3" ]] || \
        fail "netmon routes accepted a non-address line: $output"

    output=$(env MOLE_TEST_MODE=1 MOLE_TEST_CURL_BIN="$stub_dir/curl" \
        MOLE_TEST_CURL_ARGS="$TEST_ROOT/netmon-curl-args" \
        CLASH_ENDPOINT="unix:/tmp/verge/verge-mihomo.sock" \
        CLASH_SECRET="s3cr3t" \
        MOLE_TEST_CURL_BODY="$TEST_ROOT/netmon-curl-body" \
        bash -c 'printf "{\"version\":\"test\"}" > "$MOLE_TEST_CURL_BODY"; bash "$0" clash' "$helper") || \
        fail "netmon clash mode failed"
    [[ "$output" == '{"version":"test"}' ]] || \
        fail "netmon clash did not pass the controller body through: $output"
    grep -Fq -- "--unix-socket /tmp/verge/verge-mihomo.sock" "$TEST_ROOT/netmon-curl-args" || \
        fail "netmon clash did not use the unix socket"
    grep -Fq -- "Authorization: Bearer s3cr3t" "$TEST_ROOT/netmon-curl-args" || \
        fail "netmon clash did not send the bearer secret"

    set +e
    output=$(env MOLE_TEST_MODE=1 bash "$helper" clash 2>/dev/null)
    rc=$?
    set -e
    assert_status 2 "$rc" "clash mode without an endpoint did not fail closed"

    output=$(env MOLE_TEST_MODE=1 MOLE_TEST_PS_BIN="$stub_dir/ps" \
        MOLE_TEST_CLASH_CFG="$fixture_cfg" \
        bash "$helper" discover) || fail "netmon discover mode failed"
    [[ "$output" == *"endpoint"$'\t'"unix:/tmp/verge/verge-mihomo.sock"* ]] || \
        fail "netmon discover lost the unix endpoint: $output"
    [[ "$output" == *"secret"$'\t'"testsecret"* ]] || \
        fail "netmon discover lost the controller secret: $output"
    [[ "$output" == *"mixedport"$'\t'"7897"* ]] || \
        fail "netmon discover lost the mixed port: $output"
    [[ "$output" == *"proxyport"$'\t'"7897"* \
        && "$output" == *"proxyport"$'\t'"7891"* \
        && "$output" == *"proxyport"$'\t'"7890"* ]] || \
        fail "netmon discover lost a configured proxy port: $output"
    [[ "$output" != *"mixedport"$'\t'"7891"* && "$output" != *"mixedport"$'\t'"7890"* ]] || \
        fail "netmon discover mislabeled HTTP/SOCKS ports as mixed ports: $output"
    [[ "$output" != *"endpoint"$'\t'"http:"* ]] || \
        fail "netmon discover invented a TCP endpoint from an empty controller"

    set +e
    output=$(env MOLE_TEST_MODE=1 bash "$helper" bogus-mode 2>/dev/null)
    rc=$?
    set -e
    assert_status 2 "$rc" "netmon unknown mode did not fail closed"

    pass "netmon bridge byte, flow, route, clash and discovery contracts"
}

test_dev_env_current_version_lock() {
    local home="$TEST_ROOT/env-home"
    local current="$home/.nvm/versions/node/v20.1.0"
    local old="$home/.nvm/versions/node/v18.2.0"
    local latest="$home/.nvm/versions/node/v22.3.0"
    local output
    mkdir -p "$current" "$old" "$latest" \
        "$home/.nvm/alias/lts" "$home/.nvm/alias/release"
    mkdir -p "$old/lib/node_modules/typescript"
    printf 'global package' > "$old/lib/node_modules/typescript/package.json"
    printf 'lts/krypton\n' > "$home/.nvm/alias/lts/*"
    printf 'v20.1.0\n' > "$home/.nvm/alias/lts/krypton"
    printf 'release/team\n' > "$home/.nvm/alias/work"
    printf 'lts/krypton\n' > "$home/.nvm/alias/release/team"

    assert_nvm_alias_locked() {
        local alias="$1" expected="$2" expected_path
        expected_path="$home/.nvm/versions/node/$expected"
        printf '%s\n' "$alias" > "$home/.nvm/alias/default"
        output=$(env HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin MOLE_TEST_NVM_ONLY=1 \
            bash "$RUNTIME_DIR/bin/app_env_scan.sh") || fail "nvm alias scan failed for $alias"
        [[ "$(printf '%s\n' "$output" | awk -F '\t' -v path="$expected_path" \
            '$4 == path { count++; kind=$2 } END { print count ":" kind }')" == "1:current" ]] || \
            fail "nvm alias $alias did not uniquely lock $expected: $output"
        [[ "$(printf '%s\n' "$output" | awk -F '\t' '$2 == "current" {count++} END {print count+0}')" == "1" ]] || \
            fail "nvm alias $alias produced more than one current version: $output"
    }

    assert_nvm_alias_locked "v20.1.0" "v20.1.0"
    assert_nvm_alias_locked "20" "v20.1.0"
    assert_nvm_alias_locked "node" "v22.3.0"
    assert_nvm_alias_locked "stable" "v22.3.0"
    assert_nvm_alias_locked "lts/*" "v20.1.0"
    assert_nvm_alias_locked "lts/krypton" "v20.1.0"
    assert_nvm_alias_locked "work" "v20.1.0"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' -v path="$old" '$4 == path { print $2; exit }')" == "runtime" ]] || \
        fail "non-current nvm version was not selectable"
    [[ "$(printf '%s\n' "$output" | awk -F '\t' -v path="$old" \
        '$4 == path { print ((($5 + 0) > 0 && $6 == path "/lib/node_modules") ? "linked" : "missing"); exit }')" == "linked" ]] || \
        fail "nvm global node_modules were not linked to their version: $output"
    pass "development environment current-version lock"
}

test_nvm_delete_time_guard() {
    local home="$TEST_ROOT/nvm-guard-home"
    local trash="$TEST_ROOT/nvm-guard-trash"
    local plan="$TEST_ROOT/nvm-guard-plan"
    local current="$home/.nvm/versions/node/v20.1.0"
    local old="$home/.nvm/versions/node/v18.2.0"
    local identity output rc
    mkdir -p "$current/bin" "$old/bin" "$home/.nvm/alias" "$trash"
    printf '#!/bin/sh\nexit 0\n' > "$old/bin/node"
    chmod +x "$old/bin/node"
    identity=$(/usr/bin/stat -f '%d:%i:%m' "$old")
    printf '%s\0%s\0' "$old" "$identity" > "$plan"

    run_nvm_apply_fixture() {
        env HOME="$home" PATH="${NVM_TEST_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" \
            MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
            MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/nvm-guard-deletions.log" \
            MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
            bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan"
    }

    # The preview selected an old version, but default changed before apply.
    printf 'v18.2.0\n' > "$home/.nvm/alias/default"
    set +e
    output=$(run_nvm_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -d "$old" && "$output" == *"failed=1"* ]] || \
        fail "delete-time guard accepted the fresh nvm default: $output"

    # The default is elsewhere, but the selected version now backs active node.
    printf 'v20.1.0\n' > "$home/.nvm/alias/default"
    set +e
    output=$(NVM_TEST_PATH="$old/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        run_nvm_apply_fixture 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && -d "$old" && "$output" == *"failed=1"* ]] || \
        fail "delete-time guard accepted the fresh active nvm version: $output"

    # An identity-bound version that is neither fresh default nor active remains deletable.
    output=$(run_nvm_apply_fixture) || fail "delete-time guard rejected an inactive nvm version"
    [[ ! -e "$old" && "$output" == *"removed=1"* && "$output" == *"failed=0"* ]] || \
        fail "delete-time guard returned unexpected counters for an inactive version: $output"
    pass "nvm delete-time default and active version guard"
}

test_owner_managed_runtimes_readonly() {
    local home="$TEST_ROOT/owner-runtime-home"
    local trash="$TEST_ROOT/owner-runtime-trash"
    local plan="$TEST_ROOT/owner-runtime-plan"
    local output path identity kind rc
    local -a paths=(
        "$home/Library/Application Support/fnm/node-versions/v20.1.0/installation"
        "$home/.volta/tools/image/node/20.1.0"
        "$home/.asdf/installs/node/20.1.0"
        "$home/.pyenv/versions/3.12.1"
        "$home/.rbenv/versions/3.3.1"
        "$home/.rustup/toolchains/stable-aarch64-apple-darwin"
    )

    mkdir -p "$trash"
    for path in "${paths[@]}"; do mkdir -p "$path"; done

    output=$(env HOME="$home" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
        FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        bash "$RUNTIME_DIR/bin/app_env_scan.sh") || \
        fail "owner-managed runtime scan failed"
    for path in "${paths[@]}"; do
        kind=$(printf '%s\n' "$output" | awk -F '\t' -v path="$path" \
            '$4 == path { count++; kind=$2 } END { print count ":" kind }')
        [[ "$kind" == "1:manager" ]] || \
            fail "owner-managed runtime was not uniquely read-only: $path ($kind)"
    done

    : > "$plan"
    for path in "${paths[@]}"; do
        identity=$(/usr/bin/stat -f '%d:%i:%m' "$path")
        printf '%s\0%s\0' "$path" "$identity" >> "$plan"
    done
    set +e
    output=$(env HOME="$home" MOLE_TEST_MODE=1 MOLE_TEST_NO_AUTH=1 \
        MOLE_TEST_TRASH_DIR="$trash" MOLE_DELETE_LOG="$TEST_ROOT/owner-runtime-deletions.log" \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_apply.sh" < "$plan" 2>&1)
    rc=$?
    set -e
    [[ "$rc" -ne 0 && "$output" == *"removed=0"* && "$output" == *"failed=6"* ]] || \
        fail "apply sink accepted an owner-managed runtime path: $output"
    for path in "${paths[@]}"; do
        [[ -d "$path" ]] || fail "apply sink removed an owner-managed runtime: $path"
    done
    pass "owner-managed runtimes are read-only at scan and apply"
}

test_slim_scan_exclusivity() {
    local home="$TEST_ROOT/slim-home"
    local first="$home/Pictures/first image.png"
    local second="$home/Pictures/second image.png"
    local output
    mkdir -p "$home/Pictures" "$home/Desktop" "$home/Downloads"
    dd if=/dev/zero of="$first" bs=1048576 count=3 >/dev/null 2>&1
    cp "$first" "$second"

    output=$(env HOME="$home" TMPDIR="$TEST_ROOT" FORGESWEEP_FULL_DISK_AUTHORIZED=1 \
        MO_TIMEOUT_INITIALIZED=1 MO_TIMEOUT_BIN= MO_TIMEOUT_PERL_BIN= \
        bash "$RUNTIME_DIR/bin/app_slim_scan.sh") || fail "slim scan failed"
    printf '%s\n' "$output" | awk -F '\t' '
        NF >= 3 {
            separator = index($3, "|")
            if (separator == 0) next
            operation = substr($3, 1, separator - 1)
            path = substr($3, separator + 1)
            if (operation == "duplicate") { duplicate[path] = 1; duplicate_count++ }
            if (operation == "compress") { compress[path] = 1; compress_count++ }
        }
        END {
            if (duplicate_count != 1 || compress_count != 1) exit 2
            for (path in duplicate) if (compress[path]) exit 3
        }
    ' || fail "slim scan scheduled duplicate and compress for the same path"
    pass "slim scan action exclusivity"
}

test_auto_cleanup_planner() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Auto-cleanup planner tests skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi

    local arch="$(uname -m)"
    local binary="$TEST_ROOT/auto-cleanup-planner-tests"
    local module_cache="$TEST_ROOT/auto-cleanup-planner-module-cache"
    AUTO_CLEANUP_FIXTURE=$(mktemp -d "$ROOT_DIR/.auto-cleanup-planner-tests.XXXXXX") || \
        fail "create auto-cleanup planner fixture"
    mkdir -p "$module_cache"

    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/AutoCleanup.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/AutoCleanupPlannerTests.swift" \
        -o "$binary" || fail "compile auto-cleanup planner tests"
    "$binary" "$AUTO_CLEANUP_FIXTURE" || fail "auto-cleanup planner tests"

    rm -rf -- "$AUTO_CLEANUP_FIXTURE"
    AUTO_CLEANUP_FIXTURE=""
    pass "auto-cleanup planner policies, symlink guard and persistence"
}

test_cleanup_risk_policy() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Cleanup risk policy tests skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi

    local arch="$(uname -m)"
    local binary="$TEST_ROOT/cleanup-risk-tests"
    local module_cache="$TEST_ROOT/cleanup-risk-module-cache"
    local fixture="$TEST_ROOT/cleanup-risk-fixture"
    mkdir -p "$module_cache" "$fixture"

    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        "$ROOT_DIR/SimpleMole/Models.swift" \
        "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
        "$ROOT_DIR/SimpleMole/Services/Parsers.swift" \
        "$ROOT_DIR/SimpleMole/Services/CleanupCache.swift" \
        "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
        "$ROOT_DIR/script/CleanupRiskPolicyTests.swift" \
        -o "$binary" || fail "compile cleanup risk policy tests"
    "$binary" "$fixture" || fail "cleanup risk policy tests"
    pass "cleanup risk defaults, routes, runtime guards and cache persistence"
}

test_inventory_components() {
    SM_TEST_SKIP_SWIFT="${SM_TEST_SKIP_SWIFT:-0}" \
        bash "$ROOT_DIR/script/test_inventory.sh" || fail "simulator and Docker inventory tests"
    pass "simulator and Docker inventory safety contracts"
}

test_project_automation() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
        local arch binary module_cache
        arch="$(uname -m)"
        binary="$TEST_ROOT/project-automation-tests"
        module_cache="$TEST_ROOT/project-automation-module-cache"
        mkdir -p "$module_cache"
        swiftc -target "$arch-apple-macos13.0" \
            -module-cache-path "$module_cache" \
            -DPROJECT_RADAR_PARSER_TESTS -DPROJECT_HIBERNATION_PARSER_TESTS \
            "$ROOT_DIR/SimpleMole/Models.swift" \
            "$ROOT_DIR/SimpleMole/Services/DeletionPlan.swift" \
            "$ROOT_DIR/SimpleMole/Services/CleanupRiskPolicy.swift" \
            "$ROOT_DIR/SimpleMole/Services/AutomationPolicy.swift" \
            "$ROOT_DIR/SimpleMole/Services/SavedScanLocation.swift" \
            "$ROOT_DIR/SimpleMole/Services/AutomationStore.swift" \
            "$ROOT_DIR/SimpleMole/Services/SmartTriggerEvaluator.swift" \
            "$ROOT_DIR/SimpleMole/Services/ProjectRadar.swift" \
            "$ROOT_DIR/SimpleMole/Services/ProjectHibernation.swift" \
            "$ROOT_DIR/script/CleanupRiskTestL10nStub.swift" \
            "$ROOT_DIR/script/ProjectAutomationTests.swift" \
            -o "$binary" || fail "compile project automation tests"
        "$binary" || fail "project automation Swift tests"
    fi
    bash "$ROOT_DIR/script/ProjectAutomationBridgeTests.sh" || \
        fail "project automation bridge tests"
    pass "project radar, hibernation, restore and typed automation contracts"
}

test_cleanup_execution_accounting() {
    local apply_source installer_source
    apply_source=$(sed -n '/private func performApply(/,/private func reportCleanupResult/p' \
        "$ROOT_DIR/SimpleMole/AppState.swift")
    if printf '%s\n' "$apply_source" | grep -Fq 'cleanupScanComplete = false'; then
        fail "partial cleanup invalidates the scan and disables retry"
    fi
    installer_source=$(sed -n '/func applyInstallers()/,/func applyCleanup()/p' \
        "$ROOT_DIR/SimpleMole/AppState.swift")
    printf '%s\n' "$installer_source" | grep -Fq 'permanently: true' || \
        fail "reviewed installer cleanup does not request permanent deletion"
    printf '%s\n' "$installer_source" | grep -Fq 'cleanup.installers.confirm' || \
        fail "installer cleanup lacks an explicit permanent-deletion confirmation"
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Cleanup execution accounting tests skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi
    local arch binary module_cache
    arch="$(uname -m)"
    binary="$TEST_ROOT/cleanup-execution-tests"
    module_cache="$TEST_ROOT/cleanup-execution-module-cache"
    mkdir -p "$module_cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$module_cache" \
        "$ROOT_DIR/SimpleMole/Services/CleanupExecutionResult.swift" \
        "$ROOT_DIR/script/CleanupExecutionTests.swift" \
        -o "$binary" || fail "compile cleanup execution accounting tests"
    "$binary" || fail "cleanup execution accounting tests"
    pass "cleanup execution removed, skipped, and failed accounting"
}

test_clipboard_history() {
    local arch binary
    arch="$(uname -m)"
    binary="$TEST_ROOT/clipboard-history-tests"
    mkdir -p "$TEST_ROOT/clipboard-module-cache"
    swiftc -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/clipboard-module-cache" \
        -framework AppKit -framework Combine \
        "$ROOT_DIR/SimpleMole/Services/ClipboardHistoryManager.swift" \
        "$ROOT_DIR/script/ClipboardHistoryTests.swift" \
        -o "$binary" || fail "clipboard history tests compile"
    "$binary" || fail "clipboard history retention and pinning"
    pass "clipboard history retention and pinning"
}

test_swift() {
    if [[ "${SM_TEST_SKIP_SWIFT:-0}" == "1" ]]; then
        printf 'ok - Swift typecheck skipped (SM_TEST_SKIP_SWIFT=1)\n'
        return
    fi

    local arch
    local swift_sources=(
        "$ROOT_DIR"/SimpleMole/*.swift
        "$ROOT_DIR"/SimpleMole/L10n/*.swift
        "$ROOT_DIR"/SimpleMole/Services/*.swift
        "$ROOT_DIR"/SimpleMole/Views/*.swift
    )
    arch="$(uname -m)"
    mkdir -p "$TEST_ROOT/swift-module-cache"
    swiftc -typecheck -target "$arch-apple-macos13.0" \
        -module-cache-path "$TEST_ROOT/swift-module-cache" \
        -framework Cocoa -framework SwiftUI -framework Security -framework CryptoKit -framework IOKit \
        "${swift_sources[@]}" || fail "Swift typecheck"
    pass "Swift typecheck"

    if [[ "${SM_TEST_BUILD:-0}" == "1" ]]; then
        GOPROXY=off SM_BUILD_ARCHS="${SM_TEST_BUILD_ARCHS:-$arch}" \
            SM_CODESIGN_IDENTITY="${SM_TEST_CODESIGN_IDENTITY:--}" SM_ALLOW_ADHOC=1 \
            "$ROOT_DIR/script/build.sh" || fail "app build"
        for built_arch in ${SM_TEST_BUILD_ARCHS:-$arch}; do
            codesign --verify --deep --strict "$ROOT_DIR/dist/$built_arch/ForgeSweep.app" || \
                fail "app code signature ($built_arch)"
        done
        pass "app build and code signature"
    fi
}

printf 'ForgeSweep local regression tests\n'
test_shell_syntax
if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
    bash "$ROOT_DIR/script/test_cleanup_scan.sh" || fail "native cleanup scan tests"
fi
test_native_core_ownership_contract
test_plists
test_brand_contract
test_tab_motion_contract
test_control_motion_contract
test_header_layout_contract
test_process_icon_contract
test_productivity_feature_contract
stage_bridge_runtime
test_timeout_fallback
test_scan_access_boundary
test_xcode_scan_boundary
test_developer_scan_boundary
test_analyze_ai_inventory
test_system_preview_protocol
test_signing_policy_contract
test_gc_runner
test_node_cache_inventory
test_identity_bound_apply
test_auto_cleanup_apply
test_installer_apply
test_packaged_apply_layout
test_special_apply_identity_binding
test_uninstall_space_breakdown
test_native_cask_uninstall_contract
test_uninstall_queue
test_cleanup_process_probe_batching
test_runtime_process_identity_binding
test_runtime_store_aggregation
test_netmon_bridge
if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
    bash "$ROOT_DIR/script/test_traffic.sh" || fail "traffic accounting and app attribution"
    pass "traffic accounting, app attribution and descending rankings"
fi
test_dev_env_current_version_lock
test_nvm_delete_time_guard
test_owner_managed_runtimes_readonly
test_slim_scan_exclusivity
test_auto_cleanup_planner
test_cleanup_risk_policy
test_cleanup_execution_accounting
test_inventory_components
test_project_automation
test_clipboard_history
test_swift
printf 'All %d checks passed.\n' "$PASSED"
