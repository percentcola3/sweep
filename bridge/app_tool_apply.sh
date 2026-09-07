#!/bin/bash
set -euo pipefail
run_uninstall() {
    local manager="$1" package="$2"
    [[ "$package" =~ ^[A-Za-z0-9@._+:/-]+$ ]] || return 1
    case "$manager" in
        npm) npm uninstall --global "$package";; pnpm) pnpm remove --global "$package";;
        brew) brew uninstall "$package";; brew-cask) brew uninstall --cask "$package";;
        cargo) cargo uninstall "$package";; dotnet) dotnet tool uninstall --global "$package";;
        pipx) pipx uninstall "$package";; *) return 1;;
    esac
}
removed=0; failed=0
while IFS= read -r -d '' encoded; do
    manager="${encoded%%|*}"; package="${encoded#*|}"
    if run_uninstall "$manager" "$package"; then removed=$((removed + 1)); else failed=$((failed + 1)); fi
done
printf 'removed=%s\nfailed=%s\n' "$removed" "$failed"
[[ "$failed" -eq 0 ]]
