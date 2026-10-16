#!/bin/zsh
# Requires the project's release-signing key in the login Keychain. Runs only
# throwaway application bundles with unique identifiers and a localhost feed.
set -eu
SCRIPT_DIR="${0:A:h}"
exec python3 "$SCRIPT_DIR/test-automatic-installer.py" "$@"
