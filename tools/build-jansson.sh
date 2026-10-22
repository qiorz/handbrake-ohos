#!/bin/bash
# Cross-build jansson 2.15.0 (static) for HarmonyOS / OHOS arm64.
# libhb uses jansson for its preset / JSON API (libhb/hb_json.c).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

export CC="$HERE/ohos-cc"
export CXX="$HERE/ohos-cxx"

extract "jansson-2.15.0.tar.bz2" "jansson"
cd "$BUILD/jansson"

log "jansson: configure"
./configure \
  --prefix="$PREFIX" \
  --host=aarch64-linux-gnu \
  --enable-static --disable-shared \
  --disable-docs \
  CFLAGS="-O2 -fPIC" \
  > "$LOGS/jansson-configure.log" 2>&1 || {
    echo "=== jansson configure FAILED, tail: ==="; tail -40 "$LOGS/jansson-configure.log"; exit 1; }
log "jansson: configure OK"

make -j"$JOBS" > "$LOGS/jansson-build.log" 2>&1 || {
    echo "=== jansson build FAILED, tail: ==="; tail -60 "$LOGS/jansson-build.log"; exit 1; }
log "jansson: make OK"
make install >> "$LOGS/jansson-build.log" 2>&1
log "jansson: installed to $PREFIX"
ls -l "$PREFIX/lib/" | grep -i jansson || true
