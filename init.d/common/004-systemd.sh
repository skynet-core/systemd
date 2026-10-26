#!/usr/bin/bash

# Ensure the supplied name carries a known unit-type extension.
normalize_unit_name() {
	local name="$1"
	case "$name" in
	*.target | *.service | *.socket | *.path | *.timer | *.mount | *.device | *.scope | *.slice | *.swap | *.automount)
		printf '%s' "$name"
		;;
	*)
		printf '%s' "$2"
		;;
	esac
}

# Resolve a unit name to an existing unit file path, including /dev/null masks.
#   $1 = unit name (bare name, e.g. "custom.target")
#   $2 = extension to append when the name has none
resolve_unit() {
	local name="$1" ext="$2" candidate sp full

	if [[ "$name" == */* ]]; then
		if [[ -f "$name" || "$name" -ef /dev/null ]]; then
			printf '%s' "$name"
			return 0
		fi
		return 1
	fi

	full="$(normalize_unit_name "$name" "${name}${ext}")"

	for sp in "${UNIT_SEARCH_PATHS[@]}"; do
		candidate="${sp}/${full}"
		if [[ -f "$candidate" || "$candidate" -ef /dev/null ]]; then
			printf '%s' "$candidate"
			return 0
		fi
	done
	return 1
}
