#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOLE_SOURCE="${MOLE_SRC:-$ROOT_DIR/vendor/mole}"
[[ -d "$MOLE_SOURCE/lib" ]] || { echo "FAIL: Mole lib not found at $MOLE_SOURCE"; exit 1; }

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/simple-mole-project-tests.XXXXXX")
TEST_ROOT=$(cd -P "$TEST_ROOT" && /bin/pwd -P)
EXTERNAL_PROJECT=""
cleanup() {
    case "$TEST_ROOT" in
        */simple-mole-project-tests.*) rm -rf "$TEST_ROOT" ;;
    esac
    case "$EXTERNAL_PROJECT" in
        /private/tmp/simple-mole-external.*) rm -rf "$EXTERNAL_PROJECT" ;;
    esac
}
trap cleanup EXIT
STAGE="$TEST_ROOT/stage"
TEST_HOME="$TEST_ROOT/home"
TEST_TRASH="$TEST_HOME/.Trash"
mkdir -p "$STAGE/bin" "$TEST_HOME" "$TEST_TRASH"
bash "$ROOT_DIR/script/stage_bridge_resources.sh" "$MOLE_SOURCE" "$STAGE"

IDLE_LSOF="$TEST_ROOT/lsof-idle"
ACTIVE_LSOF="$TEST_ROOT/lsof-active"
TRANSIENT_LSOF="$TEST_ROOT/lsof-transient"
ERROR_LSOF="$TEST_ROOT/lsof-error"
TIMEOUT_LSOF="$TEST_ROOT/lsof-timeout"
printf '#!/bin/bash\nexit 1\n' > "$IDLE_LSOF"
printf '#!/bin/bash\n[[ -z "${SM_TEST_LSOF_ARGS_FILE:-}" ]] || printf "%%s\\n" "$*" >> "$SM_TEST_LSOF_ARGS_FILE"\nprintf "p111\\nn%%s/unrelated\\np999\\nn%%s/open-file\\n" "$SM_TEST_UNRELATED_ROOT" "$SM_TEST_ACTIVE_ROOT"\n' > "$ACTIVE_LSOF"
printf '#!/bin/bash\ncount=0\n[[ -f "$SM_TEST_LSOF_COUNT_FILE" ]] && count=$(/bin/cat "$SM_TEST_LSOF_COUNT_FILE")\ncount=$((count + 1))\nprintf "%%s\\n" "$count" > "$SM_TEST_LSOF_COUNT_FILE"\nif [[ "$count" -ge 3 ]]; then printf "p999\\nn%%s/open-file\\n" "$SM_TEST_ACTIVE_ROOT"; exit 0; fi\nexit 1\n' > "$TRANSIENT_LSOF"
printf '#!/bin/bash\nprintf "permission denied\\n" >&2\nexit 1\n' > "$ERROR_LSOF"
printf '#!/bin/bash\nexit 124\n' > "$TIMEOUT_LSOF"
chmod +x "$IDLE_LSOF" "$ACTIVE_LSOF" "$TRANSIENT_LSOF" \
    "$ERROR_LSOF" "$TIMEOUT_LSOF"

pass_count=0
fail() { echo "FAIL: $*"; exit 1; }
pass() { pass_count=$((pass_count + 1)); echo "PASS: $*"; }

bridge_env() {
    env HOME="$TEST_HOME" USER="${USER:-tester}" LOGNAME="${LOGNAME:-tester}" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" TMPDIR="$TEST_ROOT" \
        MOLE_TEST_MODE=1 MOLE_TEST_TRASH_DIR="$TEST_TRASH" \
        MOLE_DELETE_LOG="$TEST_ROOT/deletions.log" SM_LSOF_BIN="${TEST_LSOF:-$IDLE_LSOF}" \
        SM_TEST_ACTIVE_ROOT="${SM_TEST_ACTIVE_ROOT:-}" \
        SM_TEST_UNRELATED_ROOT="${SM_TEST_UNRELATED_ROOT:-$TEST_ROOT/unrelated}" \
        SM_TEST_LSOF_ARGS_FILE="${SM_TEST_LSOF_ARGS_FILE:-$TEST_ROOT/lsof-args}" \
        SM_TEST_LSOF_COUNT_FILE="${SM_TEST_LSOF_COUNT_FILE:-$TEST_ROOT/lsof-count}" "$@"
}

to_lines() { LC_ALL=C tr '\000' '\n' < "$1" > "$2"; }
field() { sed -n "${1}p" "$2"; }
root_identity() { /usr/bin/stat -f%d:%i "$1"; }
path_identity() { /usr/bin/stat -f%d:%i:%m "$1"; }
make_old() { /usr/bin/touch -t 202001010000 "$@"; }
nul_has_project() {
    local target="$1" output="$2"
    TARGET_PROJECT="$target" /usr/bin/perl -0 -e '
        my $previous = "";
        while (defined(my $field = <STDIN>)) {
            chomp $field;
            exit 0 if $previous eq "project" && $field eq $ENV{"TARGET_PROJECT"};
            $previous = $field;
        }
        exit 1;
    ' < "$output"
}
project_activity_from_lines() {
    local target="$1" output="$2"
    /usr/bin/awk -v target="$target" '
        previous == "project" && $0 == target {
            getline identity
            getline activity
            print activity
            exit
        }
        { previous = $0 }
    ' "$output"
}

PROJECT="$TEST_ROOT/project"
ARTIFACT="$PROJECT/.next"
DEEP_SOURCE="$PROJECT/src/one/two/three/four/five/six/main.swift"
mkdir -p "$ARTIFACT/cache"
mkdir -p "${DEEP_SOURCE%/*}"
mkdir -p "$PROJECT/.git/objects/deep"
printf '{"scripts":{"postinstall":"touch should-not-run"}}\n' > "$PROJECT/package.json"
printf 'cache\n' > "$ARTIFACT/cache/data"
printf 'let activity = true\n' > "$DEEP_SOURCE"
printf 'git internals\n' > "$PROJECT/.git/objects/deep/recent"
make_old "$ARTIFACT/cache/data" "$ARTIFACT/cache" "$ARTIFACT"
make_old "$PROJECT/package.json" "$PROJECT/src" "$PROJECT/src/one" \
    "$PROJECT/src/one/two" "$PROJECT/src/one/two/three" \
    "$PROJECT/src/one/two/three/four" "$PROJECT/src/one/two/three/four/five" \
    "${DEEP_SOURCE%/*}"
/usr/bin/touch "$DEEP_SOURCE"
DEEP_SOURCE_MTIME=$(/usr/bin/stat -f%m "$DEEP_SOURCE")
/usr/bin/touch -t 203001010000 "$ARTIFACT/cache/data" "$ARTIFACT/cache" "$ARTIFACT" \
    "$PROJECT/.git/objects/deep/recent"

RADAR_OUT="$TEST_ROOT/radar.out"
printf '%s\0' "$PROJECT" | bridge_env /bin/bash "$STAGE/bin/app_project_radar.sh" > "$RADAR_OUT"
to_lines "$RADAR_OUT" "$TEST_ROOT/radar.lines"
grep -Fqx "project" "$TEST_ROOT/radar.lines" || fail "radar did not emit project"
grep -Fqx "javascriptCache" "$TEST_ROOT/radar.lines" || fail "radar did not classify .next"
grep -Fqx "safe" "$TEST_ROOT/radar.lines" || fail "radar did not mark strict output Safe"
pass "radar classifies strict generated output"

RADAR_ACTIVITY=$(project_activity_from_lines "$PROJECT" "$TEST_ROOT/radar.lines")
[[ "$RADAR_ACTIVITY" == "$DEEP_SOURCE_MTIME" ]] ||
    fail "radar ignored deep source activity or included generated/.git content"
pass "radar scans deep source activity and prunes generated/.git content"

ACTIVITY_OUT="$TEST_ROOT/activity.out"
printf '%s\0' "$PROJECT" | bridge_env /bin/bash "$STAGE/bin/app_project_activity.sh" > "$ACTIVITY_OUT"
to_lines "$ACTIVITY_OUT" "$TEST_ROOT/activity.lines"
[[ "$(field 3 "$TEST_ROOT/activity.lines")" == "idle" ]] || fail "idle activity was not reported"
pass "activity check supports fail-closed injectable fixture"

# Activity discovery must take one global lsof snapshot and filter its name
# fields. Recursive `+D` traversal made tiny cleanup items wait up to 10s.
/bin/rm -f "$TEST_ROOT/lsof-global-args"
printf '%s\0' "$PROJECT" | TEST_LSOF="$ACTIVE_LSOF" \
    SM_TEST_ACTIVE_ROOT="$PROJECT" SM_TEST_LSOF_ARGS_FILE="$TEST_ROOT/lsof-global-args" \
    bridge_env /bin/bash "$STAGE/bin/app_project_activity.sh" \
    > "$TEST_ROOT/activity-active.out"
to_lines "$TEST_ROOT/activity-active.out" "$TEST_ROOT/activity-active.lines"
[[ "$(field 3 "$TEST_ROOT/activity-active.lines")" == "active" ]] || \
    fail "global lsof snapshot did not bind an open project path"
[[ "$(wc -l < "$TEST_ROOT/lsof-global-args" | tr -d ' ')" == "1" ]] || \
    fail "activity check did not use exactly one lsof snapshot"
[[ "$(cat "$TEST_ROOT/lsof-global-args")" == "-nP -Fpn" ]] || \
    fail "activity check still traverses a project path: $(cat "$TEST_ROOT/lsof-global-args")"
pass "activity check filters one non-recursive global lsof snapshot"

printf '%s\0' "$PROJECT" | TEST_LSOF="$ERROR_LSOF" \
    bridge_env /bin/bash "$STAGE/bin/app_project_activity.sh" \
    > "$TEST_ROOT/activity-error.out"
to_lines "$TEST_ROOT/activity-error.out" "$TEST_ROOT/activity-error.lines"
[[ "$(field 3 "$TEST_ROOT/activity-error.lines")" == "unknown" && \
   "$(field 4 "$TEST_ROOT/activity-error.lines")" == "lsof-error" ]] || \
    fail "lsof errors did not fail closed"
printf '%s\0' "$PROJECT" | TEST_LSOF="$TIMEOUT_LSOF" \
    bridge_env /bin/bash "$STAGE/bin/app_project_activity.sh" \
    > "$TEST_ROOT/activity-timeout.out"
to_lines "$TEST_ROOT/activity-timeout.out" "$TEST_ROOT/activity-timeout.lines"
[[ "$(field 3 "$TEST_ROOT/activity-timeout.lines")" == "unknown" && \
   "$(field 4 "$TEST_ROOT/activity-timeout.lines")" == "lsof-timeout" ]] || \
    fail "lsof timeouts did not fail closed"
pass "activity snapshot errors and timeouts fail closed"

# Purge apply must rely on the mutation-edge guard only. Its single selected
# artifact should therefore trigger one (not two) activity snapshots.
PURGE_ARTIFACT="$PROJECT/__pycache__"
mkdir -p "$PURGE_ARTIFACT" "$TEST_HOME/.config/mole"
printf 'bytecode\n' > "$PURGE_ARTIFACT/example.pyc"
printf '%s\n' "$PROJECT" > "$TEST_HOME/.config/mole/purge_paths"
PURGE_ID=$(path_identity "$PURGE_ARTIFACT")
printf '%s\0%s\0' "$PURGE_ARTIFACT" "$PURGE_ID" > "$TEST_ROOT/purge.in"
/bin/rm -f "$TEST_ROOT/purge-lsof-args"
TEST_LSOF="$ACTIVE_LSOF" SM_TEST_ACTIVE_ROOT="$TEST_ROOT/not-the-project" \
    SM_TEST_LSOF_ARGS_FILE="$TEST_ROOT/purge-lsof-args" \
    bridge_env /bin/bash "$STAGE/bin/app_purge_apply.sh" \
    < "$TEST_ROOT/purge.in" > "$TEST_ROOT/purge.out"
[[ ! -e "$PURGE_ARTIFACT" && "$(cat "$TEST_ROOT/purge.out")" == *"removed=1"* ]] || \
    fail "purge apply did not remove the verified idle artifact"
[[ "$(wc -l < "$TEST_ROOT/purge-lsof-args" | tr -d ' ')" == "1" ]] || \
    fail "purge apply repeated the project activity guard"
pass "purge apply performs one final project activity snapshot"

WARNING_SOURCE_PROJECT="$TEST_ROOT/warning-source-project"
WARNING_SOURCE_FILE="$WARNING_SOURCE_PROJECT/bin/deploy.sh"
mkdir -p "$WARNING_SOURCE_PROJECT/.next" "${WARNING_SOURCE_FILE%/*}"
printf '{"name":"warning-source"}\n' > "$WARNING_SOURCE_PROJECT/package.json"
printf 'cache\n' > "$WARNING_SOURCE_PROJECT/.next/data"
printf '#!/bin/sh\n' > "$WARNING_SOURCE_FILE"
make_old "$WARNING_SOURCE_PROJECT" "$WARNING_SOURCE_PROJECT/package.json" \
    "$WARNING_SOURCE_PROJECT/.next" "$WARNING_SOURCE_PROJECT/.next/data" \
    "$WARNING_SOURCE_PROJECT/bin"
/usr/bin/touch "$WARNING_SOURCE_FILE"
WARNING_SOURCE_MTIME=$(/usr/bin/stat -f%m "$WARNING_SOURCE_FILE")
printf '%s\0' "$WARNING_SOURCE_PROJECT" | \
    bridge_env /bin/bash "$STAGE/bin/app_project_radar.sh" > "$TEST_ROOT/warning-source.out"
to_lines "$TEST_ROOT/warning-source.out" "$TEST_ROOT/warning-source.lines"
[[ "$(project_activity_from_lines "$WARNING_SOURCE_PROJECT" \
    "$TEST_ROOT/warning-source.lines")" == "$WARNING_SOURCE_MTIME" ]] ||
    fail "Warning bin source was pruned from project activity"
pass "project inactivity keeps ambiguous build and bin directories in the source tree"

ROOT_ID=$(root_identity "$PROJECT")
make_old "$ARTIFACT/cache/data" "$ARTIFACT/cache" "$ARTIFACT"
ARTIFACT_ID=$(path_identity "$ARTIFACT")
HIBERNATE_IN="$TEST_ROOT/hibernate.in"
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache "$ARTIFACT" "$ARTIFACT_ID" \
    > "$HIBERNATE_IN"
HIBERNATE_OUT="$TEST_ROOT/hibernate.out"
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$HIBERNATE_IN" > "$HIBERNATE_OUT"
to_lines "$HIBERNATE_OUT" "$TEST_ROOT/hibernate.lines"
[[ "$(field 1 "$TEST_ROOT/hibernate.lines")" == "trashed" ]] || fail "artifact was not trashed"
TRASH_PATH=$(field 5 "$TEST_ROOT/hibernate.lines")
TRASH_ID=$(field 6 "$TEST_ROOT/hibernate.lines")
[[ ! -e "$ARTIFACT" && -d "$TRASH_PATH" ]] || fail "Trash receipt does not match filesystem"
[[ "$TRASH_ID" == "$ARTIFACT_ID" ]] || fail "Trash identity changed"
pass "automatic hibernation moves only Safe artifact and emits exact receipt"

RESTORE_IN="$TEST_ROOT/restore.in"
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" "$ARTIFACT" "$ARTIFACT_ID" "$TRASH_PATH" "$TRASH_ID" javascriptCache \
    > "$RESTORE_IN"
RESTORE_OUT="$TEST_ROOT/restore.out"
bridge_env /bin/bash "$STAGE/bin/app_project_restore.sh" \
    < "$RESTORE_IN" > "$RESTORE_OUT"
[[ -d "$ARTIFACT" && ! -e "$TRASH_PATH" ]] || fail "restore did not move exact receipt back"
[[ ! -e "$PROJECT/should-not-run" && ! -e "$ROOT_DIR/should-not-run" ]] || fail "project script ran"
pass "restore is exact, non-overwriting, and runs no project scripts"

WARNING="$PROJECT/node_modules"
mkdir -p "$WARNING/pkg"
printf 'dependency\n' > "$WARNING/pkg/data"
printf 'Signature: 8a477f597d28d172789f06886806bc55\n' > "$WARNING/CACHEDIR.TAG"
make_old "$WARNING/pkg/data" "$WARNING/CACHEDIR.TAG" "$WARNING/pkg" "$WARNING"
WARNING_ID=$(path_identity "$WARNING")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - warning dependencyNodeModules "$WARNING" "$WARNING_ID" \
    > "$TEST_ROOT/warning.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/warning.in" > "$TEST_ROOT/warning.out" 2> "$TEST_ROOT/warning.err"
warning_status=$?
set -e
[[ "$warning_status" -ne 0 && -d "$WARNING" ]] || fail "automatic Warning dependency was moved"
pass "automatic hibernation refuses Warning dependencies"

printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" manual - warning dependencyNodeModules "$WARNING" "$WARNING_ID" \
    > "$TEST_ROOT/warning-manual.in"
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/warning-manual.in" > "$TEST_ROOT/warning-manual.out"
to_lines "$TEST_ROOT/warning-manual.out" "$TEST_ROOT/warning-manual.lines"
WARNING_TRASH=$(field 5 "$TEST_ROOT/warning-manual.lines")
WARNING_TRASH_ID=$(field 6 "$TEST_ROOT/warning-manual.lines")
[[ -d "$WARNING_TRASH" && ! -e "$WARNING" ]] || fail "manual Warning dependency was not moved"
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" "$WARNING" "$WARNING_ID" \
    "$WARNING_TRASH" "$WARNING_TRASH_ID" dependencyNodeModules > "$TEST_ROOT/warning-restore.in"
bridge_env /bin/bash "$STAGE/bin/app_project_restore.sh" \
    < "$TEST_ROOT/warning-restore.in" > "$TEST_ROOT/warning-restore.out"
[[ -d "$WARNING" ]] || fail "manual Warning dependency receipt did not restore"
pass "CACHEDIR.TAG cannot promote dependencies above Warning"

INACTIVITY_ARTIFACT="$PROJECT/.pytest_cache"
mkdir -p "$INACTIVITY_ARTIFACT"
printf 'cache\n' > "$INACTIVITY_ARTIFACT/data"
make_old "$INACTIVITY_ARTIFACT/data" "$INACTIVITY_ARTIFACT"
INACTIVITY_ID=$(path_identity "$INACTIVITY_ARTIFACT")
INACTIVITY_CUTOFF=$((DEEP_SOURCE_MTIME - 1))
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic "$INACTIVITY_CUTOFF" safe pythonCache \
    "$INACTIVITY_ARTIFACT" "$INACTIVITY_ID" > "$TEST_ROOT/inactivity.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/inactivity.in" > "$TEST_ROOT/inactivity.out" 2> "$TEST_ROOT/inactivity.err"
inactivity_status=$?
set -e
[[ "$inactivity_status" -ne 0 && -d "$INACTIVITY_ARTIFACT" ]] ||
    fail "project activity newer than the trigger cutoff was ignored"
pass "project inactivity cutoff is rechecked by the mutation bridge"

ACTIVE_ARTIFACT="$PROJECT/.turbo"
mkdir -p "$ACTIVE_ARTIFACT"
printf 'cache\n' > "$ACTIVE_ARTIFACT/data"
make_old "$ACTIVE_ARTIFACT/data" "$ACTIVE_ARTIFACT"
ACTIVE_ID=$(path_identity "$ACTIVE_ARTIFACT")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache "$ACTIVE_ARTIFACT" "$ACTIVE_ID" \
    > "$TEST_ROOT/active.in"
set +e
TEST_LSOF="$ACTIVE_LSOF" SM_TEST_ACTIVE_ROOT="$PROJECT" \
    bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/active.in" > "$TEST_ROOT/active.out" 2> "$TEST_ROOT/active.err"
active_status=$?
set -e
[[ "$active_status" -ne 0 && -d "$ACTIVE_ARTIFACT" ]] || fail "active project artifact was moved"
pass "running project protection fails closed"

TRANSIENT_ARTIFACT="$PROJECT/.ruff_cache"
mkdir -p "$TRANSIENT_ARTIFACT"
printf 'cache\n' > "$TRANSIENT_ARTIFACT/data"
make_old "$TRANSIENT_ARTIFACT/data" "$TRANSIENT_ARTIFACT"
TRANSIENT_ID=$(path_identity "$TRANSIENT_ARTIFACT")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe pythonCache \
    "$TRANSIENT_ARTIFACT" "$TRANSIENT_ID" > "$TEST_ROOT/transient.in"
/bin/rm -f "$TEST_ROOT/lsof-transient-count"
set +e
TEST_LSOF="$TRANSIENT_LSOF" SM_TEST_ACTIVE_ROOT="$PROJECT" \
    SM_TEST_LSOF_COUNT_FILE="$TEST_ROOT/lsof-transient-count" \
    bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/transient.in" > "$TEST_ROOT/transient.out" 2> "$TEST_ROOT/transient.err"
transient_status=$?
set -e
[[ "$transient_status" -ne 0 && -d "$TRANSIENT_ARTIFACT" ]] ||
    fail "project becoming active at the final Trash edge was moved"
pass "project activity is checked again at the final Trash edge"

MODEL_ARTIFACT="$PROJECT/.parcel-cache"
MODEL_PAYLOAD="$MODEL_ARTIFACT/a/b/c/d/e/f/g/h/i/model.gguf"
mkdir -p "${MODEL_PAYLOAD%/*}"
printf 'model\n' > "$MODEL_PAYLOAD"
make_old "$MODEL_PAYLOAD" "$MODEL_ARTIFACT"
MODEL_ID=$(path_identity "$MODEL_ARTIFACT")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache "$MODEL_ARTIFACT" "$MODEL_ID" \
    > "$TEST_ROOT/model.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/model.in" > "$TEST_ROOT/model.out" 2> "$TEST_ROOT/model.err"
model_status=$?
set -e
[[ "$model_status" -ne 0 && -d "$MODEL_ARTIFACT" ]] || fail "model-containing cache was moved"
pass "AI model content is excluded from automation"

SESSION_ARTIFACT="$PROJECT/.svelte-kit"
mkdir -p "$SESSION_ARTIFACT/a/.local/share/opencode/project" \
    "$SESSION_ARTIFACT/b/.gemini/tmp" "$SESSION_ARTIFACT/c/.cache/torch"
printf 'session\n' > "$SESSION_ARTIFACT/a/.local/share/opencode/project/state"
make_old "$SESSION_ARTIFACT/a/.local/share/opencode/project/state" "$SESSION_ARTIFACT"
SESSION_ID=$(path_identity "$SESSION_ARTIFACT")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache \
    "$SESSION_ARTIFACT" "$SESSION_ID" > "$TEST_ROOT/session.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/session.in" > "$TEST_ROOT/session.out" 2> "$TEST_ROOT/session.err"
session_status=$?
set -e
[[ "$session_status" -ne 0 && -d "$SESSION_ARTIFACT" ]] ||
    fail "AI session or model-cache content was moved"
pass "AI sessions and model caches remain Protected inside project artifacts"

GENERIC_SESSION_ARTIFACT="$PROJECT/.nuxt"
mkdir -p "$GENERIC_SESSION_ARTIFACT/sessions" "$GENERIC_SESSION_ARTIFACT/models"
printf 'session\n' > "$GENERIC_SESSION_ARTIFACT/sessions/current.json"
printf 'model\n' > "$GENERIC_SESSION_ARTIFACT/models/custom.bin"
make_old "$GENERIC_SESSION_ARTIFACT/sessions/current.json" \
    "$GENERIC_SESSION_ARTIFACT/models/custom.bin" "$GENERIC_SESSION_ARTIFACT"
GENERIC_SESSION_ID=$(path_identity "$GENERIC_SESSION_ARTIFACT")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache \
    "$GENERIC_SESSION_ARTIFACT" "$GENERIC_SESSION_ID" > "$TEST_ROOT/generic-session.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/generic-session.in" > "$TEST_ROOT/generic-session.out" \
    2> "$TEST_ROOT/generic-session.err"
generic_session_status=$?
set -e
[[ "$generic_session_status" -ne 0 && \
   -e "$GENERIC_SESSION_ARTIFACT/sessions/current.json" && \
   -e "$GENERIC_SESSION_ARTIFACT/models/custom.bin" ]] || \
    fail "generic session/model content was moved by automatic hibernation"
pass "generic session and model directories remain Protected in hibernation"

printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache "$PROJECT/.git" "0:0:0" \
    > "$TEST_ROOT/git.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/git.in" > "$TEST_ROOT/git.out" 2> "$TEST_ROOT/git.err"
git_status=$?
set -e
[[ "$git_status" -ne 0 ]] || fail ".git request was accepted"
pass "project root and .git cannot enter hibernation"

NO_CLOBBER="$PROJECT/.next"
make_old "$NO_CLOBBER/cache/data" "$NO_CLOBBER/cache" "$NO_CLOBBER"
NO_CLOBBER_ID=$(path_identity "$NO_CLOBBER")
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" automatic - safe javascriptCache "$NO_CLOBBER" "$NO_CLOBBER_ID" \
    > "$TEST_ROOT/no-clobber-hibernate.in"
bridge_env /bin/bash "$STAGE/bin/app_project_hibernate.sh" \
    < "$TEST_ROOT/no-clobber-hibernate.in" > "$TEST_ROOT/no-clobber-hibernate.out"
to_lines "$TEST_ROOT/no-clobber-hibernate.out" "$TEST_ROOT/no-clobber-hibernate.lines"
NO_CLOBBER_TRASH=$(field 5 "$TEST_ROOT/no-clobber-hibernate.lines")
NO_CLOBBER_TRASH_ID=$(field 6 "$TEST_ROOT/no-clobber-hibernate.lines")
mkdir -p "$NO_CLOBBER"
printf 'new data\n' > "$NO_CLOBBER/new-data"
printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$PROJECT" "$ROOT_ID" "$NO_CLOBBER" "$NO_CLOBBER_ID" \
    "$NO_CLOBBER_TRASH" "$NO_CLOBBER_TRASH_ID" javascriptCache > "$TEST_ROOT/no-clobber-restore.in"
set +e
bridge_env /bin/bash "$STAGE/bin/app_project_restore.sh" \
    < "$TEST_ROOT/no-clobber-restore.in" > "$TEST_ROOT/no-clobber-restore.out" 2> "$TEST_ROOT/no-clobber-restore.err"
restore_status=$?
set -e
[[ "$restore_status" -ne 0 && -f "$NO_CLOBBER/new-data" && -d "$NO_CLOBBER_TRASH" ]] ||
    fail "restore overwrote a recreated target"
pass "restore refuses overwrite and retains Trash source"

MISSING="$TEST_ROOT/missing-location"
printf '%s\0' "$MISSING" | bridge_env /bin/bash "$STAGE/bin/app_project_radar.sh" \
    > "$TEST_ROOT/missing.out"
to_lines "$TEST_ROOT/missing.out" "$TEST_ROOT/missing.lines"
[[ "$(field 1 "$TEST_ROOT/missing.lines")" == "location" &&
   "$(field 3 "$TEST_ROOT/missing.lines")" == "unavailable" ]] ||
    fail "missing saved location was dropped"
pass "missing saved locations remain visible as unavailable"

DEEP_LOCATION="$TEST_ROOT/deep-location"
DEEP_PROJECT="$DEEP_LOCATION/a/b/c/d/e/f/project"
DEEP_ARTIFACT="$DEEP_PROJECT/one/two/three/four/five/six/seven/.next"
mkdir -p "$DEEP_ARTIFACT"
printf '{"name":"deep"}\n' > "$DEEP_PROJECT/package.json"
printf 'deep cache\n' > "$DEEP_ARTIFACT/data"
printf '%s\0' "$DEEP_LOCATION" | bridge_env /bin/bash "$STAGE/bin/app_project_radar.sh" \
    > "$TEST_ROOT/deep-radar.out"
to_lines "$TEST_ROOT/deep-radar.out" "$TEST_ROOT/deep-radar.lines"
grep -Fqx "$DEEP_PROJECT" "$TEST_ROOT/deep-radar.lines" ||
    fail "project radar silently truncated a project below depth five"
grep -Fqx "$DEEP_ARTIFACT" "$TEST_ROOT/deep-radar.lines" ||
    fail "project radar silently truncated an artifact below depth seven"
pass "project radar discovers deep monorepo projects and generated artifacts"

EXTERNAL_PROJECT=$(mktemp -d /private/tmp/simple-mole-external.XXXXXX)
mkdir -p "$EXTERNAL_PROJECT/.next"
printf '{"name":"external"}\n' > "$EXTERNAL_PROJECT/package.json"
printf 'external cache\n' > "$EXTERNAL_PROJECT/.next/data"

SAVED_SCOPE="$TEST_ROOT/saved-scope"
INSIDE_PROJECT="$SAVED_SCOPE/inside"
mkdir -p "$INSIDE_PROJECT/.next"
printf '{"name":"inside"}\n' > "$INSIDE_PROJECT/package.json"
printf 'inside cache\n' > "$INSIDE_PROJECT/.next/data"

# With a line-based marker protocol this component forges a second line whose
# text is the absolute external project path. NUL records must keep it one path,
# and scope validation must reject it because the physical root contains LF.
NEWLINE_PARENT="$SAVED_SCOPE/injected"$'\n'
SHADOW_EXTERNAL="${NEWLINE_PARENT}${EXTERNAL_PROJECT}"
mkdir -p "$SHADOW_EXTERNAL"
printf '{"name":"forged"}\n' > "$SHADOW_EXTERNAL/package.json"

printf '%s\0' "$SAVED_SCOPE" | bridge_env /bin/bash "$STAGE/bin/app_project_radar.sh" \
    > "$TEST_ROOT/scoped-radar.out"
nul_has_project "$INSIDE_PROJECT" "$TEST_ROOT/scoped-radar.out" ||
    fail "valid in-scope project was not discovered"
if nul_has_project "$EXTERNAL_PROJECT" "$TEST_ROOT/scoped-radar.out"; then
    fail "newline component forged a project outside the saved location"
fi
pass "project discovery is NUL-safe and confined to its saved location"

echo "Project automation bridge tests passed: $pass_count"
