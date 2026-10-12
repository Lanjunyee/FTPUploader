#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEP_ROOT="${FTP_SECURE_DEP_ROOT:-$PROJECT_ROOT/.build/secure-deps}"
SSH_VERSION=1.11.1
SSL_VERSION=3.5.9
SSH_SHA=d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
SSL_SHA=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
case "${1:-}" in
  "") MODE=build ;;
  --check) MODE=check ;;
  --verify) MODE=verify ;;
  *) echo "usage: $0 [--check|--verify]" >&2; exit 2 ;;
esac
# --check is read-only: it never creates directories, fetches or compiles.
# Pins remain canonical here. The helper keys every declared input and verifies
# completed artifact content before reusing or atomically publishing a generation.
exec python3 "$PROJECT_ROOT/script/secure_dependency_cache.py" "$MODE" \
  --root "$DEP_ROOT" --ssh-version "$SSH_VERSION" --ssl-version "$SSL_VERSION" \
  --ssh-sha "$SSH_SHA" --ssl-sha "$SSL_SHA"
