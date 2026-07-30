#!/usr/bin/env bash
set -euo pipefail

# ensure-codex.sh — compatibility wrapper for the generic headless guard.
#
# Usage: ensure-codex.sh <project> [name]

PROJECT="${1:?Usage: ensure-codex.sh <project> [name]}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/ensure-headless.sh" codex "$@"
