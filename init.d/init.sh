#!/usr/bin/bash

set -euo pipefail

DIR="$(dirname "$(realpath "$0")")"

mapfile -t common < <(find "$DIR/common" -type f -name "*.sh" | sort)
for file in "${common[@]}"; do
	# shellcheck disable=SC1090
	. "$file"
done

mapfile -t modules < <(find "$DIR/modules" -type f -name "*.sh" | sort)
for file in "${modules[@]}"; do
	# shellcheck disable=SC1090
	. "$file"
done

for file in "${modules[@]}"; do
	name="$(init_module_name "$file")"
	debug "Loading module $file ($name)"
	for h in "${MODULE_PRE_HOOKS[@]}"; do
		debug "Calling module hook (pre): $h"
		eval "$h pre $name"
		debug "Finished module hook (pre): $h"
	done

	if ! eval "module_${name}_enabled"; then
		debug "Skipping module $name"
		continue
	fi

	debug "Running module_${name}_run"
	eval "module_${name}_run $*"

	for h in "${MODULE_POST_HOOKS[@]}"; do
		debug "Calling module hook (post): $h"
		eval "$h post $name"
		debug "Finished module hook (post): $h"
	done
done

