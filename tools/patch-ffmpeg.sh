#!/bin/bash
# Apply HandBrake's own FFmpeg patch set (contrib/ffmpeg/A*.patch) on top of the
# extracted ffmpeg-8.0.2 tree, then rebuild incrementally.
#
# HandBrake's libhb depends on patched FFmpeg APIs -- most importantly
# A14 "Expose the unmodified Dolby Vision RPU T35 buffers", which introduces
# AV_FRAME_DATA_DOVI_RPU_BUFFER_T35 that libhb/decavcodec.c uses unconditionally.
# Upstream's contrib system applies exactly these patches; we reproduce that.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

HB_PATCHES="$SRC/handbrake/contrib/ffmpeg"
cd "$BUILD/ffmpeg"

log "ffmpeg: applying HandBrake patch set from $HB_PATCHES"
ok=0; skip=0
for p in "$HB_PATCHES"/A*.patch; do
  name="$(basename "$p")"
  if patch -p1 --forward --batch --no-backup-if-mismatch -i "$p" > "$LOGS/ffmpeg-patch-$name.log" 2>&1; then
    echo "  applied   $name"; ok=$((ok+1))
  else
    echo "  SKIPPED   $name (already applied or does not apply)"
    skip=$((skip+1))
  fi
done
log "ffmpeg: patches applied=$ok skipped=$skip"

log "ffmpeg: rebuilding after patches (incremental)"
make -j"$JOBS" > "$LOGS/ffmpeg-rebuild.log" 2>&1 || {
    echo "=== ffmpeg rebuild FAILED, tail: ==="; tail -60 "$LOGS/ffmpeg-rebuild.log"; exit 1; }
log "ffmpeg: rebuild OK"
make install >> "$LOGS/ffmpeg-rebuild.log" 2>&1
log "ffmpeg: reinstalled to $PREFIX"
