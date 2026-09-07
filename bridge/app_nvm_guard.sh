#!/bin/bash
# Shared nvm alias/current-version resolution for scan and delete-time guards.

simplemole_active_bin_dir() {
    local command_name="$1"
    local command_path="" resolved="" link_target="" candidate="" hops=0
    command_path=$(command -v "$command_name" 2>/dev/null) || command_path=""
    if [[ -z "$command_path" ]]; then
        for candidate in "/opt/homebrew/bin/$command_name" "/usr/local/bin/$command_name"; do
            if [[ -x "$candidate" ]]; then command_path="$candidate"; break; fi
        done
    fi
    [[ "$command_path" == /* ]] || return 1
    resolved="$command_path"
    while [[ -L "$resolved" && $hops -lt 8 ]]; do
        link_target=$(readlink "$resolved") || return 1
        if [[ "$link_target" == /* ]]; then
            resolved="$link_target"
        else
            resolved="${resolved%/*}/$link_target"
        fi
        hops=$((hops + 1))
    done
    [[ ! -L "$resolved" ]] || return 1
    (cd -P "${resolved%/*}" 2>/dev/null && pwd) || return 1
}

simplemole_nvm_latest_installed() {
    local root="$1" prefix="${2:-}" dir version
    while IFS= read -r dir; do
        version="${dir##*/}"
        [[ "$version" =~ ^v[0-9]+(\.[0-9]+){2}$ ]] || continue
        if [[ -n "$prefix" && "$version" != "$prefix" && "$version" != "$prefix".* ]]; then
            continue
        fi
        printf '%s\n' "$version"
    done < <(find "$root" -maxdepth 1 -mindepth 1 -type d 2>/dev/null) | sort -V | tail -1
}

simplemole_nvm_alias_file() {
    local alias_root="$1" alias_name="$2" component
    local -a components=()
    if [[ "$alias_name" == 'lts/*' ]]; then
        printf '%s\n' "$alias_root/lts/*"
        return 0
    fi
    [[ -n "$alias_name" && "$alias_name" != /* && "$alias_name" != */ ]] || return 1
    IFS='/' read -r -a components <<< "$alias_name"
    [[ ${#components[@]} -gt 0 ]] || return 1
    for component in "${components[@]}"; do
        [[ "$component" != "." && "$component" != ".." &&
            "$component" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    done
    printf '%s\n' "$alias_root/$alias_name"
}

# Resolve built-in, version-prefix, lts, and safely named custom alias chains.
simplemole_nvm_resolve_version() {
    local root="$1" requested="$2" alias_root="${3:-$HOME/.nvm/alias}"
    local alias_file="" next="" bare="" resolved="" steps=0
    while [[ "$steps" -lt 16 ]]; do
        case "$requested" in
            node|stable)
                simplemole_nvm_latest_installed "$root"
                return $?
                ;;
            *)
                if [[ "$requested" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ ]]; then
                    bare="${requested#v}"
                    if [[ -d "$root/v$bare" ]]; then
                        printf 'v%s\n' "$bare"
                        return 0
                    fi
                    resolved=$(simplemole_nvm_latest_installed "$root" "v$bare")
                    [[ -n "$resolved" ]] || return 1
                    printf '%s\n' "$resolved"
                    return 0
                fi
                alias_file=$(simplemole_nvm_alias_file "$alias_root" "$requested") || return 1
                ;;
        esac

        [[ -f "$alias_file" && ! -L "$alias_file" ]] || return 1
        next=$(tr -d '[:space:]' < "$alias_file")
        [[ -n "$next" ]] || return 1
        requested="$next"
        steps=$((steps + 1))
    done
    return 1
}

simplemole_paths_overlap() {
    local first="$1" second="$2"
    [[ "$first" == "$second" || "$first" == "$second"/* || "$second" == "$first"/* ]]
}

# Return success only when an nvm path is provably neither the fresh default
# nor the version backing the currently resolved node executable.
simplemole_nvm_path_safe_to_delete() {
    local path="$1"
    local logical_root="$HOME/.nvm/versions/node"
    local root="" physical_path=""
    if ! root=$(cd -P "$logical_root" 2>/dev/null && pwd); then
        case "$path" in "$logical_root"|"$logical_root"/*) return 1 ;; *) return 0 ;; esac
    fi
    if ! physical_path=$(cd -P "$path" 2>/dev/null && pwd); then
        case "$path" in "$logical_root"|"$logical_root"/*) return 1 ;; *) return 0 ;; esac
    fi
    case "$physical_path" in
        "$root"|"$root"/*) path="$physical_path" ;;
        *)
            # A lexical nvm path resolving outside the version root is unsafe.
            case "$path" in "$logical_root"|"$logical_root"/*) return 1 ;; *) return 0 ;; esac
            ;;
    esac

    local default_file="$HOME/.nvm/alias/default"
    local requested="" resolved="" default_dir=""
    if [[ -e "$default_file" || -L "$default_file" ]]; then
        [[ -f "$default_file" && ! -L "$default_file" ]] || return 1
        requested=$(tr -d '[:space:]' < "$default_file")
        resolved=$(simplemole_nvm_resolve_version "$root" "$requested" "$HOME/.nvm/alias") || return 1
        default_dir="$root/$resolved"
        [[ -d "$default_dir" ]] || return 1
        simplemole_paths_overlap "$path" "$default_dir" && return 1
    fi

    local active_bin="" active_relative="" active_version="" active_dir=""
    active_bin=$(simplemole_active_bin_dir node) || active_bin=""
    case "$active_bin" in
        "$root"/*)
            active_relative="${active_bin#"$root"/}"
            active_version="${active_relative%%/*}"
            active_dir="$root/$active_version"
            [[ -d "$active_dir" ]] || return 1
            simplemole_paths_overlap "$path" "$active_dir" && return 1
            ;;
    esac
    return 0
}
