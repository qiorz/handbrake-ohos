#!/bin/bash
# Smoke test: drive the OHOS (Windows) NDK clang from MSYS2 with POSIX paths.
set -u
NDK="/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/native"
CC="$NDK/llvm/bin/clang.exe"
SYSROOT="$NDK/sysroot"
OUT="/d/dsh/homo移植/out"

echo "== 1. direct clang.exe with POSIX paths (MSYS2 auto-conversion) =="
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__ \
      -O2 -c "/d/dsh/homo移植/tools/hello.c" -o "$OUT/hello-msys.o" && echo "compile OK"

echo "== 2. link it =="
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__ -static \
      "$OUT/hello-msys.o" -o "$OUT/hello-msys" && echo "link OK"

echo "== 3. what does the NDK clang think the target is? =="
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -dumpmachine
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -print-sysroot

echo "== 4. tool inventory from MSYS2 =="
for t in make python3 nasm pkg-config autoconf automake libtool m4 gawk; do
  p=$(command -v $t 2>/dev/null); echo "  $t -> ${p:-MISSING}"
done

echo "== 5. can clang find a sysroot header? =="
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -E -x c - <<'EOF' >/dev/null && echo "headers OK"
#include <stdio.h>
#include <pthread.h>
#include <sys/mman.h>
#include <zlib.h>
EOF

echo "== 6. is zlib.h present in sysroot? =="
find "$SYSROOT" -name "zlib.h" 2>/dev/null | head -3
find "$SYSROOT" -name "libz.so" 2>/dev/null | head -3
echo "== 7. pthreads / musl feature probe =="
cat > /tmp/probe.c <<'EOF'
#include <stdio.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/sysinfo.h>
int main(void){ printf("nproc=%ld\n", sysconf(_SC_NPROCESSORS_ONLN)); return 0; }
EOF
"$CC" --target=aarch64-linux-ohos --sysroot="$SYSROOT" -D__MUSL__ -static /tmp/probe.c -o "$OUT/probe" && echo "pthread/sysinfo compile OK"
