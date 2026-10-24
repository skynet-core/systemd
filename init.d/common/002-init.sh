#!/usr/bin/bash

init_module_name() {
	local name
	name="$(basename "$1")"
	name="${name%.*}"
	if [[ $name =~ ^[0-9]+-(.*)$ ]]; then
		name="${BASH_REMATCH[1]}"
	fi
	echo "${name//-/_}"
}
