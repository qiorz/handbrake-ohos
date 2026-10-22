#!/bin/bash
# Cross-build x265 (multi-bitdepth: 8 + 10 + 12) for HarmonyOS / OHOS arm64.
#
# HandBrake's encx265.c drives x265 through its *multilib* API: x265_api_get(bitDepth)
# must be able to hand back an 8-, 10- or 12-bit encoder.  That is achieved the
# same way upstream's contrib does it (contrib/x265/module.defs + x265_{8,10,12}bit):
#
#   1. build 10-bit and 12-bit with EXPORT_C_API=OFF -> they get their own C++
#      namespaces (x265_10bit / x265_12bit), so their symbols do not collide;
#   2. build 8-bit with EXPORT_C_API=ON and EXTRA_LIB + LINKED_10BIT/LINKED_12BIT,
#      which compiles the forwarding logic into x265_api_get().  NOTE: x265's
#      CMake only *declares* the LINKED_* options when EXTRA_LIB is non-empty
#      (source/CMakeLists.txt: `if(EXTRA_LIB) option(LINKED_10BIT ...)`), so
#      EXTRA_LIB must reference the two already-built archives;
#   3. merge the three archives object-by-object into one libx265.a
#      (upstream does this in X265.LINK in contrib/x265/module.defs).
#
# The 10/12-bit variants both name their archive libx265.a, hence the renames.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

AR="$OHOS_LLVM_BIN/llvm-ar.exe"
RANLIB="$OHOS_LLVM_BIN/llvm-ranlib.exe"
X265_TARBALL="x265-snapshot-20260216-13309.tar.gz"

extract "$X265_TARBALL" "x265"
SRCDIR="$BUILD/x265/source"
[ -f "$SRCDIR/CMakeLists.txt" ] || { echo "x265 源码目录不对: $SRCDIR"; exit 1; }

# ---------------------------------------------------------------------------
# 应用 HandBrake 的 x265 补丁集（contrib/x265/A01..A09）。
#
# 与 FFmpeg 的情形完全一样：HandBrake 会给自己依赖的库打补丁，而 libhb 直接
# 依赖这些补丁新增的 API。这次是 encx265.c 用到的
#   x265_param.ambientIlluminance / ambientLightX / ambientLightY /
#   bEmitAmbientViewingEnvironment
# 来自 A03-Implement-ambient-viewing-environment-sei.patch。
# 不打卡在编译 encx265.c 时就会报 "no member named 'ambientIlluminance'"。
# ---------------------------------------------------------------------------
if [ ! -f "$BUILD/x265/.patched" ]; then
  log "x265: 应用 HandBrake 补丁集"
  cd "$BUILD/x265"
  ok=0; skip=0
  for p in "$SRC/handbrake/contrib/x265"/A*.patch; do
    name="$(basename "$p")"
    if patch -p1 --forward --batch --no-backup-if-mismatch -i "$p" \
         > "$LOGS/x265-patch-$name.log" 2>&1; then
      echo "  applied   $name"; ok=$((ok+1))
    else
      echo "  SKIPPED   $name (已打过或不适用)"; skip=$((skip+1))
    fi
  done
  touch "$BUILD/x265/.patched"
  log "x265: 补丁 applied=$ok skipped=$skip"
fi

COMMON=(
  -G Ninja
  -DCMAKE_MAKE_PROGRAM="$OHOS_NINJA"
  # 用自写的 toolchain 而不是 NDK 自带那份，原因见 port-ohos/toolchain/ohos-aarch64.cmake：
  #  (a) CMAKE_SYSTEM_NAME 用 Linux（x265 见到 "OHOS" 会当成未知平台，强制关掉
  #      AARCH64_RUNTIME_CPU_DETECT 并走错平台分支）；
  #  (b) 编译器指向 .cmd 包装器，把 --target 烘进命令行——因为 CMake 的
  #      CMAKE_CXX_COMPILER_TARGET 不注入 add_custom_command，而 x265 正是用
  #      自定义命令汇编 aarch64 的 .S。
  -DCMAKE_TOOLCHAIN_FILE="$HBROOT/port-ohos/toolchain/ohos-aarch64.cmake"
  -DCMAKE_BUILD_TYPE=Release
  -DENABLE_SHARED=OFF
  -DENABLE_CLI=OFF
  -DENABLE_LIBNUMA=OFF          # 目标没有 libnuma（且 OHOS 无 sysctl）
  -DCMAKE_POSITION_INDEPENDENT_CODE=ON   # 静态库要进 .so，必须 PIC
  # 汇编保持默认 ON。第一次尝试时 CMake 的 --target 不作用于 add_custom_command，
  # 导致 aarch64 的 .S 汇编失败（unknown target CPU 'armv8-a'），当时只能
  # -DENABLE_ASSEMBLY=OFF；现在换用 .cmd 包装器 toolchain 后可以正常汇编，于是
  # x265 的 aarch64 intrinsics 与运行时 CPU 检测都回来了（common/CMakeLists.txt 把
  # 整套 aarch64 源码门控在 if(ENABLE_ASSEMBLY AND (ARM64 OR CROSS_COMPILE_ARM64)) 下）。
)

build_variant() {
  local dir="$1"; shift
  log "x265: configure $dir"
  mkdir -p "$BUILD/x265/$dir"
  cd "$BUILD/x265/$dir"
  "$OHOS_CMAKE" "${COMMON[@]}" "$@" "$SRCDIR" > "$LOGS/x265-$dir-cmake.log" 2>&1 || {
      echo "=== x265 $dir configure FAILED ==="; tail -30 "$LOGS/x265-$dir-cmake.log"; exit 1; }
  log "x265: build $dir"
  "$OHOS_CMAKE" --build . --parallel "$JOBS" > "$LOGS/x265-$dir-build.log" 2>&1 || {
      echo "=== x265 $dir build FAILED ==="; tail -40 "$LOGS/x265-$dir-build.log"; exit 1; }
  log "x265: $dir OK ($(ls -l libx265.a | awk '{print $5}') bytes)"
}

# 1) 先做 10bit / 12bit（它们互相独立）
build_variant 12bit -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON
cp "$BUILD/x265/12bit/libx265.a" "$BUILD/x265/libx265_main12.a"

build_variant 10bit -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF
cp "$BUILD/x265/10bit/libx265.a" "$BUILD/x265/libx265_main10.a"

# 2) 再做 8bit，把前两个作为 EXTRA_LIB 传进去，启用 multilib 转发
build_variant 8bit -DHIGH_BIT_DEPTH=OFF -DEXPORT_C_API=ON \
  -DEXTRA_LIB="$BUILD/x265/libx265_main10.a;$BUILD/x265/libx265_main12.a" \
  -DEXTRA_LINK_FLAGS="-L$BUILD/x265" \
  -DLINKED_10BIT=ON -DLINKED_12BIT=ON
cp "$BUILD/x265/8bit/libx265.a" "$BUILD/x265/libx265_main.a"

# 3) 合并：三个归档里对象文件名会重复（api.cpp.o 等），所以各解到独立目录
log "x265: merging 8/10/12-bit archives"
rm -rf "$BUILD/x265/merge"
mkdir -p "$BUILD/x265/merge"
cd "$BUILD/x265/merge"
i=0
for a in "$BUILD/x265/libx265_main.a" "$BUILD/x265/libx265_main10.a" "$BUILD/x265/libx265_main12.a"; do
  i=$((i+1))
  mkdir -p "part$i"
  ( cd "part$i" && "$AR" x "$a" )
done
mkdir -p "$PREFIX/lib" "$PREFIX/include"
rm -f "$PREFIX/lib/libx265.a"
"$AR" crs "$PREFIX/lib/libx265.a" part*/*.o
"$RANLIB" "$PREFIX/lib/libx265.a"
log "x265: merged -> $PREFIX/lib/libx265.a ($(ls -l "$PREFIX/lib/libx265.a" | awk '{print $5}') bytes)"

# 4) 头文件取 8bit 构建（EXPORT_C_API=ON 的那份）
cp "$SRCDIR/x265.h" "$PREFIX/include/"
cp "$BUILD/x265/8bit/x265_config.h" "$PREFIX/include/"
log "x265: headers installed"
