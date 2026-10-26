#!/usr/bin/bash
# verify.sh — run INSIDE a live container (via `docker/podman exec`) where
# systemd is PID 1, to prove the entrypoint did what we asked.
#
# Expects these env vars (they are the SAME ones passed to `run`):
#   SYSTEMD_INIT_TARGET          target that should be active now
#   SYSTEMD_INIT_TARGET_WANTS    space- or comma-separated services to check
#   SYSTEMD_MASKED               space- or comma-separated units to check
#
# Prints a summary prefixed with [verify] and exits 0 on success, 1 on failure.
set -uo pipefail

log()  { printf '[verify] %s\n'     "$*" >&2; }
fail() { printf '[verify] FAIL: %s\n' "$*" >&2; exit 1; }

TARGET="${SYSTEMD_INIT_TARGET:-}"
WANTS="${SYSTEMD_INIT_TARGET_WANTS:-}"
[[ -n "$TARGET" ]] || fail "SYSTEMD_INIT_TARGET not set"

check_target() {
  log "checking target is-active: $TARGET"
  local state; state="$(systemctl is-active "$TARGET" 2>&1)"
  log "  state: $state"
  [[ "$state" == "active" ]] || fail "target $TARGET is not active (state=$state)"
}

check_services() {
  local want state idx=0 count
  IFS=', ' read -r -a arr <<< "$WANTS"
  count=0; for w in "${arr[@]}"; do [[ -n "$w" ]] && count=$((count+1)); done
  for want in "${arr[@]}"; do
    [[ -z "$want" ]] && continue
    idx=$((idx+1))
    state="$(systemctl is-active "$want" 2>&1)"
    log "  service $idx/$count: $want => $state"
    [[ "$state" == "active" ]] || fail "service $want not active (state=$state)"
  done
}

check_symlinks() {
  local link="/etc/systemd/system/default.target"
  [[ -L "$link" ]] || fail "default.target is not a symlink"
  local resolved; resolved="$(readlink -f "$link")"
  log "  default.target -> $resolved"
  case "$resolved" in
    */"$TARGET") : ;;
    *) fail "default.target does not resolve to */$TARGET (got $resolved)" ;;
  esac

  if [[ -n "$WANTS" ]]; then
    local wants_dir="/etc/systemd/system/default.target.wants"
    [[ -d "$wants_dir" ]] || fail "$wants_dir missing"
    local want name
    IFS=', ' read -r -a arr2 <<< "$WANTS"
    for want in "${arr2[@]}"; do
      [[ -z "$want" ]] && continue
      name="${want##*/}"
      [[ -L "${wants_dir}/${name}" ]] || fail "wants link missing: ${wants_dir}/${name}"
      log "  wants: ${name} -> $(readlink -f "${wants_dir}/${name}")"
    done
  fi
}

check_masked() {
  local item name state enabled_link start_output
  local -a masks
  IFS=', ' read -r -a masks <<< "${SYSTEMD_MASKED:-}"
  for item in "${masks[@]}"; do
    [[ -z "$item" ]] && continue
    name="$(systemctl show --property=Id --value "${item##*/}")"
    state="$(systemctl is-enabled "$name" 2>&1)"
    log "  masked: $name => $state"
    [[ "$state" == "masked" ]] || fail "$name is not masked (state=$state)"
    state="$(systemctl is-active "$name" 2>&1)"
    log "  active state: $name => $state"
    [[ "$state" == "inactive" ]] || fail "$name is active"
    [[ "$(readlink "/etc/systemd/system/$name")" == "/dev/null" ]] || fail "$name has no mask symlink"
    enabled_link="$(find /etc/systemd/system -mindepth 2 -type l -name "$name" -print -quit)"
    [[ -z "$enabled_link" ]] || fail "$name is still enabled: $enabled_link"
    log "  no enablement links remain for $name"
    grep -Fxq "disable $name" /etc/systemd/system-preset/00-systemd-masked.preset || fail "$name has no disable preset"
    if start_output="$(systemctl start "$name" 2>&1)"; then
      fail "$name could still be started"
    fi
    log "  start rejected: $start_output"
    [[ "$start_output" == *masked* ]] || fail "$name start failed for another reason"
  done
}

check_target
if [[ -n "$WANTS" ]]; then check_services; fi
check_symlinks
check_masked

echo "=== VERIFY RESULT: PASS ==="
echo "  target:         $TARGET => $(systemctl is-active "$TARGET")"
if [[ -n "$WANTS" ]]; then
  IFS=', ' read -r -a arr3 <<< "$WANTS"
  for want in "${arr3[@]}"; do
    [[ -z "$want" ]] && continue
    printf '  service:      %-40s %s\n' "$want" "$(systemctl is-active "$want")"
  done
fi
echo "  default.target -> $(readlink -f /etc/systemd/system/default.target)"
exit 0
