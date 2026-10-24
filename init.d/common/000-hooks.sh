#!/usr/bin/bash

MODULE_PRE_HOOKS=()
MODULE_POST_HOOKS=()

add_module_pre_hook() {
	MODULE_PRE_HOOKS+=("$1")
}

add_module_post_hook() {
	MODULE_POST_HOOKS+=("$1")
}
