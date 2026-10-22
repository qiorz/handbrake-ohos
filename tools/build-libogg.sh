#!/bin/bash
# Cross-build libogg 1.3.6 (static) for HarmonyOS / OHOS arm64.
# Needed by libhb/extradata.c (ogg_packet layout for Opus/Vorbis extradata).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

extract "libogg-1.3.6.tar.gz" "libogg"
mkdir -p "$BUILD/libogg-cmake"
cd "$BUILD/libogg-cmake"

log "libogg: cmake configure"
"$OHOS_CMAKE" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$OHOS_NATIVE_WIN/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=OFF \
  -DINSTALL_DOCS=OFF -DBUILD_TESTING=OFF \
  "$BUILD/libogg" > "$LOGS/libogg-cmake.log" 2>&1 || {
    echo "=== libogg configure FAILED, tail: ==="; tail -40 "$LOGS/libogg-cmake.log"; exit 1; }

"$OHOS_CMAKE" --build . --target install > "$LOGS/libogg-build.log" 2>&1 || {
    echo "=== libogg build FAILED, tail: ==="; tail -60 "$LOGS/libogg-build.log"; exit 1; }
log "libogg: installed"
ls -l "$PREFIX/lib/" | grep -i ogg || true
