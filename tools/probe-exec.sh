#!/bin/sh
echo "===== MOUNTS ====="
mount 2>&1 | grep -E "data|tmp|system|vendor" | head -40

echo "===== SELINUX ====="
getenforce 2>&1
echo "context: $(cat /proc/self/attr/current 2>&1)"

echo "===== try exec variants ====="
P=/data/local/tmp
echo "--- ls -lZ ---"
ls -lZ $P/hello-signed 2>&1

echo "--- copy to other locations and try ---"
for d in /data/local/tmp /data/service/el2/public /data/local /mnt/data; do
  if [ -d "$d" ] && [ -w "$d" ]; then
    cp $P/hello-signed "$d/probe-exec" 2>/dev/null && chmod 755 "$d/probe-exec" 2>/dev/null
    if [ -x "$d/probe-exec" ]; then
      out=$("$d/probe-exec" 2>&1 | head -2)
      echo "[$d] exec returned: rc=$? out=$out"
    else
      echo "[$d] not executable/copy failed"
    fi
  else
    echo "[$d] not writable or missing"
  fi
done

echo "===== direct strace-less diagnosis ====="
sh -c '/data/local/tmp/hello-signed' 2>&1
echo "rc=$?"

echo "===== is there an app sandbox we can reach? ====="
ls /data/app/el2/100/base 2>&1 | head -20
ls /data/service/el2 2>&1 | head

echo "===== devicedebug / aa tools ====="
command -v aa bm devicedebug hdc 2>&1

echo "===== /proc/sys/kernel/randomize / mmap_min_addr ====="
cat /proc/sys/vm/mmap_min_addr 2>&1
