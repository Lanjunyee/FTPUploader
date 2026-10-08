#!/usr/bin/env bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEP_ROOT="$PROJECT_ROOT/.build/secure-deps"
mkdir -p "$DEP_ROOT/sources" "$DEP_ROOT/universal/lib" "$DEP_ROOT/universal/include" "$DEP_ROOT/licenses"
SSH_VERSION=1.11.1
SSL_VERSION=3.5.9
fetch() {
  local file="$1" url="$2" sha="$3"
  if [[ ! -f "$file" ]]; then curl --fail --location --max-time 120 "$url" -o "$file"; fi
  echo "$sha  $file" | shasum -a 256 -c -
}
# SHA256 pins below are from the official release archives; OpenSSL also publishes its SHA256 alongside the archive.
fetch "$DEP_ROOT/sources/libssh2-$SSH_VERSION.release.tar.gz" "https://github.com/libssh2/libssh2/releases/download/libssh2-$SSH_VERSION/libssh2-$SSH_VERSION.tar.gz" d9ec76cbe34db98eec3539fe2c899d26b0c837cb3eb466a56b0f109cabf658f7
fetch "$DEP_ROOT/sources/openssl-$SSL_VERSION.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-$SSL_VERSION/openssl-$SSL_VERSION.tar.gz" 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
for arch in arm64 x86_64; do
  prefix="$DEP_ROOT/$arch/install"
  if [[ ! -f "$prefix/lib/libssh2.a" ]]; then
    mkdir -p "$DEP_ROOT/$arch" "$prefix"
    tar -xzf "$DEP_ROOT/sources/openssl-$SSL_VERSION.tar.gz" -C "$DEP_ROOT/$arch"
    pushd "$DEP_ROOT/$arch/openssl-$SSL_VERSION" >/dev/null
    target=darwin64-arm64-cc
    [[ "$arch" == x86_64 ]] && target=darwin64-x86_64-cc
    ./Configure "$target" no-shared no-tests no-module no-engine no-legacy --prefix="$prefix" --libdir=lib -mmacosx-version-min=13.0
    make -j8 build_libs
    make install_dev
    popd >/dev/null
    tar -xzf "$DEP_ROOT/sources/libssh2-$SSH_VERSION.release.tar.gz" -C "$DEP_ROOT/$arch"
    cmake -S "$DEP_ROOT/$arch/libssh2-$SSH_VERSION" -B "$DEP_ROOT/$arch/ssh-build" \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="$arch" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 \
      -DCMAKE_INSTALL_PREFIX="$prefix" -DCRYPTO_BACKEND=OpenSSL -DOPENSSL_ROOT_DIR="$prefix" \
      -DOPENSSL_USE_STATIC_LIBS=ON -DBUILD_SHARED_LIBS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DENABLE_ZLIB_COMPRESSION=OFF
    cmake --build "$DEP_ROOT/$arch/ssh-build" -j8
    cmake --install "$DEP_ROOT/$arch/ssh-build"
  fi
done
for library in libssh2.a libcrypto.a; do
  lipo -create "$DEP_ROOT/arm64/install/lib/$library" "$DEP_ROOT/x86_64/install/lib/$library" -output "$DEP_ROOT/universal/lib/$library"
done
cp "$DEP_ROOT/arm64/install/include/libssh2"*.h "$DEP_ROOT/universal/include/"
cp "$DEP_ROOT/arm64/libssh2-$SSH_VERSION/COPYING" "$DEP_ROOT/licenses/libssh2-COPYING"
cp "$DEP_ROOT/arm64/openssl-$SSL_VERSION/LICENSE.txt" "$DEP_ROOT/licenses/OpenSSL-LICENSE.txt"
lipo -info "$DEP_ROOT/universal/lib/libssh2.a"
lipo -info "$DEP_ROOT/universal/lib/libcrypto.a"
