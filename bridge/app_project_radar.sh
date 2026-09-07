#!/bin/bash
# Read-only project and generated-artifact inventory.
# Input roots and output records are NUL-delimited.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/../lib/core/common.sh"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/../lib/clean/purge_shared.sh"
source "$SCRIPT_DIR/app_scan_access.sh"

SM_ARTIFACT_RISK="protected"
SM_ARTIFACT_KIND="unknown"
SM_PROJECT_RADAR_TEMP_ROOT=""

sm_project_radar_cleanup() {
    case "${SM_PROJECT_RADAR_TEMP_ROOT:-}" in
        "${TMPDIR:-/tmp}"/simple-mole-radar.*)
            rm -rf "$SM_PROJECT_RADAR_TEMP_ROOT"
            ;;
    esac
    SM_PROJECT_RADAR_TEMP_ROOT=""
}

sm_project_emit() {
    local field
    for field in "$@"; do printf '%s\0' "$field"; done
}

sm_project_path_syntax_safe() {
    local path="${1:-}"
    [[ "$path" == /* && "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
    case "$path" in
        *'/../'* | */.. | *'/./'* | */. | *'//'*) return 1 ;;
    esac
    return 0
}

sm_project_real_directory() {
    local path="${1:-}"
    while [[ "$path" != "/" && "$path" == */ ]]; do path="${path%/}"; done
    sm_project_path_syntax_safe "$path" || return 1
    [[ -d "$path" && ! -L "$path" ]] || return 1
    local physical=""
    physical=$(cd -P "$path" 2>/dev/null && /bin/pwd -P) || return 1
    [[ "$physical" == "$path" ]] || return 1
    printf '%s\n' "$physical"
}

sm_project_root_identity() {
    "$STAT_BSD" -f%d:%i "$1" 2>/dev/null
}

sm_project_file_identity() {
    "$STAT_BSD" -f%d:%i:%m "$1" 2>/dev/null
}

sm_project_is_root() {
    local root="$1"
    mole_purge_is_project_root "$root"
}

sm_has_manifest_between() {
    local artifact="$1"
    local root="$2"
    local group="$3"
    local dir="${artifact%/*}"
    local entry
    while [[ "$dir" == "$root" || "$dir" == "$root/"* ]]; do
        case "$group" in
            javascript)
                [[ -f "$dir/package.json" ]] && return 0
                ;;
            rust-maven)
                [[ -f "$dir/Cargo.toml" || -f "$dir/pom.xml" ]] && return 0
                ;;
            gradle)
                [[ -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ||
                   -f "$dir/settings.gradle" || -f "$dir/settings.gradle.kts" ]] && return 0
                ;;
            swift)
                [[ -f "$dir/Package.swift" ]] && return 0
                ;;
            dart)
                [[ -f "$dir/pubspec.yaml" ]] && return 0
                ;;
            zig)
                [[ -f "$dir/build.zig" || -f "$dir/build.zig.zon" ]] && return 0
                ;;
            dotnet)
                for entry in "$dir"/*.csproj "$dir"/*.fsproj "$dir"/*.vbproj; do
                    [[ -f "$entry" ]] && return 0
                done
                ;;
            python)
                [[ -f "$dir/pyproject.toml" || -f "$dir/requirements.txt" ||
                   -f "$dir/setup.py" || -f "$dir/setup.cfg" ]] && return 0
                ;;
            any)
                sm_project_is_root "$dir" && return 0
                ;;
        esac
        [[ "$dir" == "$root" ]] && break
        dir="${dir%/*}"
        [[ -n "$dir" ]] || break
    done
    return 1
}

sm_project_contains_protected_content() {
    local path="$1"
    local found=""
    # Never cap this walk: a model or session nested below a build cache is
    # still Protected. Any incomplete traversal also fails closed.
    found=$(command find "$path" \( \
        -name .git -o \
        -path '*/.codex/sessions' -o -path '*/.codex/log' -o \
        -path '*/.codex/auth.json' -o -path '*/.codex/history.jsonl' -o \
        -path '*/.claude/projects' -o -path '*/.claude/todos' -o \
        -path '*/.claude/shell-snapshots' -o \
        -path '*/.local/share/opencode/project' -o -path '*/.gemini' -o \
        -path '*/.ollama/models' -o -path '*/.cache/huggingface' -o \
        -path '*/.cache/lm-studio/models' -o -path '*/.cache/torch' -o \
        -iname 'models' -o -iname 'sessions' -o -iname 'conversations' -o \
        -iname 'userdata' -o -iname 'user data' -o -iname 'docker' -o \
        -iname '.docker' -o -iname 'vms' -o \
        -iname '*.gguf' -o -iname '*.safetensors' -o -iname '*.ckpt' -o \
        -iname '*.mlmodel' -o -iname '*.mlmodelc' -o -iname '*.pt' -o \
        -iname '*.pth' -o -iname '*.onnx' -o -iname '*.tflite' -o \
        -iname 'pytorch_model.bin' -o -iname 'adapter_model.bin' -o \
        -iname 'model.bin' -o -iname 'Docker.raw' -o -iname 'Docker.qcow2' \
        \) -print -quit 2>/dev/null) || return 0
    [[ -n "$found" ]]
}

sm_cachedir_tag_valid() {
    local path="$1"
    mole_dir_has_cachedir_tag "$path"
}

sm_project_find_literal_pattern() {
    local pattern="$1"
    pattern="${pattern//\\/\\\\}"
    pattern="${pattern//\*/\\*}"
    pattern="${pattern//\?/\\?}"
    pattern="${pattern//\[/\\[}"
    printf '%s\n' "$pattern"
}

# Classifies only known generated directories. It sets SM_ARTIFACT_RISK and
# SM_ARTIFACT_KIND; callers must still verify identity, activity and Trash.
sm_project_classify_artifact() {
    local path="$1"
    local root="$2"
    local base="${path##*/}"
    SM_ARTIFACT_RISK="protected"
    SM_ARTIFACT_KIND="unknown"

    # Dependency trees stay Warning even when a nested tool writes CACHEDIR.TAG.
    # Their restore can require network access or lockfile-specific tooling.
    if [[ "$base" == "node_modules" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyNodeModules"
    elif [[ "$base" == "Pods" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyPods"
    elif [[ "$base" == "vendor" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyComposer"
    elif [[ "$base" == "venv" || "$base" == ".venv" ||
            "$base" == ".tox" || "$base" == ".nox" ]]; then
        SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="dependencyVirtualEnv"
    elif sm_cachedir_tag_valid "$path"; then
        SM_ARTIFACT_RISK="safe"
        SM_ARTIFACT_KIND="cacheTag"
    else
        case "$base" in
            .pytest_cache|.mypy_cache|.ruff_cache|__pycache__)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="pythonCache"
                ;;
            .turbo|.parcel-cache|.next|.nuxt|.output|.svelte-kit|.astro|.angular)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="javascriptCache"
                sm_has_manifest_between "$path" "$root" javascript || SM_ARTIFACT_RISK="warning"
                ;;
            target)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="rustTarget"
                sm_has_manifest_between "$path" "$root" rust-maven || SM_ARTIFACT_RISK="warning"
                ;;
            .gradle|.terragrunt-cache)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="javaCache"
                if [[ "$base" == .gradle ]]; then
                    sm_has_manifest_between "$path" "$root" gradle || SM_ARTIFACT_RISK="warning"
                fi
                ;;
            .build)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="swiftBuild"
                sm_has_manifest_between "$path" "$root" swift || SM_ARTIFACT_RISK="warning"
                ;;
            .dart_tool)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="dartCache"
                sm_has_manifest_between "$path" "$root" dart || SM_ARTIFACT_RISK="warning"
                ;;
            .zig-cache|zig-out)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="zigCache"
                sm_has_manifest_between "$path" "$root" zig || SM_ARTIFACT_RISK="warning"
                ;;
            .cxx)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="nativeBuildCache"
                sm_has_manifest_between "$path" "$root" gradle || SM_ARTIFACT_RISK="warning"
                ;;
            obj)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="nativeBuildCache"
                sm_has_manifest_between "$path" "$root" dotnet || SM_ARTIFACT_RISK="warning"
                ;;
            coverage)
                SM_ARTIFACT_RISK="safe"; SM_ARTIFACT_KIND="coverage"
                ;;
            build|dist|out|bin)
                SM_ARTIFACT_RISK="warning"; SM_ARTIFACT_KIND="genericBuildOutput"
                ;;
        esac
    fi

    if [[ "$path" == "$root" || "$path" == "$root/.git" || "$path" == "$root/.git/"* ]]; then
        SM_ARTIFACT_RISK="protected"
        SM_ARTIFACT_KIND="unknown"
    elif sm_project_contains_protected_content "$path"; then
        SM_ARTIFACT_RISK="protected"
    elif declare -f should_protect_path >/dev/null 2>&1 && should_protect_path "$path"; then
        SM_ARTIFACT_RISK="protected"
    elif declare -f holds_compiled_model_cache >/dev/null 2>&1 && holds_compiled_model_cache "$path"; then
        SM_ARTIFACT_RISK="protected"
    elif declare -f is_path_whitelisted >/dev/null 2>&1 && is_path_whitelisted "$path"; then
        SM_ARTIFACT_RISK="protected"
    fi
}

sm_project_latest_activity() {
    local root="$1"
    local artifact_file="${2:-}"
    local latest=0 value="" candidate="" artifact="" path="" duplicate=false
    local now="" listing="" identity="" pattern="" index=0 owned_artifact_file=""
    local -a generated_paths=()
    local -a generated_identities=()
    local -a find_args=()

    now=$(/bin/date +%s 2>/dev/null || true)
    [[ "$now" =~ ^[0-9]+$ ]] || return 1
    listing=$(mktemp "${TMPDIR:-/tmp}/simple-mole-project-activity.XXXXXX") || {
        printf '%s\n' "$now"
        return 0
    }

    # Project inactivity excludes only artifacts that classify as Safe now.
    # Ambiguous build/bin/dist names, dependencies and protected content remain
    # part of the source activity tree.
    if [[ -z "$artifact_file" || ! -f "$artifact_file" ]]; then
        artifact_file=$(mktemp "${TMPDIR:-/tmp}/simple-mole-project-artifacts.XXXXXX") || {
            rm -f "$listing"
            printf '%s\n' "$now"
            return 0
        }
        owned_artifact_file="$artifact_file"
        if ! sm_project_discover_artifacts "$root" > "$artifact_file" 2>/dev/null; then
            rm -f "$listing" "$artifact_file"
            printf '%s\n' "$now"
            return 0
        fi
    fi
    while IFS= read -r -d '' artifact; do
        if [[ "${artifact##*/}" == "CACHEDIR.TAG" ]]; then artifact="${artifact%/*}"; fi
        path=$(sm_project_real_directory "$artifact" 2>/dev/null || true)
        [[ -n "$path" && "$path" != "$root" && "$path" == "$root/"* ]] || continue
        sm_project_classify_artifact "$path" "$root"
        [[ "$SM_ARTIFACT_RISK" == "safe" ]] || continue
        identity=$(sm_project_file_identity "$path" 2>/dev/null || true)
        [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || continue
        duplicate=false
        if [[ ${#generated_paths[@]} -gt 0 ]]; then
            for candidate in "${generated_paths[@]}"; do
                if [[ "$candidate" == "$path" ]]; then duplicate=true; break; fi
            done
        fi
        if [[ "$duplicate" != "true" ]]; then
            generated_paths+=("$path")
            generated_identities+=("$identity")
        fi
    done < "$artifact_file"
    if [[ -n "$owned_artifact_file" ]]; then
        rm -f "$owned_artifact_file"
    fi

    find_args=("$root" -mindepth 1)
    find_args+=( '(' -name .git -prune ')' -o )
    if [[ ${#generated_paths[@]} -gt 0 ]]; then
        find_args+=( '(' -type d '(' )
        for ((index = 0; index < ${#generated_paths[@]}; index++)); do
            [[ "$index" -gt 0 ]] && find_args+=( -o )
            pattern=$(sm_project_find_literal_pattern "${generated_paths[$index]}")
            find_args+=( -path "$pattern" )
        done
        find_args+=( ')' -prune ')' -o )
    fi
    find_args+=( '(' '(' -type f -o -type d ')' -print0 ')' )

    if ! command find "${find_args[@]}" > "$listing" 2>/dev/null; then
        rm -f "$listing"
        printf '%s\n' "$now"
        return 0
    fi
    for ((index = 0; index < ${#generated_paths[@]}; index++)); do
        identity=$(sm_project_file_identity "${generated_paths[$index]}" 2>/dev/null || true)
        path=$(sm_project_real_directory "${generated_paths[$index]}" 2>/dev/null || true)
        if [[ "$identity" != "${generated_identities[$index]}" ||
              "$path" != "${generated_paths[$index]}" ]]; then
            rm -f "$listing"
            printf '%s\n' "$now"
            return 0
        fi
        sm_project_classify_artifact "$path" "$root"
        if [[ "$SM_ARTIFACT_RISK" != "safe" ]]; then
            rm -f "$listing"
            printf '%s\n' "$now"
            return 0
        fi
    done
    while IFS= read -r -d '' candidate; do
        value=$("$STAT_BSD" -f%m "$candidate" 2>/dev/null || true)
        if [[ ! "$value" =~ ^[0-9]+$ ]]; then
            rm -f "$listing"
            printf '%s\n' "$now"
            return 0
        fi
        [[ "$value" -gt "$latest" ]] && latest="$value"
    done < "$listing"
    rm -f "$listing"

    # An empty or unreadable source tree must never look long-inactive.
    [[ "$latest" -gt 0 ]] || latest="$now"
    printf '%s\n' "$latest"
}

sm_project_artifact_mtime() {
    local path="$1"
    local latest=0 value="" candidate listing=""
    listing=$(mktemp "${TMPDIR:-/tmp}/simple-mole-artifact-mtime.XXXXXX") || return 1
    if ! command find "$path" -print0 > "$listing" 2>/dev/null; then
        rm -f "$listing"
        return 1
    fi
    while IFS= read -r -d '' candidate; do
        value=$("$STAT_BSD" -f%m "$candidate" 2>/dev/null || true)
        if [[ "$value" =~ ^[0-9]+$ && "$value" -gt "$latest" ]]; then latest="$value"; fi
    done < "$listing"
    rm -f "$listing"
    printf '%s\n' "$latest"
}

sm_project_discover_markers() {
    local location="$1"
    command find "$location" -mindepth 1 \
        \( -type d -name .git -print0 -prune \) -o \
        \( -type d \( -name node_modules -o -name Pods -o -name vendor -o \
            -name .venv -o -name venv -o -name target -o -name .build -o \
            -name build -o -name dist \) -prune \) -o \
        \( -type f \( -name .git -o -name package.json -o -name Cargo.toml -o \
            -name go.mod -o -name pyproject.toml -o -name requirements.txt -o \
            -name pom.xml -o -name build.gradle -o -name build.gradle.kts -o \
            -name Gemfile -o -name composer.json -o -name pubspec.yaml -o \
            -name Package.swift -o -name Makefile -o -name build.zig -o \
            -name build.zig.zon \) -print0 \)
}

sm_project_discover_artifacts() {
    local root="$1"
    command find "$root" -mindepth 1 \
        \( -type d -name .git -prune \) -o \
        \( -type d \( -name .pytest_cache -o -name .mypy_cache -o \
            -name .ruff_cache -o -name __pycache__ -o -name .turbo -o \
            -name .parcel-cache -o -name .next -o -name .nuxt -o \
            -name .output -o -name .svelte-kit -o -name .astro -o \
            -name .angular -o -name target -o -name .gradle -o \
            -name .terragrunt-cache -o -name .build -o -name .dart_tool -o \
            -name .zig-cache -o -name zig-out -o -name .cxx -o -name obj -o \
            -name coverage -o -name node_modules -o -name Pods -o \
            -name vendor -o -name venv -o -name .venv -o -name .tox -o \
            -name .nox -o -name build -o -name dist -o -name out -o -name bin \
        \) -print0 -prune \) -o \
        \( -type f -name CACHEDIR.TAG -print0 \)
}

sm_project_radar_main() {
    load_mole_whitelist
    local temp_root
    temp_root=$(mktemp -d "${TMPDIR:-/tmp}/simple-mole-radar.XXXXXX")
    SM_PROJECT_RADAR_TEMP_ROOT="$temp_root"
    trap sm_project_radar_cleanup EXIT
    local project_file="$temp_root/projects.nul"
    : > "$project_file"

    local raw location marker root marker_file artifact_file artifact path
    local existing activity root_identity identity bytes mtime
    local project_count=0 artifact_count=0 unavailable_count=0 location_count=0
    local duplicate=false in_scope=false
    local -a saved_locations=()
    local -a project_roots=()
    local -a emitted_artifacts=()
    while IFS= read -r -d '' raw; do
        if ! forgesweep_scan_path_allowed "$raw"; then
            sm_project_emit location "$raw" unavailable
            unavailable_count=$((unavailable_count + 1))
            continue
        fi
        if ! location=$(sm_project_real_directory "$raw"); then
            sm_project_emit location "$raw" unavailable
            unavailable_count=$((unavailable_count + 1))
            continue
        fi
        marker_file="$temp_root/markers.$location_count.nul"
        location_count=$((location_count + 1))
        if ! sm_project_discover_markers "$location" > "$marker_file" 2>/dev/null; then
            sm_project_emit location "$location" unavailable
            unavailable_count=$((unavailable_count + 1))
            continue
        fi
        sm_project_emit location "$location" available
        saved_locations+=("$location")
        if sm_project_is_root "$location"; then printf '%s\0' "$location" >> "$project_file"; fi
        while IFS= read -r -d '' marker; do
            [[ -n "$marker" ]] || continue
            root="${marker%/*}"
            [[ "$root" == "$location" || "$root" == "$location/"* ]] || continue
            path=$(sm_project_real_directory "$root" 2>/dev/null || true)
            [[ -n "$path" && "$path" == "$root" ]] || continue
            sm_project_is_root "$root" || continue
            printf '%s\0' "$root" >> "$project_file"
        done < "$marker_file"
    done

    # Revalidate scope after discovery and deduplicate without a line-based
    # protocol. This prevents newline components from forging an external root.
    while IFS= read -r -d '' root; do
        path=$(sm_project_real_directory "$root" 2>/dev/null || true)
        [[ -n "$path" && "$path" == "$root" ]] || continue
        in_scope=false
        if [[ ${#saved_locations[@]} -gt 0 ]]; then
            for location in "${saved_locations[@]}"; do
                if [[ "$root" == "$location" || "$root" == "$location/"* ]]; then
                    in_scope=true
                    break
                fi
            done
        fi
        [[ "$in_scope" == "true" ]] || continue
        duplicate=false
        if [[ ${#project_roots[@]} -gt 0 ]]; then
            for existing in "${project_roots[@]}"; do
                if [[ "$existing" == "$root" ]]; then duplicate=true; break; fi
            done
        fi
        [[ "$duplicate" == "true" ]] || project_roots+=("$root")
    done < "$project_file"

    # Nested projects own their artifacts before an enclosing monorepo does.
    local index previous key
    for ((index = 1; index < ${#project_roots[@]}; index++)); do
        key="${project_roots[$index]}"
        previous=$((index - 1))
        while [[ "$previous" -ge 0 &&
                 ${#project_roots[$previous]} -lt ${#key} ]]; do
            project_roots[$((previous + 1))]="${project_roots[$previous]}"
            previous=$((previous - 1))
        done
        project_roots[$((previous + 1))]="$key"
    done

    for ((index = 0; index < ${#project_roots[@]}; index++)); do
        root="${project_roots[$index]}"
        [[ -n "$root" ]] || continue
        artifact_file="$temp_root/artifacts.$project_count.nul"
        root_identity=$(sm_project_root_identity "$root" 2>/dev/null || true)
        [[ "$root_identity" =~ ^[0-9]+:[0-9]+$ ]] || continue
        if ! sm_project_discover_artifacts "$root" > "$artifact_file" 2>/dev/null; then
            activity=$(/bin/date +%s 2>/dev/null || true)
            if [[ "$activity" =~ ^[0-9]+$ ]]; then
                sm_project_emit project "$root" "$root_identity" "$activity"
                project_count=$((project_count + 1))
            fi
            continue
        fi
        activity=$(sm_project_latest_activity "$root" "$artifact_file") || continue
        sm_project_emit project "$root" "$root_identity" "$activity"
        project_count=$((project_count + 1))

        while IFS= read -r -d '' artifact; do
            [[ -n "$artifact" ]] || continue
            if [[ "${artifact##*/}" == "CACHEDIR.TAG" ]]; then artifact="${artifact%/*}"; fi
            [[ "$artifact" != "$root" ]] || continue
            duplicate=false
            if [[ ${#emitted_artifacts[@]} -gt 0 ]]; then
                for existing in "${emitted_artifacts[@]}"; do
                    if [[ "$existing" == "$artifact" ]]; then duplicate=true; break; fi
                done
            fi
            [[ "$duplicate" == "true" ]] && continue
            path=$(sm_project_real_directory "$artifact" 2>/dev/null || true)
            [[ -n "$path" && "$path" == "$root/"* ]] || continue
            sm_project_classify_artifact "$path" "$root"
            [[ "$SM_ARTIFACT_KIND" != "unknown" ]] || continue
            identity=$(sm_project_file_identity "$path" 2>/dev/null || true)
            [[ "$identity" =~ ^[0-9]+:[0-9]+:[0-9]+$ ]] || continue
            bytes=$(du -sk "$path" 2>/dev/null | awk '{print $1 * 1024}')
            [[ "$bytes" =~ ^[0-9]+$ ]] || { bytes=0; SM_ARTIFACT_RISK="protected"; }
            mtime=$(sm_project_artifact_mtime "$path")
            sm_project_emit artifact "$root" "$SM_ARTIFACT_RISK" "$SM_ARTIFACT_KIND" \
                "$bytes" "$mtime" "$identity" "$path"
            emitted_artifacts+=("$path")
            artifact_count=$((artifact_count + 1))
        done < "$artifact_file"
    done

    sm_project_emit summary "$project_count" "$artifact_count" "$unavailable_count"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    sm_project_radar_main "$@"
fi
