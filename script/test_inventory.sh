#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INVENTORY_TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/simplemole-inventory-tests.XXXXXX")"
trap 'rm -rf "$INVENTORY_TEST_ROOT"' EXIT

fail() {
    echo "inventory test failed: $1" >&2
    exit 1
}

SIMULATOR_ID="11111111-1111-4111-8111-111111111111"
SIMULATOR_DECOY_ID="22222222-2222-4222-8222-222222222222"
SIMULATOR_ARGS="$INVENTORY_TEST_ROOT/simulator-args.log"
SIMULATOR_DELETES="$INVENTORY_TEST_ROOT/simulator-deletes.log"
SIMULATOR_STUB="$INVENTORY_TEST_ROOT/xcrun"
cat > "$SIMULATOR_STUB" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s' "${1:-}" >> "$SIMULATOR_ARGS"
for argument in "${@:2}"; do printf ' %s' "$argument" >> "$SIMULATOR_ARGS"; done
printf '\n' >> "$SIMULATOR_ARGS"

if [[ "$#" -eq 2 && "$1" == "--find" && "$2" == "simctl" ]]; then
    echo "/test/simctl"
elif [[ "$#" -eq 4 && "$1" == "simctl" && "$2" == "list" && "$3" == "devices" && "$4" == "--json" ]]; then
    printf '{"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-18-0":[{"name":"Test Phone","udid":"%s","state":"Shutdown","isAvailable":true}]}}\n' "$SIMULATOR_ID"
elif [[ "$#" -eq 3 && "$1" == "simctl" && "$2" == "list" && "$3" == "devices" ]]; then
    printf '== Devices ==\n-- iOS 18.0 --\n'
    if [[ -n "${SIMULATOR_DECOY_ID:-}" ]]; then
        printf '    %s (%s) (%s)\n' "${SIMULATOR_DECOY_NAME:-Decoy Phone}" \
            "$SIMULATOR_DECOY_ID" "${SIMULATOR_DECOY_STATE:-Shutdown}"
    fi
    printf '    %s (%s) (%s)\n' "${SIMULATOR_DEVICE_NAME:-Test Phone}" \
        "$SIMULATOR_ID" "${SIMULATOR_STATE:-Creating}"
elif [[ "$#" -eq 3 && "$1" == "simctl" && "$2" == "delete" && "$3" == "$SIMULATOR_ID" ]]; then
    printf '%s\n' "$3" >> "$SIMULATOR_DELETES"
else
    echo "unexpected xcrun arguments" >&2
    exit 91
fi
STUB
chmod +x "$SIMULATOR_STUB"

scan_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_XCRUN_BIN="$SIMULATOR_STUB" \
    SIMULATOR_ARGS="$SIMULATOR_ARGS" SIMULATOR_DELETES="$SIMULATOR_DELETES" \
    SIMULATOR_ID="$SIMULATOR_ID" \
    bash "$ROOT_DIR/bridge/app_simulator_scan.sh")
[[ "$scan_output" == *'"devices"'* && "$scan_output" == *"$SIMULATOR_ID"* ]] || \
    fail "simulator scan did not preserve simctl JSON"
grep -Fxq 'simctl list devices --json' "$SIMULATOR_ARGS" || \
    fail "simulator scan used unexpected arguments"

printf '%s\0' "$SIMULATOR_ID" > "$INVENTORY_TEST_ROOT/simulator.plan"
delete_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_XCRUN_BIN="$SIMULATOR_STUB" \
    SIMULATOR_ARGS="$SIMULATOR_ARGS" SIMULATOR_DELETES="$SIMULATOR_DELETES" \
    SIMULATOR_ID="$SIMULATOR_ID" SIMULATOR_STATE=Shutdown \
    bash "$ROOT_DIR/bridge/app_simulator_delete.sh" < "$INVENTORY_TEST_ROOT/simulator.plan")
[[ "$delete_output" == *'removed=1'* && "$delete_output" == *'failed=0'* ]] || \
    fail "stopped simulator was not deleted after explicit submission"
grep -Fxq "$SIMULATOR_ID" "$SIMULATOR_DELETES" || \
    fail "simulator delete did not receive the selected UUID"

: > "$SIMULATOR_DELETES"
delete_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_XCRUN_BIN="$SIMULATOR_STUB" \
    SIMULATOR_ARGS="$SIMULATOR_ARGS" SIMULATOR_DELETES="$SIMULATOR_DELETES" \
    SIMULATOR_ID="$SIMULATOR_ID" SIMULATOR_STATE=Booted \
    bash "$ROOT_DIR/bridge/app_simulator_delete.sh" < "$INVENTORY_TEST_ROOT/simulator.plan")
[[ "$delete_output" == *'removed=0'* && "$delete_output" == *'skipped=1'* ]] || \
    fail "booted simulator was not protected"
[[ ! -s "$SIMULATOR_DELETES" ]] || fail "booted simulator reached the delete command"

# A device name can contain a state-looking token. Only the state immediately
# after the exact UUID may authorize the operation.
delete_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_XCRUN_BIN="$SIMULATOR_STUB" \
    SIMULATOR_ARGS="$SIMULATOR_ARGS" SIMULATOR_DELETES="$SIMULATOR_DELETES" \
    SIMULATOR_ID="$SIMULATOR_ID" SIMULATOR_STATE=Booted \
    SIMULATOR_DEVICE_NAME='Misleading (Shutdown)' \
    bash "$ROOT_DIR/bridge/app_simulator_delete.sh" < "$INVENTORY_TEST_ROOT/simulator.plan")
[[ "$delete_output" == *'removed=0'* && "$delete_output" == *'skipped=1'* ]] || \
    fail "simulator delete trusted a state-looking device name"
[[ ! -s "$SIMULATOR_DELETES" ]] || fail "state-looking device name bypassed protection"

# A different device can put the selected UUID and a fake Shutdown token in
# its name. The selected device's own Booted state must still win.
: > "$SIMULATOR_DELETES"
delete_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_XCRUN_BIN="$SIMULATOR_STUB" \
    SIMULATOR_ARGS="$SIMULATOR_ARGS" SIMULATOR_DELETES="$SIMULATOR_DELETES" \
    SIMULATOR_ID="$SIMULATOR_ID" SIMULATOR_STATE=Booted \
    SIMULATOR_DECOY_ID="$SIMULATOR_DECOY_ID" SIMULATOR_DECOY_STATE=Shutdown \
    SIMULATOR_DECOY_NAME="Decoy ($SIMULATOR_ID) (Shutdown)" \
    bash "$ROOT_DIR/bridge/app_simulator_delete.sh" < "$INVENTORY_TEST_ROOT/simulator.plan")
[[ "$delete_output" == *'removed=0'* && "$delete_output" == *'skipped=1'* ]] || \
    fail "simulator delete trusted another device name as selected-device state"
[[ ! -s "$SIMULATOR_DELETES" ]] || \
    fail "another device name sent a Booted selected device to delete"

printf 'not-a-uuid\0' > "$INVENTORY_TEST_ROOT/simulator.plan"
set +e
delete_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_XCRUN_BIN="$SIMULATOR_STUB" \
    SIMULATOR_ARGS="$SIMULATOR_ARGS" SIMULATOR_DELETES="$SIMULATOR_DELETES" \
    SIMULATOR_ID="$SIMULATOR_ID" SIMULATOR_STATE=Shutdown \
    bash "$ROOT_DIR/bridge/app_simulator_delete.sh" \
    < "$INVENTORY_TEST_ROOT/simulator.plan" 2>&1)
delete_status=$?
set -e
[[ "$delete_status" -ne 0 && "$delete_output" == *'failed=1'* ]] || \
    fail "simulator delete accepted a malformed identifier"
if grep -Eiq 'simctl (shutdown|erase)($| )' "$SIMULATOR_ARGS"; then
    fail "simulator bridge changed device runtime state"
fi

DOCKER_ARGS="$INVENTORY_TEST_ROOT/docker-args.log"
DOCKER_STUB="$INVENTORY_TEST_ROOT/docker"
cat > "$DOCKER_STUB" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s' "${1:-}" >> "$DOCKER_ARGS"
for argument in "${@:2}"; do printf ' %s' "$argument" >> "$DOCKER_ARGS"; done
printf '\n' >> "$DOCKER_ARGS"

if [[ "$#" -eq 6 && "$1" == "image" && "$2" == "ls" && "$3" == "--all" && "$4" == "--no-trunc" && "$5" == "--format" ]]; then
    echo '{"ID":"sha256:image1","Repository":"demo","Tag":"latest","Size":"1GB"}'
elif [[ "$#" -eq 7 && "$1" == "container" && "$2" == "ls" && "$3" == "--all" && "$4" == "--no-trunc" && "$5" == "--size" && "$6" == "--format" ]]; then
    echo '{"ID":"container1","Names":"demo-api","State":"running","Size":"10MB"}'
elif [[ "$#" -eq 4 && "$1" == "volume" && "$2" == "ls" && "$3" == "--format" ]]; then
    echo '{"Name":"demo-volume","Driver":"local"}'
elif [[ "$#" -eq 4 && "$1" == "builder" && "$2" == "du" && "$3" == "--format" ]]; then
    echo '{"ID":"cache1","Description":"build cache","Size":"2GB","InUse":false}'
elif [[ "$#" -eq 2 && "$1" == "system" && "$2" == "df" ]]; then
    cat <<'DF'
TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE
Images          7         2         3.1GB     1.2GB (38%)
Containers      3         1         400MB     300MB (75%)
Local Volumes   5         1         9GB       7GB (77%)
Build Cache     12        0         4GB       4GB
DF
else
    echo "unexpected Docker arguments" >&2
    exit 92
fi
STUB
chmod +x "$DOCKER_STUB"

for kind in images containers volumes build-cache; do
    details_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_DOCKER_BIN="$DOCKER_STUB" \
        DOCKER_ARGS="$DOCKER_ARGS" bash "$ROOT_DIR/bridge/app_docker_details.sh" "$kind")
    [[ "$details_output" == "$kind"$'\t''{'* ]] || \
        fail "Docker $kind inventory was not emitted as prefixed JSON"
done

set +e
env MOLE_TEST_MODE=1 MOLE_TEST_DOCKER_BIN="$DOCKER_STUB" DOCKER_ARGS="$DOCKER_ARGS" \
    bash "$ROOT_DIR/bridge/app_docker_details.sh" arbitrary >/dev/null 2>&1
docker_unknown_status=$?
set -e
[[ "$docker_unknown_status" -eq 2 ]] || fail "Docker inventory accepted an unknown mode"

set +e
docker_missing_output=$(env MOLE_TEST_MODE=1 \
    MOLE_TEST_DOCKER_BIN="$INVENTORY_TEST_ROOT/missing-docker" \
    bash "$ROOT_DIR/bridge/app_docker_details.sh" images 2>&1)
docker_missing_status=$?
set -e
[[ "$docker_missing_status" -eq 127 && "$docker_missing_output" == *"unavailable"* ]] || \
    fail "missing Docker CLI was indistinguishable from an empty inventory"

df_output=$(env MOLE_TEST_MODE=1 MOLE_TEST_DOCKER_BIN="$DOCKER_STUB" \
    DOCKER_ARGS="$DOCKER_ARGS" bash "$ROOT_DIR/bridge/app_docker_df.sh")
[[ "$df_output" == *$'Local Volumes\t5\t9GB\t7GB (77%)'* ]] || \
    fail "Docker summary split the Local Volumes type"
[[ "$df_output" == *$'Build Cache\t12\t4GB\t4GB'* ]] || \
    fail "Docker summary split the Build Cache type"
if grep -Eiq '(^| )(prune|rm|rmi|exec)($| )' "$DOCKER_ARGS"; then
    fail "Docker inventory invoked a mutating command"
fi

if [[ "${SM_TEST_SKIP_SWIFT:-0}" != "1" ]]; then
    architecture="$(uname -m)"
    mkdir -p "$INVENTORY_TEST_ROOT/module-cache" "$INVENTORY_TEST_ROOT/parser-fixture"
    swiftc -DINVENTORY_PARSER_TESTS -target "$architecture-apple-macos13.0" \
        -module-cache-path "$INVENTORY_TEST_ROOT/module-cache" \
        "$ROOT_DIR/SimpleMole/Services/SimulatorInventory.swift" \
        "$ROOT_DIR/SimpleMole/Services/DockerInventory.swift" \
        "$ROOT_DIR/script/InventoryTests.swift" \
        -o "$INVENTORY_TEST_ROOT/inventory-tests"
    "$INVENTORY_TEST_ROOT/inventory-tests" "$INVENTORY_TEST_ROOT/parser-fixture"
fi

echo "inventory bridge and parser tests passed"
