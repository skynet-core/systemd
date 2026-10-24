#!/usr/bin/bash
# host_verify_links.sh — runs on the HOST after `docker cp`-ing a directory
# out of a running container. Reads the symlinks that the entrypoint created
# and prints a summary that the test harness can grep.
#
# Args:
#   $1 = extracted directory (containing `system/` with the systemd layout)
#   $2 = expected target unit name (e.g. "skynet-custom.target")
#   $3 = space-separated list of expected wants (e.g. "skynet-svc-one.service skynet-svc-two.service")
set -euo pipefail

DIR="${1:?missing DIR}"
TARGET="${2:?missing TARGET}"
WANTS="${3:?missing WANTS}"
SYSTEM_DIR="${DIR}/system"
DEFAULT_LINK="${SYSTEM_DIR}/default.target"
WANTS_DIR="${SYSTEM_DIR}/default.target.wants"

fail() { printf '[host-verify] FAIL: %s\n' "$*" >&2; exit 1; }

# 1. default.target must be a symlink resolving to the expected target.
[[ -L "$DEFAULT_LINK" ]] || fail "default.target is not a symlink"
resolved="$(readlink -f "$DEFAULT_LINK")"
case "$resolved" in
  *"/${TARGET}") : ;;
  *) fail "default.target resolves to $resolved, expected */${TARGET}" ;;
esac
printf '[host-verify] OK: default.target -> %s\n' "$resolved"

# 2. every expected want must be present as a symlink in wants dir.
[[ -d "$WANTS_DIR" ]] || fail "wants dir missing: $WANTS_DIR"
IFS=' ' read -r -a arr <<< "$WANTS"
for want in "${arr[@]}"; do
  [[ -z "$want" ]] && continue
  link="${WANTS_DIR}/${want}"
  [[ -L "$link" ]] || fail "wants link missing: $link"
  printf '[host-verify] OK: %s -> %s\n' "$link" "$(readlink -f "$link")"
done

# 3. dump the full wants dir for the record.
echo '[host-verify] wants dir listing:'
ls -l "$WANTS_DIR" | sed 's/^/[host-verify]   /'
