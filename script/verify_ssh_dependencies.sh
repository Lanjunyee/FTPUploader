#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
for arch in arm64 x86_64; do
  bundle=".build/secure-deps/ssh-probe-$arch.app"
  mkdir -p "$bundle/Contents/MacOS"
  clang -arch "$arch" -mmacosx-version-min=13.0 -I FTPUploader/Support -I .build/secure-deps/universal/include \
    script/ssh_probe.c FTPUploader/Support/SSHBridge.c .build/secure-deps/universal/lib/libssh2.a \
    .build/secure-deps/universal/lib/libcrypto.a -o "$bundle/Contents/MacOS/ssh-probe"
  /usr/bin/python3 - "$bundle" "$arch" <<'PY'
import plistlib,sys
from pathlib import Path
(Path(sys.argv[1])/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.schoolftpuploader.ssh-probe-'+sys.argv[2], 'CFBundleName':'SSH Dependency Gate','CFBundleExecutable':'ssh-probe','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'13.0'}))
PY
  codesign --force --sign - --entitlements FTPUploader/FTPUploader.entitlements "$bundle"
done
.build/ssh-fixture-env/bin/python script/ssh_gate_fixture.py
