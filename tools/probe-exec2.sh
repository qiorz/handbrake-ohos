#!/bin/sh
# Hunt for a directory from which a self-signed native binary can actually be
# executed on this HarmonyOS device.  /data/local/tmp is known-bad (its SELinux
# label `data_local_tmp` is unreadable by code_protect's BSS).
BIN=/data/local/tmp/hello-signed

echo "===== candidate writable dirs ====="
CANDS="/data/local/tmp /data/local /data/service/el1/public /data/service/el2/public \
/data/storage/el2/base/cache /storage/Users/currentUser /storage/media/100/local/files \
/mnt/data /data/test /data/vendor /vendor/etc /system/etc /data/app/el2/100/base"

for d in $CANDS; do
  if [ -d "$d" ]; then
    w="ro"; [ -w "$d" ] && w="RW"
    lbl=$(ls -ldZ "$d" 2>/dev/null | awk '{print $5}')
    echo "[$w] $d  label=$lbl"
  else
    echo "[--] $d  (missing)"
  fi
done

echo ""
echo "===== try executing from every RW candidate ====="
for d in $CANDS; do
  [ -d "$d" ] || continue
  [ -w "$d" ] || continue
  if cp "$BIN" "$d/hb-probe" 2>/dev/null && chmod 755 "$d/hb-probe" 2>/dev/null; then
    out=$("$d/hb-probe" 2>&1 | head -1)
    rc=$?
    echo "  EXEC-OK?  $d  rc=$rc  out=$out"
    rm -f "$d/hb-probe" 2>/dev/null
  else
    echo "  no-write  $d"
  fi
done

echo ""
echo "===== devicedebug / aa capabilities ====="
devicedebug --help 2>&1 | head -20
echo "--- aa help (first lines) ---"
aa help 2>&1 | head -12

echo ""
echo "===== current shell domain and exec policy hints ====="
echo "context: $(cat /proc/self/attr/current 2>&1)"
echo "--- dmesg avc denials (if readable) ---"
dmesg 2>/dev/null | grep -i -E "avc|denied" | tail -15

echo ""
echo "===== is there a user-facing writable home on this device? ====="
ls -ldZ /storage 2>&1
ls /storage 2>&1
