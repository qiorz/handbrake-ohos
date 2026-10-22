#!/bin/bash
# Linux (x86_64 host) build: libhb + HAP, reusing prebuilt/ dependency archives.
# Prereq: HarmonyOS command line tools in PATH (hvigorw, ohpm) + DEVECO_SDK_HOME.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"            # package root (contains port-ohos/, project/, prebuilt/)
WORK="${HBWORK:-$ROOT/../hb-build}"       # out-of-tree build dir
NDK="${DEVECO_SDK_HOME:-/opt/harmony26/command-line-tools/sdk}/default/openharmony/native"
CMAKE="$NDK/build-tools/cmake/bin/cmake"
NINJA="$NDK/build-tools/cmake/bin/ninja"

mkdir -p "$WORK"/{src,out,build,logs}
ln -sfn "$ROOT/sources/handbrake-1.11.2" "$WORK/src/handbrake"
[ -d "$WORK/out/ohos-arm64/lib" ] || cp -r "$ROOT/prebuilt/lib" "$WORK/out/ohos-arm64/"
[ -d "$WORK/out/ohos-arm64/include" ] || cp -r "$ROOT/prebuilt/include" "$WORK/out/ohos-arm64/"

echo "== [1/2] libhb =="
mkdir -p "$WORK/build/libhb-ohos" && cd "$WORK/build/libhb-ohos"
[ -f build.ninja ] || "$CMAKE" -G Ninja -DCMAKE_MAKE_PROGRAM="$NINJA" \
  -DCMAKE_TOOLCHAIN_FILE="$NDK/build/cmake/ohos.toolchain.cmake" \
  -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release \
  -DHB_SRC="$WORK/src/handbrake" -DHB_DEPS="$WORK/out/ohos-arm64" \
  "$ROOT/port-ohos"
"$NINJA" -j"$(nproc)"

echo "== [2/2] HAP =="
cd "$ROOT/project"
# Point the NAPI module at this workspace.
python3 - "$WORK" <<'PY'
import json, re, sys, io
w = sys.argv[1]
p = 'entry/build-profile.json5'
s = open(p).read()
s = re.sub(r'"arguments": "[^"]*"',
           '"arguments": "-DHB_PREFIX=%s/out/ohos-arm64 -DHB_SRC=%s/src/handbrake"' % (w, w), s)
open(p, 'w').write(s)
PY
hvigorw assembleHap --no-daemon
ls -lh entry/build/default/outputs/default/*.hap
