#!/bin/bash
# The plugin moved to plugin/. This keeps the old path working for Shortcuts
# and scripts that still call it.
exec bash "$(dirname "$0")/../plugin/scripts/setup.sh" "$@"
