#!/bin/bash
# Common environment for cross-building HandBrake dependencies for HarmonyOS (OHOS) arm64.
# Runs under MSYS2 bash on Windows, driving the DevEco OHOS native NDK (Windows clang).

set -u

# --- DevEco / OHOS NDK ------------------------------------------------------
# IMPORTANT: the real DevEco SDK lives under "C:\Program Files\Huawei\DevEco Studio\...",
# i.e. with spaces.  Autotools/CMake recipes regularly mis-quote paths containing
# spaces, so we address the NDK through a space-free junction:
#     D:\ohosndk  ==>  C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native
# (create it once with: New-Item -ItemType Junction -Path D:\ohosndk -Target "<native>").
export DEVECO_HOME="/c/Program Files/Huawei/DevEco Studio"
export OHOS_SDK="$DEVECO_HOME/sdk/default/openharmony"
export OHOS_NATIVE_WIN="D:/ohosndk"
export OHOS_NATIVE="$OHOS_NATIVE_WIN"
export OHOS_SYSROOT_WIN="$OHOS_NATIVE_WIN/sysroot"
export OHOS_SYSROOT="$OHOS_SYSROOT_WIN"
export OHOS_LLVM_BIN="$OHOS_NATIVE/llvm/bin"
export OHOS_CMAKE="$OHOS_NATIVE/build-tools/cmake/bin/cmake.exe"
export OHOS_NINJA="$OHOS_NATIVE/build-tools/cmake/bin/ninja.exe"

export OHOS_TARGET_TRIPLE="aarch64-linux-ohos"

# The NDK ships `aarch64-unknown-linux-ohos-clang` as a *shell* wrapper, which is
# useless on a Windows host.  We therefore call clang.exe directly and reproduce
# exactly what that wrapper does.
export OHOS_CFLAGS_BASE="--target=$OHOS_TARGET_TRIPLE --sysroot=$OHOS_SYSROOT_WIN -D__MUSL__"

export CC="$OHOS_LLVM_BIN/clang.exe"
export CXX="$OHOS_LLVM_BIN/clang++.exe"
export AR="$OHOS_LLVM_BIN/llvm-ar.exe"
export RANLIB="$OHOS_LLVM_BIN/llvm-ranlib.exe"
export STRIP="$OHOS_LLVM_BIN/llvm-strip.exe"
export NM="$OHOS_LLVM_BIN/llvm-nm.exe"
# Cross-build hygiene: without LD pinned, autoconf/libtool happily pick up the
# MSYS2 *host* linker (C:/msys64/usr/bin/ld.exe) while targeting aarch64-OHOS.
export LD="$OHOS_LLVM_BIN/ld.lld.exe"

# --- Workspace -------------------------------------------------------------
# NOTE: the build workspace deliberately lives at an ASCII path.
#   * hvigor/DevEco rejects project paths containing non-ASCII characters
#     (error 00306003 "Invalid project path").
#   * CMake+Ninja mis-encodes non-ASCII paths in the *link* response file
#     (the UTF-8 bytes get re-encoded to the ANSI code page), producing
#     "clang: error: no such file or directory: .../homo<D2><C6>ֲ/...".
#
# HBROOT is the directory that holds src/ build/ out/ port-ohos/.  It defaults to
# the parent of this tools/ directory, so an unzipped hand-off copy works with no
# edits -- as long as you unzip it to an ASCII path.  Override by exporting HBROOT
# before sourcing, e.g. HBROOT=/d/hbohos when the checkout itself sits under a
# non-ASCII directory.
if [ -z "${HBROOT:-}" ]; then
    HBROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
fi
export HBROOT
export SRC="$HBROOT/src"
export BUILD="$HBROOT/build"
export OUT="$HBROOT/out"
export PREFIX="$OUT/ohos-arm64"          # everything we cross-build lands here
export LOGS="$HBROOT/build/logs"
mkdir -p "$SRC" "$BUILD" "$PREFIX" "$LOGS"

export JOBS="${JOBS:-8}"

# --- helpers ---------------------------------------------------------------
log() { echo "[$(date +%H:%M:%S)] $*"; }

# Extract a tarball into $BUILD unless already present.
extract() {
  local tarball="$1" dir="$2"
  if [ -d "$BUILD/$dir" ]; then log "already extracted: $dir"; return 0; fi
  log "extracting $tarball -> $dir"
  mkdir -p "$BUILD/$dir"
  case "$tarball" in
    *.tar.bz2) tar -xjf "$SRC/$tarball" -C "$BUILD/$dir" --strip-components=1 ;;
    *.tar.gz|*.tgz) tar -xzf "$SRC/$tarball" -C "$BUILD/$dir" --strip-components=1 ;;
    *) echo "unknown archive type: $tarball" >&2; return 1 ;;
  esac
}

# A CMake toolchain file for OHOS arm64, for the deps that build with CMake.
write_ohos_toolchain() {
  cat > "$OUT/ohos-arm64-toolchain.cmake" <<EOF
set(CMAKE_SYSTEM_NAME OHOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(OHOS 1)
set(CMAKE_C_COMPILER   "$OHOS_LLVM_BIN/clang.exe")
set(CMAKE_CXX_COMPILER "$OHOS_LLVM_BIN/clang++.exe")
set(CMAKE_AR           "$OHOS_LLVM_BIN/llvm-ar.exe")
set(CMAKE_RANLIB       "$OHOS_LLVM_BIN/llvm-ranlib.exe")
set(CMAKE_STRIP        "$OHOS_LLVM_BIN/llvm-strip.exe")
set(CMAKE_C_COMPILER_TARGET   aarch64-linux-ohos)
set(CMAKE_CXX_COMPILER_TARGET aarch64-linux-ohos)
set(CMAKE_SYSROOT "$OHOS_SYSROOT_WIN")
set(CMAKE_C_FLAGS_INIT   "--sysroot=$OHOS_SYSROOT_WIN -D__MUSL__")
set(CMAKE_CXX_FLAGS_INIT "--sysroot=$OHOS_SYSROOT_WIN -D__MUSL__")
set(CMAKE_FIND_ROOT_PATH "$OHOS_SYSROOT_WIN")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
set(CMAKE_INSTALL_PREFIX "$PREFIX")
EOF
  log "wrote $OUT/ohos-arm64-toolchain.cmake"
}
