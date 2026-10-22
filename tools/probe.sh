#!/bin/sh
echo "===== SHELL ====="
echo "whoami: $(whoami 2>&1)"
id 2>&1
echo "pwd: $(pwd 2>&1)"
echo "HOME=$HOME"
echo "PATH=$PATH"
echo "uname: $(uname -a 2>&1)"
echo "TEMPDIR=$TMPDIR"

echo "===== WRITABLE DIRS ====="
for d in /data/local/tmp /data/storage/el2/base /storage/Users/currentUser /mnt /tmp /sdcard; do
  if [ -e "$d" ]; then
    if [ -w "$d" ]; then echo "WRITABLE $d"; else echo "readonly $d"; fi
  else
    echo "MISSING  $d"
  fi
done

echo "===== TOOLS ====="
for c in sh bash ash python3 python busybox curl wget git cmake make gcc cc clang ld toybox tar unzip zip openssl xxd file ldd readelf nm objdump; do
  p=$(command -v "$c" 2>/dev/null)
  if [ -n "$p" ]; then echo "HAVE  $c -> $p"; else echo "MISS  $c"; fi
done

echo "===== /system/bin (first 120) ====="
ls /system/bin 2>&1 | head -120

echo "===== /usr/bin ====="
ls /usr/bin 2>&1 | head -60

echo "===== TOP LEVEL ====="
ls / 2>&1

echo "===== LIBC ====="
ls -l /system/lib64/libc.so /lib/ld-musl-aarch64.so.1 /lib64/ld-linux-aarch64.so.1 2>&1
echo "--- lib64 first 60 ---"
ls /system/lib64 2>&1 | head -60

echo "===== ENV / PLATFORM ====="
cat /etc/os-release 2>&1
echo "--- param ---"
for p in const.ohos.apiversion const.product.model const.product.cpu.abilist const.build.characteristics const.product.devicetype; do
  echo "$p=$(param get $p 2>&1)"
done

echo "===== CPU / MEM ====="
cat /proc/cpuinfo 2>&1 | head -30
echo "--- meminfo ---"
head -5 /proc/meminfo 2>&1
echo "--- nproc ---"
nproc 2>&1
