#!/bin/zsh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$ROOT_DIR/LimitIsland.app"

if [[ ! -x "$APP_PATH/Contents/MacOS/LimitIsland" ]]; then
	"$ROOT_DIR/Scripts/build-app.sh"
fi

open "$APP_PATH"
