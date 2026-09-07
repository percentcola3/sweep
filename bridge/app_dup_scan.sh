#!/bin/bash
# App bridge: duplicate detection among provided large files.
# stdin: NUL-delimited absolute file paths.
# Output TSV (groups with >= 2 byte-identical members only):
#   bytes \t dupkey \t path
# Pipeline: same-size grouping -> head+tail fingerprint -> full md5, so full
# hashing only runs on real candidates. Bash 3.2 compatible (no assoc arrays).
set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1090
source "$SCRIPT_DIR/lib/core/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/app_scan_access.sh"

work="$(mktemp -d "${TMPDIR:-/tmp}/sm-dup.XXXXXX")"
trap 'rm -rf "$work"' EXIT
t_size="$work/size.tsv"; t_blk="$work/blocks.tsv"; t_fp="$work/fp.tsv"
t_cand="$work/cand.tsv"; t_full="$work/full.tsv"
: > "$t_fp"; : > "$t_full"

# 1) size index
while IFS= read -r -d '' p; do
    forgesweep_scan_path_allowed "$p" || continue
    [[ -f "$p" ]] || continue
    printf '%s\t%s\n' "$(stat -f '%z' "$p" 2>/dev/null || echo 0)" "$p"
done | sort -n > "$t_size"

# 2) same-size groups (>=2 members), blocks separated by blank lines
awk -F'\t' '
    $1 == prev { buf = buf "\n" $0; n++ }
    $1 != prev { if (n >= 2) print buf "\n"; buf = $0; prev = $1; n = 1 }
    END { if (n >= 2) print buf "\n" }
' "$t_size" > "$t_blk"

# 3) cheap fingerprint: md5 over first+last 1MB
while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    size="${line%%$'\t'*}"; path="${line#*$'\t'}"
    fp=$( { head -c 1048576 "$path" 2>/dev/null; tail -c 1048576 "$path" 2>/dev/null; } \
        | md5 -q 2>/dev/null) || continue
    [[ -n "$fp" ]] || continue
    printf '%s\t%s\t%s\n' "$fp" "$size" "$path"
done < "$t_blk" | sort > "$t_fp"

# 4) fingerprint groups (>=2) -> full hash, per-file bounded
sort -t$'\t' -k1,1 "$t_fp" | awk -F'\t' '
    $1 == prev { print; n++ }
    $1 != prev { if (n >= 2) print prev_line; prev = $1; prev_line = $0; n = 1 }
    END { if (n >= 2) print prev_line }
' > "$t_cand"
# the awk above drops boundary lines; redo grouping precisely:
awk -F'\t' '
    { fp[NR] = $1; sz[NR] = $2; pth[NR] = $3; n = NR }
    END {
        for (i = 1; i <= n; i++) cnt[fp[i]]++
        for (i = 1; i <= n; i++) if (cnt[fp[i]] >= 2) print sz[i] "\t" pth[i]
    }
' "$t_fp" | sort -n > "$t_cand"

while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    size="${line%%$'\t'*}"; path="${line#*$'\t'}"
    full=$(run_with_timeout 300 md5 -q "$path" 2>/dev/null) || continue
    [[ -n "$full" ]] || continue
    printf '%s\t%s\t%s\n' "$full" "$size" "$path"
done < "$t_cand" | sort > "$t_full"

# 5) emit full-hash groups with a stable key
awk -F'\t' '
    { h[NR] = $1; sz[NR] = $2; pth[NR] = $3; n = NR }
    END {
        for (i = 1; i <= n; i++) cnt[h[i]]++
        k = 0
        for (i = 1; i <= n; i++) {
            if (cnt[h[i]] < 2) continue
            if (!(h[i] in seen)) { seen[h[i]] = 1; k++; key = "d-" k }
            printf "%s\t%s\t%s\n", sz[i], key, pth[i]
        }
    }
' "$t_full"
