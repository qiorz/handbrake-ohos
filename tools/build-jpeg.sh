#!/bin/bash
# Cross-build libjpeg-turbo 3.1.3 (static, turbojpeg API) for HarmonyOS / OHOS arm64.
# Needed by libhb/hb.c (preview JPEG encode/decode via the turbojpeg API).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

extract "libjpeg-turbo-3.1.3.tar.gz" "libjpeg-turbo"
mkdir -p "$BUILD/jpeg-cmake"
cd "$BUILD/jpeg-cmake"

# WITH_SIMD=1 uses NEON intrinsics on aarch64 and needs no nasm; if the CMake
# probe still insists on an assembler we fall back to WITH_SIMD=0.
try_simd() {
  local simd="$1"
  log "libjpeg-turbo: cmake configure (WITH_SIMD=$simd)"
  rm -rf CMakeCache.txt CMakeFiles
  "$OHOS_CMAKE" -G Ninja \
    -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_NATIVE_WIN/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=arm64-v8a \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" \
    -DENABLE_SHARED=OFF -DENABLE_STATIC=ON \
    -DWITH_TURBOJPEG=ON -DWITH_SIMD="$simd" -DWITH_12BIT=OFF \
    -DWITH_JAVA=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF \
    "$BUILD/libjpeg-turbo" > "$LOGS/jpeg-cmake.log" 2>&1
}

if ! try_simd 1; then
  echo "--- WITH_SIMD=1 configure failed, retrying WITH_SIMD=0 ---"
  tail -20 "$LOGS/jpeg-cmake.log"
  try_simd 0 || { echo "=== libjpeg-turbo configure FAILED ==="; tail -40 "$LOGS/jpeg-cmake.log"; exit 1; }
fi
log "libjpeg-turbo: configure OK"

"$OHOS_CMAKE" --build . --target install > "$LOGS/jpeg-build.log" 2>&1 || {
    echo "=== libjpeg-turbo build FAILED, tail: ==="; tail -60 "$LOGS/jpeg-build.log"; exit 1; }
log "libjpeg-turbo: installed"
ls -l "$PREFIX/lib/" | grep -iE "jpeg|turbo" || true
