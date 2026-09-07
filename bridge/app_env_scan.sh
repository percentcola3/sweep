#!/bin/bash
# App bridge: inventory of user-installed dev runtimes and toolchains.
# Read-only. TSV: bytes \t kind \t name \t path \t related_bytes \t related_path
#   kind=runtime  可清理的版本目录（需用户确认，经 mole_delete 进废纸篓）
#   kind=current  正在使用中的版本（GUI 锁定不可选）
#   kind=manager  工具/包管理器本体（仅展示，不提供清理）
set -euo pipefail

# 可选守卫（存在才加载）：nvm 版本删除前置检查
GUARD="$(dirname "${BASH_SOURCE[0]}")/app_nvm_guard.sh"
[[ -f "$GUARD" ]] && source "$GUARD"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"

dir_bytes() {
    local size
    size=$(du -sk "$1" 2>/dev/null | awk '{print $1 * 1024}')
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    printf '%s' "$size"
}

# emit_version <manager> <version> <dir> <active_dir> [protected_dir]：每个版本一条记录。
emit_version() {
    local manager="$1" version="$2" dir="$3" active_dir="$4" protected_dir="${5:-}"
    [[ -d "$dir" ]] || return 0
    local bytes kind related_bytes=0 related_path=""
    bytes=$(dir_bytes "$dir")
    kind="runtime"
    # 使用中的版本：active bin 目录位于该版本目录之下。
    if [[ -n "$active_dir" && "$active_dir" == "$dir"/* ]] ||
        [[ -n "$protected_dir" && "$dir" == "$protected_dir" ]]; then
        kind="current"
    fi
    # nvm stores version-specific global packages inside the version directory.
    # They are already part of `bytes` and are removed with that old version;
    # emit the breakdown so the UI can make this relationship explicit.
    if [[ "$manager" == "nvm" && -d "$dir/lib/node_modules" ]]; then
        related_path="$dir/lib/node_modules"
        related_bytes=$(dir_bytes "$related_path")
    fi
    printf '%s\t%s\t%s · %s\t%s\t%s\t%s\n' \
        "$bytes" "$kind" "$manager" "$version" "$dir" "$related_bytes" "$related_path"
}

# emit_runtime_family <manager> <versions_root> <command> [inner] [protected_dir]
# 版本目录 = versions_root 下的一级子目录；可通过 inner 参数下钻。
emit_runtime_family() {
    local manager="$1" root="$2" cmd="$3" inner="${4:-}" protected_dir="${5:-}"
    [[ -d "$root" ]] || return 0
    local active_dir=""
    active_dir=$(simplemole_active_bin_dir "$cmd") || active_dir=""
    local dir target
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        target="$dir"
        [[ -n "$inner" && -d "$dir/$inner" ]] && target="$dir/$inner"
        emit_version "$manager" "$(basename "$dir")" "$target" "$active_dir" "$protected_dir"
    done < <(find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
}

emit_manager_dir() {
    local name="$1" dir="$2"
    [[ -d "$dir" ]] || return 0
    printf '%s\tmanager\t%s\t%s\n' "$(dir_bytes "$dir")" "$name" "$dir"
}

# Version-manager-owned runtimes must be removed with their owner command.
# Enumerate each installed version for visibility, but never offer direct
# filesystem deletion through the generic cleanup sink.
emit_readonly_runtime_family() {
    local manager="$1" root="$2" inner="${3:-}"
    forgesweep_scan_path_allowed "$root" || return 0
    [[ -d "$root" ]] || return 0
    local dir target
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        target="$dir"
        [[ -n "$inner" && -d "$dir/$inner" ]] && target="$dir/$inner"
        printf '%s\tmanager\t%s · %s\t%s\n' \
            "$(dir_bytes "$target")" "$manager" "$(basename "$dir")" "$target"
    done < <(find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
}

# --- Node 生态 ---
nvm_default_dir=""
# nvm 的默认版本也必须锁定：App 的非交互 PATH 通常找不到 nvm 当前 node。
if [[ -d "$HOME/.nvm/versions/node" && -f "$HOME/.nvm/alias/default" ]]; then
    nvm_default=$(tr -d '[:space:]' < "$HOME/.nvm/alias/default")
    nvm_resolved=$(simplemole_nvm_resolve_version \
        "$HOME/.nvm/versions/node" "$nvm_default" "$HOME/.nvm/alias" 2>/dev/null || true)
    if [[ -n "$nvm_resolved" && -d "$HOME/.nvm/versions/node/$nvm_resolved" ]]; then
        nvm_default_dir="$HOME/.nvm/versions/node/$nvm_resolved"
    fi
fi
emit_runtime_family "nvm" "$HOME/.nvm/versions/node" "node" "" "$nvm_default_dir"
[[ "${MOLE_TEST_NVM_ONLY:-0}" == "1" ]] && exit 0
emit_readonly_runtime_family "fnm" "$HOME/Library/Application Support/fnm/node-versions" "installation"
emit_readonly_runtime_family "volta" "$HOME/.volta/tools/image/node"
emit_readonly_runtime_family "asdf" "$HOME/.asdf/installs/node"

# Homebrew owns Cellar contents. Show formula directories as read-only manager
# entries instead of routing them through the generic filesystem deleter.
brew_prefixes=("/opt/homebrew" "/usr/local")
for prefix in "${brew_prefixes[@]}"; do
    cellar="$prefix/Cellar"
    [[ -d "$cellar" ]] || continue
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        printf '%s\tmanager\tHomebrew · %s\t%s\n' \
            "$(dir_bytes "$dir")" "$(basename "$dir")" "$dir"
    done < <(find "$cellar" -maxdepth 1 -mindepth 1 -type d -name 'node*' 2>/dev/null | sort)
done

# --- 其他语言运行时 ---
emit_readonly_runtime_family "pyenv" "$HOME/.pyenv/versions"
emit_readonly_runtime_family "rbenv" "$HOME/.rbenv/versions"
emit_readonly_runtime_family "rustup" "$HOME/.rustup/toolchains"

# System-wide JDK bundles require an installer/package-manager owned removal
# flow. Keep them visible but read-only instead of offering a cleanup that the
# unprivileged generic apply bridge cannot complete safely.
if [[ -d "/Library/Java/JavaVirtualMachines" ]]; then
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        bytes=$(dir_bytes "$dir")
        printf '%s\tmanager\tJDK · %s\t%s\n' "$bytes" "$(basename "$dir")" "$dir"
    done < <(find "/Library/Java/JavaVirtualMachines" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
fi

# --- 系统内置运行时（仅识别标记；GUI 锁定不可删）---
emit_builtin() {
    local name="$1" path="$2" bytes
    [[ -e "$path" ]] || return 0
    bytes=$(stat -f '%z' "$path" 2>/dev/null || echo 0)
    printf '%s\tbuiltin\t%s\t%s\n' "$bytes" "$name" "$path"
}
emit_builtin "System Python (built-in)" "/usr/bin/python3"
emit_builtin "System Ruby (built-in)"   "/usr/bin/ruby"
emit_builtin "System Perl (built-in)"   "/usr/bin/perl"
emit_builtin "System PHP (built-in)"    "/usr/bin/php"

# --- python.org 官方 pkg 安装 ---
if [[ -d "/Library/Frameworks/Python.framework/Versions" ]]; then
    while IFS= read -r dir; do
        [[ -n "$dir" ]] || continue
        printf '%s\truntime\tPython.org · %s\t%s\n' "$(dir_bytes "$dir")" "$(basename "$dir")" "$dir"
    done < <(find "/Library/Frameworks/Python.framework/Versions" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
fi

# --- Homebrew 语言运行时（python/go/ruby 的 Cellar 版本）---
for prefix in /opt/homebrew /usr/local; do
    cellar="$prefix/Cellar"
    [[ -d "$cellar" ]] || continue
    for pkg in python python@3 python@3.13 python@3.12 python@3.11 python@3.10 go ruby; do
        pkg_dir="$cellar/$pkg"
        [[ -d "$pkg_dir" ]] || continue
        case "$pkg" in
            go)   cmd_bin="$prefix/bin/go" ;;
            ruby) cmd_bin="$prefix/bin/ruby" ;;
            *)    cmd_bin="$prefix/bin/python3" ;;
        esac
        active_dir=""
        if [[ -x "$cmd_bin" ]]; then
            resolved="$cmd_bin"; hops=0
            while [[ -L "$resolved" && $hops -lt 8 ]]; do
                t=$(readlink "$resolved")
                if [[ "$t" == /* ]]; then resolved="$t"; else resolved="$(dirname "$resolved")/$t"; fi
                hops=$((hops + 1))
            done
            active_dir=$(cd -P "$(dirname "$resolved")" 2>/dev/null && pwd) || active_dir=""
        fi
        while IFS= read -r ver_dir; do
            [[ -n "$ver_dir" ]] || continue
            bytes=$(dir_bytes "$ver_dir")
            kind="runtime"
            [[ -n "$active_dir" && "$active_dir" == "$ver_dir"/* ]] && kind="current"
            printf '%s\t%s\tHomebrew · %s %s\t%s\n' "$bytes" "$kind" "$pkg" "$(basename "$ver_dir")" "$ver_dir"
        done < <(find "$pkg_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)
    done
done

# --- conda 发行版（manager 本体，仅展示）---
for d in "$HOME/miniconda3" "$HOME/anaconda3" "/opt/miniconda3" "/opt/anaconda3" "$HOME/opt/anaconda3" "$HOME/opt/miniconda3"; do
    [[ -d "$d" ]] || continue
    printf '%s\tmanager\tConda (%s)\t%s\n' "$(dir_bytes "$d")" "$(basename "$d")" "$d"
done

# --- 工具/包管理器本体（仅展示） ---
emit_manager_dir "Bun" "$HOME/.bun"
emit_manager_dir "Deno" "$HOME/.deno"
emit_manager_dir "Cargo" "$HOME/.cargo"
emit_manager_dir "Volta" "$HOME/.volta"
emit_manager_dir "nvm" "$HOME/.nvm"
if command -v brew >/dev/null 2>&1; then
    brew_prefix=$(brew --prefix 2>/dev/null || true)
    [[ -n "$brew_prefix" && -d "$brew_prefix" ]] && \
        printf '%s\tmanager\tHomebrew\t%s\n' "$(dir_bytes "$brew_prefix")" "$brew_prefix"
fi
