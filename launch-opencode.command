#!/bin/bash

set -euo pipefail

PROFILE_DIR="$(cd "$(dirname "$0")" && pwd)"
exec /bin/bash "$PROFILE_DIR/launch-coder.command" "$@"
