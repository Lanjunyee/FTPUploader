#!/usr/bin/env bash
# Prepare a LOCAL, ad-hoc release candidate. No upload, notarization or publishing.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/dist/release-candidate}"
DERIVED="$ROOT/.build/release-candidate"
VERSION=0.3.0
ARCHIVE="FTPUploader-$VERSION-local-candidate-macOS-universal.zip"
[[ ! -e "$OUT" ]] || { echo "Refusing to overwrite existing output: $OUT" >&2; exit 1; }
[[ -f "$ROOT/.build/secure-deps/universal/lib/libssh2.a" ]] || {
  echo "Prepare fixed static dependencies with script/build_secure_dependencies.sh first." >&2; exit 1;
}
mkdir -p "$OUT"
xcodebuild -project "$ROOT/FTPUploader.xcodeproj" -scheme FTPUploader \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED" ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  build > "$OUT/build.log" 2>&1
APP="$OUT/FTPUploader.app"
ditto "$DERIVED/Build/Products/Release/FTPUploader.app" "$APP"
mkdir -p "$APP/Contents/Resources/licenses"
cp "$ROOT/docs/licenses/libssh2-COPYING" "$ROOT/docs/licenses/OpenSSL-LICENSE.txt" "$APP/Contents/Resources/licenses/"
# Adding resources changes the seal. Re-sign this local candidate only.
codesign --force --sign - --options runtime --timestamp=none \
  --entitlements "$ROOT/FTPUploader/FTPUploader.entitlements" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" > "$OUT/signature-verification.log" 2>&1
codesign -dv --verbose=4 "$APP" > "$OUT/signature-details.log" 2>&1
codesign -d --entitlements - --xml "$APP" > "$OUT/entitlements.plist" 2> "$OUT/entitlements.log"
xcrun vtool -show-build "$APP/Contents/MacOS/FTPUploader" > "$OUT/build-versions.log"
xcrun otool -L "$APP/Contents/MacOS/FTPUploader" > "$OUT/linkage.log"
python3 - "$APP" "$OUT" <<'PY'
import pathlib, plistlib, subprocess, sys
app, out = map(pathlib.Path, sys.argv[1:])
with (app/'Contents/Info.plist').open('rb') as f: info=plistlib.load(f)
assert info['CFBundleShortVersionString']=='0.3.0'
assert str(info['CFBundleVersion'])=='3'
assert info['LSMinimumSystemVersion']=='15.0'
arches=subprocess.check_output(['xcrun','lipo','-archs',str(app/'Contents/MacOS/FTPUploader')],text=True).split()
assert set(arches)=={'arm64','x86_64'}
with (out/'entitlements.plist').open('rb') as f: ent=plistlib.load(f)
for key in ['app-sandbox','network.client','files.user-selected.read-write','files.bookmarks.app-scope']:
    assert ent['com.apple.security.'+key] is True
assert not ent.get('com.apple.security.get-task-allow',False)
assert 'runtime' in (out/'signature-details.log').read_text()
assert 'Signature=adhoc' in (out/'signature-details.log').read_text()
assert (out/'build-versions.log').read_text().count('minos 15.0')==2
for line in (out/'linkage.log').read_text().splitlines():
    if ' (compatibility version' in line:
        assert line.strip().startswith(('/usr/lib/','/System/Library/')),line
for name in ['libssh2-COPYING','OpenSSL-LICENSE.txt']:
    assert (app/'Contents/Resources/licenses'/name).stat().st_size>0
print('0.3.0 (3), macOS 15.0, universal, sandbox, no debugging entitlement, hardened ad-hoc, licenses: PASS')
PY
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/$ARCHIVE"
(cd "$OUT" && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)
# Verify the archive round trip rather than trusting the source bundle alone.
mkdir "$OUT/unzip-check"
ditto -x -k "$OUT/$ARCHIVE" "$OUT/unzip-check"
codesign --verify --deep --strict --verbose=2 "$OUT/unzip-check/FTPUploader.app" > "$OUT/unzip-signature.log" 2>&1
cmp "$APP/Contents/MacOS/FTPUploader" "$OUT/unzip-check/FTPUploader.app/Contents/MacOS/FTPUploader"
echo "LOCAL CANDIDATE ONLY: $OUT/$ARCHIVE"
echo "Not Developer ID signed, not notarized, not verified on macOS 15/Intel hardware. Do not publish as fully validated."
