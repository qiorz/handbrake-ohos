#!/bin/bash
# Cross-build x264 (static, PIC) for HarmonyOS / OHOS arm64.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

export CC="$HERE/ohos-cc"
export CXX="$HERE/ohos-cxx"

extract "x264-snapshot-20250729-3222.tar.gz" "x264"
cd "$BUILD/x264"

log "x264: configure"
# TODO(性能)：这里用 --disable-asm 关闭了 x264 的 aarch64 汇编（可用但没吃到 NEON 优化）。
# 想打开时：删掉下面的 --disable-asm 重新构建即可。x264 的 .S 走的是普通 make 编译规则，
# 会经过 CC 包装器拿到 --target，不存在 x265 那种 add_custom_command 不注入 --target 的问题。
# 打开后务必核对：libx264.a 应该变大，且 llvm-nm 里能看到 x264_*_neon 之类符号。
./configure \
  --prefix="$PREFIX" \
  --host=aarch64-linux-gnu \
  --enable-static --enable-pic \
  --disable-cli --disable-lavf --disable-ffms --disable-avs \
  --disable-swscale --disable-gpac --disable-lsmash \
  --disable-asm \
  --extra-cflags="-O2 -fPIC" \
  --extra-ldflags="-static" \
  > "$LOGS/x264-configure.log" 2>&1 || {
    echo "=== x264 configure FAILED, tail: ==="; tail -40 "$LOGS/x264-configure.log"; exit 1; }
log "x264: configure OK"

log "x264: make -j$JOBS"
make -j"$JOBS" > "$LOGS/x264-build.log" 2>&1 || {
    echo "=== x264 build FAILED, tail: ==="; tail -60 "$LOGS/x264-build.log"; exit 1; }
log "x264: make OK"
make install >> "$LOGS/x264-build.log" 2>&1
log "x264: installed to $PREFIX"

ls -l "$PREFIX/lib/" | grep -i x264 || true
