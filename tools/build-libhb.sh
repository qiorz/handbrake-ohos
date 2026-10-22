#!/bin/bash
# Configure + build HandBrake's libhb for HarmonyOS / OHOS arm64 using CMake+Ninja
# and the OHOS NDK toolchain file from DevEco Studio.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

HB_SRC="$SRC/handbrake"
OUTDIR="$BUILD/libhb-ohos"

if [ ! -d "$HB_SRC/libhb" ]; then
  echo "HandBrake source not found at $HB_SRC"
  echo "Expected a HandBrake 1.11.2 tree; copy/checkout it to \$SRC/handbrake."
  exit 1
fi

mkdir -p "$OUTDIR"
cd "$OUTDIR"

log "libhb: cmake configure"
"$OHOS_CMAKE" -G Ninja \
  -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$OHOS_NATIVE_WIN/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DHB_SRC="$HB_SRC" \
  -DHB_DEPS="$PREFIX" \
  "$HBROOT/port-ohos" > "$LOGS/libhb-cmake.log" 2>&1 || {
    echo "=== libhb configure FAILED, tail: ==="; tail -40 "$LOGS/libhb-cmake.log"; exit 1; }
log "libhb: configure OK"

log "libhb: building (ninja)"
"$OHOS_CMAKE" --build . > "$LOGS/libhb-build.log" 2>&1 || {
    echo "=== libhb build FAILED, tail: ==="; tail -80 "$LOGS/libhb-build.log"; exit 1; }
log "libhb: build OK"
"$OHOS_CMAKE" --build . --target install >> "$LOGS/libhb-build.log" 2>&1 || true

ls -l "$PREFIX/lib/" | grep -i handbrake || true
