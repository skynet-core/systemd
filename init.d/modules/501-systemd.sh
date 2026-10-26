#!/usr/bin/bash
#
# entrypoint.sh - configure systemd defaults before handing over to init.
#
# Environment variables:
#   SYSTEMD_INIT_TARGET
#       Name (or path) of the unit to run as the default init target.
#       If a unit type extension (.target/.service/.socket/.path/.timer)
#       is missing, ".target" is assumed. The resolved unit is linked as
#       /etc/systemd/system/default.target so `init` starts it.
#
#   SYSTEMD_INIT_TARGET_WANTS
#       Comma- and/or space separated list of units to enable into
#       /etc/systemd/system/default.target.wants/. A missing ".service"
#       extension is assumed. Units that cannot be found are skipped with
#       a warning (so a typo never blocks boot).
#
#   SYSTEMD_MASKED
#       Comma- and/or space separated list of units to disable via presets
#       and mask before boot. A missing ".service" extension is assumed.
#       Units that cannot be found are skipped with a warning.
#
# After configuration the entrypoint hands the PID 1 slot to systemd via
# `exec`, so all signals (e.g. SIGRTMIN+3 / STOPSIGNAL) reach systemd.
#
set -euo pipefail

: "${MODULE_SYSTEMD_ENABLED:=false}"
: "${SYSTEMD_SYSTEM_DIR:=/etc/systemd/system}"
: "${DEFAULT_TARGET_LINK:=${SYSTEMD_SYSTEM_DIR}/default.target}"

# List of unit search paths, in the order systemd prefers them.
# shellcheck disable=SC2034
readonly UNIT_SEARCH_PATHS=(
	"/etc/systemd/system"
	"/run/systemd/system"
	"/usr/local/lib/systemd/system"
	"/usr/lib/systemd/system"
	"/lib/systemd/system"
)

module_systemd_enabled() {
	is_true "$MODULE_SYSTEMD_ENABLED"
}

module_systemd_run() {
	# ---------------------------------------------------------------------------
	# 1. SYSTEMD_INIT_TARGET - make a custom target the default init target.
	# ---------------------------------------------------------------------------
	if [[ -n "${SYSTEMD_INIT_TARGET:-}" ]]; then
		raw_target="${SYSTEMD_INIT_TARGET// /}"
		target_src="$(resolve_unit "$raw_target" ".target")" ||
			die "SYSTEMD_INIT_TARGET='${SYSTEMD_INIT_TARGET}' does not resolve to a unit file"

		mkdir -p "$SYSTEMD_SYSTEM_DIR"
		ln -sfn "$target_src" "$DEFAULT_TARGET_LINK"
		info "default.init target -> ${target_src}"
	else
		info "SYSTEMD_INIT_TARGET not set; keeping existing default.target"
	fi

	# ---------------------------------------------------------------------------
	# 2. SYSTEMD_INIT_TARGET_WANTS - enable units into default.target.wants.
	#
	#    To guarantee the units start when the active target is NOT the
	#    literal `default.target` (i.e. when SYSTEMD_INIT_TARGET points at a
	#    custom target), also mirror the symlinks into <custom>.target.wants.
	# ---------------------------------------------------------------------------
	if [[ -n "${SYSTEMD_INIT_TARGET_WANTS:-}" ]]; then
		IFS=', ' read -r -a want_items <<<"${SYSTEMD_INIT_TARGET_WANTS}"

		# Primary enable dir (user's contract): /etc/systemd/system/default.target.wants
		PRIMARY_WANTS_DIR="${SYSTEMD_SYSTEM_DIR}/default.target.wants"
		mkdir -p "$PRIMARY_WANTS_DIR"

		# Secondary dir: if we set a custom target, its own .wants dir is what
		# systemd reads when that target is activated. Mirror the links there too.
		SECONDARY_WANTS_DIR=""
		if [[ -n "${SYSTEMD_INIT_TARGET:-}" ]]; then
			active_unit="$(basename "$(readlink -f "$DEFAULT_TARGET_LINK" 2>/dev/null || true)")"
			if [[ -n "$active_unit" && "$active_unit" != "default.target" && "$active_unit" != "" ]]; then
				SECONDARY_WANTS_DIR="${SYSTEMD_SYSTEM_DIR}/${active_unit%.target}.target.wants"
				mkdir -p "$SECONDARY_WANTS_DIR"
			fi
		fi

		enabled=0
		for item in "${want_items[@]}"; do
			[[ -z "$item" ]] && continue
			svc_src="$(resolve_unit "$item" ".service")" ||
				{
					warn "wanted unit '${item}' not found; skipping"
					continue
				}

			link_name="$(basename "$svc_src")"
			if [[ "$svc_src" -ef /dev/null || "${SYSTEMD_SYSTEM_DIR}/${link_name}" -ef /dev/null ]]; then
				warn "wanted unit '${item}' is masked; skipping"
				continue
			fi

			ln -sfn "$svc_src" "${PRIMARY_WANTS_DIR}/${link_name}"
			info "enabled ${link_name} in default.target.wants -> ${svc_src}"

			if [[ -n "$SECONDARY_WANTS_DIR" ]]; then
				ln -sfn "$svc_src" "${SECONDARY_WANTS_DIR}/${link_name}"
				info "enabled ${link_name} in $(basename "$SECONDARY_WANTS_DIR") -> ${svc_src}"
			fi

			enabled=$((enabled + 1))
		done

		if [[ "$enabled" -eq 0 ]]; then
			warn "SYSTEMD_INIT_TARGET_WANTS was set but no units could be resolved"
		fi
	else
		info "SYSTEMD_INIT_TARGET_WANTS not set; leaving .wants dirs untouched"
	fi

	# ---------------------------------------------------------------------------
	# 3. SYSTEMD_MASKED - disable units via presets, then prevent activation.
	# ---------------------------------------------------------------------------
	if [[ -n "${SYSTEMD_MASKED:-}" ]]; then
		local -a mask_items masked_units=()
		local mask_src preset_file="/etc/systemd/system-preset/00-systemd-masked.preset"
		IFS=', ' read -r -a mask_items <<<"${SYSTEMD_MASKED}"
		for item in "${mask_items[@]}"; do
			[[ -z "$item" ]] && continue
			mask_src="$(resolve_unit "$item" ".service")" ||
				{
					warn "masked unit '${item}' not found; skipping"
					continue
				}
			masked_units+=("$(basename "$mask_src")")
		done

		if ((${#masked_units[@]})); then
			mkdir -p "${preset_file%/*}"
			printf 'disable %s\n' "${masked_units[@]}" >"$preset_file"
			systemctl --root=/ --preset-mode=disable-only preset -- "${masked_units[@]}" ||
				die "Could not apply SYSTEMD_MASKED presets"
			systemctl --root=/ mask -- "${masked_units[@]}" ||
				die "Could not mask SYSTEMD_MASKED units"
			info "disabled and masked ${masked_units[*]}"
		fi
	fi
}
