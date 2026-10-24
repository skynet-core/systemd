#!/usr/bin/bash
#
# test.sh - build the image and run the test cases against docker or podman.
#
# Usage:
#   ./test.sh                       # docker, all tests
#   RUNTIME=podman ./test.sh        # podman
#   RUNTIME=docker TESTS=1 2 ./test.sh
#
# Each test:
#   - launches a detached container with --privileged --ipc=host
#   - mounts ./test as /etc/systemd/system so fixture units are visible
#   - sets SYSTEMD_INIT_TARGET and/or SYSTEMD_INIT_TARGET_WANTS
#   - waits for the target to become active (up to WAIT_TIMEOUT seconds)
#   - runs test/verify.sh via `exec` to assert target + services + symlinks
#   - always tears the container down (docker rm -f)
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TEST_DIR="${SCRIPT_DIR}"
IMAGE_TAG="${IMAGE_TAG:-systemd:local-test}"
IMAGE_NAME="${IMAGE_NAME:-skynet-systemd}"
RUNTIME="${RUNTIME:-docker}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-90}"
DOCKERFILE="${DOCKERFILE:-${REPO_ROOT}/Dockerfile.fedora-44}"
CONTEXT="${CONTEXT:-${REPO_ROOT}}"
SKIP_BUILD="${SKIP_BUILD:-false}"

# ---------------------------------------------------------------------------
# Colours + counters
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_GREEN=$'\033[32m'
    C_RED=$'\033[31m'
    C_YELLOW=$'\033[33m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_GREEN='' C_RED='' C_YELLOW='' C_BOLD='' C_RESET=''
fi
PASS=0
FAIL=0
declare -a PASSED_TESTS=() FAILED_TESTS=() SKIPPED_TESTS=()

info() { printf '%s[test]%s %s\n' "$C_BOLD" "$C_RESET" "$*" >&2; }
ok() { printf '%s[test] PASS%s %s\n' "$C_GREEN" "$C_RESET" "$*" >&2; }
bad() { printf '%s[test] FAIL%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
skip() { printf '%s[test] SKIP%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RUNTIME_BIN="$RUNTIME"
command -v "$RUNTIME_BIN" >/dev/null 2>&1 ||
    {
        bad "runtime '$RUNTIME' not on PATH"
        exit 2
    }

log() { printf '%s\n' "$*" >&2; }

# start_container <label> [-e NAME=VALUE ...]
#   Starts a detached container and echoes its ID to stdout.
#   Every extra arg must be a `-e NAME=VALUE` pair; it is passed to `run -e`
#   (i.e. becomes a real environment variable for the container, NOT a CMD arg).
start_container() {
    local label="$1"
    shift
    local env_flags=("$@")
    local slug
    slug="$(printf '%s' "$label" | tr -c 'a-zA-Z0-9_.-' '-' | sed 's/^-//')"
    local id
    id="$("$RUNTIME_BIN" run -d \
        --name "skynet-${slug}-$$-$RANDOM" \
        --privileged --ipc=host \
        --tmpfs /tmp:rw,size=64m \
        -v "${TEST_DIR}/skynet-custom.target:/etc/systemd/system/skynet-custom.target:ro" \
        -v "${TEST_DIR}/skynet-svc-one.service:/etc/systemd/system/skynet-svc-one.service:ro" \
        -v "${TEST_DIR}/skynet-svc-two.service:/etc/systemd/system/skynet-svc-two.service:ro" \
        -v "${SCRIPT_DIR}:/opt/skynet-test:ro" \
        "${env_flags[@]}" \
        "${IMAGE_TAG}" \
        2>&1)" ||
        {
            log "$id"
            return 1
        }
    echo "$id"
}

wait_for_active() {
    local id="$1" target="$2" deadline
    deadline=$((SECONDS + WAIT_TIMEOUT))
    while ((SECONDS < deadline)); do
        state="$("$RUNTIME_BIN" exec "$id" systemctl is-active "$target" 2>&1 || true)"
        [[ "$state" == "active" ]] && return 0
        sleep 1
    done
    "$RUNTIME_BIN" logs "$id" 2>&1 | tail -n 40 | sed 's/^/[container] /' >&2
    return 1
}

teardown() {
    local id="$1"
    "$RUNTIME_BIN" rm -f "$id" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Helpers to inspect the container's filesystem from the host.
# ---------------------------------------------------------------------------

# dump_container_state <id> <target>
#   Prints the default.target symlink and wants dirs to stderr.
dump_container_state() {
    local id="$1" target="$2"
    local out
    out="$("$RUNTIME_BIN" exec "$id" bash -c '
    echo "  default.target: $(ls -l /etc/systemd/system/default.target 2>&1)"
    echo "  default.target.wants:"
    ls -l /etc/systemd/system/default.target.wants 2>&1 | sed "s/^/    /"
    if [[ -d /etc/systemd/system/'"${target}"' ]]; then
      echo "  '"${target}"' dir:"
      ls -l /etc/systemd/system/'"${target}"' 2>&1 | sed "s/^/    /"
    fi
    echo "  all .target.wants dirs:"
    find /etc/systemd/system -maxdepth 1 -type d -name "*.target.wants" -exec ls -ld {} \; 2>&1 | sed "s/^/    /"
  ' 2>&1)"
    printf '%s\n' "$out" >&2
}

# run_test <label> <expected-target> <expected-wants> <env...>
#   Success path: container runs, target becomes active, services active,
#   symlinks created correctly.
run_test() {
    local label="$1" target="$2" wants="$3"
    shift 3
    local id
    info "[$label] starting: $target ${wants:+wants=$wants}"
    id="$(start_container "$label" "$@")" ||
        {
            bad "$label (container start)"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$label")
            return
        }
    info "[$label] container id: $id"

    local rc=0
    if ! wait_for_active "$id" "$target"; then
        bad "$label — target '$target' did not become active within ${WAIT_TIMEOUT}s"
        dump_container_state "$id" "$target"
        "$RUNTIME_BIN" logs --tail 80 "$id" 2>&1 | sed 's/^/[logs] /' >&2
        rc=1
    else
        if ! "$RUNTIME_BIN" exec \
            -e SYSTEMD_INIT_TARGET="$target" \
            -e SYSTEMD_INIT_TARGET_WANTS="$wants" \
            "$id" /opt/skynet-test/verify.sh; then
            bad "$label — verify.sh reported failures"
            dump_container_state "$id" "$target"
            rc=1
        fi
    fi

    teardown "$id"
    if ((rc == 0)); then
        ok "$label"
        PASS=$((PASS + 1))
        PASSED_TESTS+=("$label")
    else
        bad "$label"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$label")
    fi
}

# run_fail_test <label> <expected-error-substring> <env...>
#   Failure path: entrypoint must die fast with a recognizable error, and the
#   container must not be running when the check completes.
run_fail_test() {
    local label="$1" needle="$2"
    shift 2
    local id
    info "[$label] starting (expected to fail)"
    id="$(start_container "$label" "$@")" ||
        {
            bad "$label (container start)"
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("$label")
            return
        }
    info "[$label] container id: $id"

    # Wait for the container to exit (it should die within seconds because the
    # entrypoint's `die` exits the shell before exec'ing systemd).
    local deadline=$((SECONDS + 20)) state
    while ((SECONDS < deadline)); do
        state="$("$RUNTIME_BIN" inspect --format '{{.State.Status}}' "$id" 2>/dev/null || true)"
        [[ "$state" == "exited" ]] && break
        sleep 0.5
    done

    local rc=0
    if [[ "$state" != "exited" ]]; then
        bad "$label — container is still in state '$state' (expected exited)"
        "$RUNTIME_BIN" logs --tail 80 "$id" 2>&1 | sed 's/^/[logs] /' >&2
        rc=1
    else
        local logs
        logs="$("$RUNTIME_BIN" logs "$id" 2>&1)"
        if grep -qF "$needle" <<<"$logs"; then
            ok "$label — expected error present: \"$needle\""
        else
            bad "$label — expected \"$needle\" in logs but it was not found"
            printf '%s\n' "$logs" | tail -n 40 | sed 's/^/[logs] /' >&2
            rc=1
        fi
        local exit_code
        exit_code="$("$RUNTIME_BIN" inspect --format '{{.State.ExitCode}}' "$id" 2>/dev/null || echo '?')"
        info "[$label] exit code: $exit_code"
        ((exit_code != 0)) || {
            bad "$label — expected non-zero exit, got $exit_code"
            rc=1
        }
    fi

    teardown "$id"
    if ((rc == 0)); then
        ok "$label"
        PASS=$((PASS + 1))
        PASSED_TESTS+=("$label")
    else
        bad "$label"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$label")
    fi
}

# ---------------------------------------------------------------------------
# Build the image once before running tests (skippable via SKIP_BUILD=true,
# e.g. when CI built the image separately).
# ---------------------------------------------------------------------------
case "${SKIP_BUILD}" in
true | yes | on | 1)
    info "SKIP_BUILD=${SKIP_BUILD}; assuming ${IMAGE_TAG} already exists"
    ;;
*)
    info "building ${IMAGE_TAG} from ${DOCKERFILE} (context: ${CONTEXT})"
    if ! "$RUNTIME_BIN" build \
        --file "$DOCKERFILE" \
        --tag "$IMAGE_TAG" \
        --label "org.opencontainers.image.title=skynet-systemd" \
        --label "org.opencontainers.image.description=systemd-based image for skynet" \
        "$CONTEXT"; then
        bad "image build failed"
        exit 1
    fi
    ok "image ${IMAGE_TAG} built"
    ;;
esac

# ---------------------------------------------------------------------------
# Test cases
# ---------------------------------------------------------------------------
#  1. Custom target is the default init target; no wants.
#  2. Custom target + two wants (space-separated).
#  3. Custom target + two wants (comma-separated).
#  4. Bare target name (no `.target` extension).
#  5. Bare service names (no `.service` extension).
#  6. Unknown target — entrypoint must die fast with a recognizable error.
#  7. Unknown wanted service — target still boots, warning logged.

run_test "custom target is default (no wants)" \
    "skynet-custom.target" "" \
    -e SYSTEMD_INIT_TARGET=skynet-custom.target

run_test "custom target + two wants (space-separated)" \
    "skynet-custom.target" "skynet-svc-one.service skynet-svc-two.service" \
    -e SYSTEMD_INIT_TARGET=skynet-custom.target \
    -e SYSTEMD_INIT_TARGET_WANTS="skynet-svc-one.service skynet-svc-two.service"

run_test "custom target + two wants (comma-separated)" \
    "skynet-custom.target" "skynet-svc-one.service skynet-svc-two.service" \
    -e SYSTEMD_INIT_TARGET=skynet-custom.target \
    -e SYSTEMD_INIT_TARGET_WANTS="skynet-svc-one.service,skynet-svc-two.service"

run_test "bare target name (no .target extension)" \
    "skynet-custom.target" "" \
    -e SYSTEMD_INIT_TARGET=skynet-custom

run_test "bare service names (no .service extension)" \
    "skynet-custom.target" "skynet-svc-one.service skynet-svc-two.service" \
    -e SYSTEMD_INIT_TARGET=skynet-custom.target \
    -e SYSTEMD_INIT_TARGET_WANTS="skynet-svc-one skynet-svc-two"

run_fail_test "unknown target (expect fail-fast)" \
    "does not resolve to a unit file" \
    -e SYSTEMD_INIT_TARGET=does-not-exist.target

run_test "unknown wanted service (warning, target still active)" \
    "skynet-custom.target" "skynet-svc-one.service" \
    -e SYSTEMD_INIT_TARGET=skynet-custom.target \
    -e SYSTEMD_INIT_TARGET_WANTS="skynet-svc-one.service,does-not-exist.service"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
printf '\n%s==================== SUMMARY ====================\n' "$C_BOLD"
printf '%s runtime:   %s\n' "" "$RUNTIME"
printf '%s image:     %s\n' "" "$IMAGE_TAG"
printf '%s passed:    %d\n' "$C_GREEN" "$PASS"
printf '%s failed:    %d\n' "$C_RED" "$FAIL"
if ((${#SKIPPED_TESTS[@]})); then
    printf '%s skipped:   %d\n' "$C_YELLOW" "${#SKIPPED_TESTS[@]}"
fi
((${#PASSED_TESTS[@]})) && printf '  passed:   %s\n' "${PASSED_TESTS[*]}"
((${#FAILED_TESTS[@]})) && printf '  failed:   %s\n' "${FAILED_TESTS[*]}"
((${#SKIPPED_TESTS[@]})) && printf '  skipped:  %s\n' "${SKIPPED_TESTS[*]}"
printf '%s===================================================\n' ""
((FAIL == 0))
