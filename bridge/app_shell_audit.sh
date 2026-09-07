#!/bin/bash
# App bridge: shell rc audit. Read-only.
# TSV: file \t kind \t detail \t line
#   kind=path-dup   same PATH directory exported on multiple lines
#   kind=path-dead  literal PATH entry pointing to a missing directory
#   kind=orphan     init block for a tool that is gone (nvm/pyenv/brew)
# Bash 3.2 compatible: no associative arrays; empty-array expansions guarded.
set -euo pipefail
export LC_ALL=C

files=()
for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.bashrc" "$HOME/.bash_profile"; do
    [[ -f "$f" ]] && files+=("$f")
done
[[ ${#files[@]} -gt 0 ]] || exit 0

for f in "${files[@]}"; do
    seen_dirs=()
    seen_lines=()
    n=0
    while IFS= read -r line; do
        n=$((n + 1))
        case "$line" in
            "#"*|*PATH*=*) ;;
            *) continue ;;
        esac
        value="${line#*=}"
        value="${value%\"}"; value="${value#\"}"
        value="${value%\'}"; value="${value#\'}"
        # 逐目录检查（变量未展开的片段跳过）
        oldIFS="$IFS"; IFS=':'
        parts=($value)
        IFS="$oldIFS"
        for d in "${parts[@]}"; do
            d="${d//\$HOME/$HOME}"
            d="${d//\~/$HOME}"
            [[ -n "$d" ]] || continue
            case "$d" in
                *'$'*|*'`'*|*'('*|*'{'*) continue ;;
                /*) ;;
                *) continue ;;
            esac
            # 跨行重复导出
            i=0
            for sd in ${seen_dirs[@]+"${seen_dirs[@]}"}; do
                if [[ "$sd" == "$d" ]]; then
                    printf '%s\tpath-dup\t%s\t%s\n' "$f" "$d" "${seen_lines[$i]}"
                fi
                i=$((i + 1))
            done
            seen_dirs+=("$d")
            seen_lines+=("$n")
            # 失效目录（每目录只报一次）
            if [[ ! -d "$d" ]]; then
                dup=0
                for sd in ${seen_dirs[@]+"${seen_dirs[@]}"}; do
                    [[ "$sd" == "dead:$d" ]] && dup=1
                done
                [[ $dup -eq 0 ]] && printf '%s\tpath-dead\t%s\t%s\n' "$f" "$d" "$n"
                seen_dirs+=("dead:$d")
                seen_lines+=("$n")
            fi
        done
    done < "$f"

    # 卸载残留的初始化块
    if grep -q "nvm.sh" "$f" 2>/dev/null && [[ ! -d "$HOME/.nvm" ]]; then
        printf '%s\torphan\tnvm init block (~/.nvm missing)\t0\n' "$f"
    fi
    if grep -q "pyenv init" "$f" 2>/dev/null && [[ ! -d "$HOME/.pyenv" ]]; then
        printf '%s\torphan\tpyenv init block (~/.pyenv missing)\t0\n' "$f"
    fi
    if grep -q "brew shellenv" "$f" 2>/dev/null && ! command -v brew >/dev/null 2>&1; then
        printf '%s\torphan\tbrew shellenv block (brew not available)\t0\n' "$f"
    fi
done
