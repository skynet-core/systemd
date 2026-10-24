#!/usr/bin/bash

module_exec_enabled() {
	return 0
}

module_exec_run() {
	exec "$@"
}
