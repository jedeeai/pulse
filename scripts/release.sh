#!/usr/bin/env bash
# 构建并打包一个可发布的 Pulse.app zip
# 用法: bash scripts/release.sh 1.0.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "用法: bash scripts/release.sh <version>  例如: bash scripts/release.sh 1.0.0" >&2
  exit 1
fi

echo "[release] 构建 Pulse v$VERSION ..."
PULSE_VERSION="$VERSION" bash "$ROOT/scripts/build-app.sh"

APP_DIR="$ROOT/dist/Pulse.app"
ZIP_PATH="$ROOT/dist/Pulse-$VERSION.zip"

rm -f "$ZIP_PATH"
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"

echo "[release] 打包完成: $ZIP_PATH"
shasum -a 256 "$ZIP_PATH"
