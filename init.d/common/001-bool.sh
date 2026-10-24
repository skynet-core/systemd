#!/usr/bin/bash

is_true() {
	case "$1" in
	[tT][rR][uU][eE] | [yY][eE][sS] | [oO][nN] | [yY] | 1)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

is_false() {
	case "$1" in
	[fF][aA][lL][sS][eE] | [oO][fF][fF] | [nN][oO] | [nN] | 0)
		return 0
		;;
	*)
		return 1
		;;
	esac
}
