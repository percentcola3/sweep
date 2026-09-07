#!/bin/bash
set -euo pipefail

emit_json_packages() {
    local manager="$1"; shift
    command -v "$1" >/dev/null 2>&1 || return 0
    "$@" 2>/dev/null | node -e '
      let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{try{const p=JSON.parse(s).dependencies||{};for(const n of Object.keys(p))console.log("0\t"+process.argv[1]+" · "+n+"\t"+process.argv[1]+"|"+n)}catch(_){}})' "$manager"
}
if command -v node >/dev/null 2>&1; then
    emit_json_packages npm npm ls -g --depth=0 --json
    emit_json_packages pnpm pnpm ls -g --depth=0 --json
fi
if command -v brew >/dev/null 2>&1; then
    brew list --formula 2>/dev/null | while IFS= read -r p; do printf '0\tHomebrew · %s\tbrew|%s\n' "$p" "$p"; done
    brew list --cask 2>/dev/null | while IFS= read -r p; do printf '0\tHomebrew Cask · %s\tbrew-cask|%s\n' "$p" "$p"; done
fi
if command -v cargo >/dev/null 2>&1; then
    cargo install --list 2>/dev/null | awk '/^[^ ]+ v[0-9]/{gsub(/ v.*/, "", $1); printf "0\tCargo · %s\tcargo|%s\n", $1, $1}'
fi
if command -v dotnet >/dev/null 2>&1; then
    dotnet tool list --global 2>/dev/null | awk 'NR > 2 && $1 !~ /^-+$/ && $1 != "Package" { printf "0\t.NET Tool · %s\tdotnet|%s\n", $1, $1 }'
fi
if command -v pipx >/dev/null 2>&1; then
    pipx list --short 2>/dev/null | awk '{printf "0\tpipx · %s\tpipx|%s\n", $1, $1}'
fi
