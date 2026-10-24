#!/usr/bin/bash

: "${INIT_LOG_LEVEL:=2}"

debug() {
	if [ "$INIT_LOG_LEVEL" -ge 3 ]; then
		printf '[DEBUG]: (%s): %s\n' "$(basename "$0")" "$*" >&2
	fi
}

info() {
	if [ "$INIT_LOG_LEVEL" -ge 2 ]; then
		printf '[INFO]: (%s): %s\n' "$(basename "$0")" "$*" >&2
	fi
}

warn() {
	if [ "$INIT_LOG_LEVEL" -ge 1 ]; then
		printf '[WARN]: (%s): %s\n' "$(basename "$0")" "$*" >&2
	fi
}

error() {
	if [ "$INIT_LOG_LEVEL" -ge 0 ]; then
		printf '[ERROR]: (%s): %s\n' "$(basename "$0")" "$*" >&2
	fi
}

die() {
	printf '[FATAL]: (%s): %s\n' "$(basename "$0")" "$*" >&2
	exit 1
}
