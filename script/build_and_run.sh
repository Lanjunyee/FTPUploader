#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="FTPUploader"
APP_BUNDLE="$PROJECT_ROOT/dist/$APP_NAME.app"

case "$MODE" in
  run|--verify|--debug|--logs|--telemetry) ;;
  *) echo "usage: $0 [--verify|--debug|--logs|--telemetry]" >&2; exit 2 ;;
esac

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
xcodebuild -quiet -project "$PROJECT_ROOT/FTPUploader.xcodeproj" \
  -scheme "$APP_NAME" -configuration Debug \
  -derivedDataPath "$PROJECT_ROOT/.build/xcode" build
mkdir -p "$PROJECT_ROOT/dist"
ditto "$PROJECT_ROOT/.build/xcode/Build/Products/Debug/$APP_NAME.app" "$APP_BUNDLE"

if [[ "$MODE" == "--debug" ]]; then
  lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
else
  /usr/bin/open -n "$APP_BUNDLE"
  case "$MODE" in
    --verify) sleep 1; pgrep -x "$APP_NAME" >/dev/null; echo "应用已启动：$APP_BUNDLE" ;;
    --logs) /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
    --telemetry) /usr/bin/log stream --info --style compact --predicate 'subsystem == "local.ftpuploader"' ;;
  esac
fi
