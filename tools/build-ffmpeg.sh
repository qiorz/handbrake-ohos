#!/bin/bash
# Cross-build FFmpeg 8.0.2 (static) for HarmonyOS / OHOS arm64.
#
# The enabled-component list mirrors upstream HandBrake's contrib/ffmpeg/module.defs
# so that libhb finds every av_* API and codec it expects, minus the components that
# need third-party libraries we deliberately do not port (x265, libvpx, dav1d, lame,
# opus, speex, zimg, libdvd*, libbluray, ...).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/env.sh"

export CC="$HERE/ohos-cc"
export CXX="$HERE/ohos-cxx"

extract "ffmpeg-8.0.2.tar.bz2" "ffmpeg"
cd "$BUILD/ffmpeg"

log "ffmpeg: configure"
./configure \
  --prefix="$PREFIX" \
  --target-os=linux \
  --arch=aarch64 \
  --cpu=armv8-a \
  --enable-cross-compile \
  --host-cc=gcc \
  --cc="$HERE/ohos-cc" \
  --cxx="$HERE/ohos-cxx" \
  --ar="$OHOS_LLVM_BIN/llvm-ar.exe" \
  --ranlib="$OHOS_LLVM_BIN/llvm-ranlib.exe" \
  --strip="$OHOS_LLVM_BIN/llvm-strip.exe" \
  --nm="$OHOS_LLVM_BIN/llvm-nm.exe" \
  --enable-static --disable-shared \
  --enable-gpl \
  --disable-autodetect \
  --enable-pthreads \
  --disable-stripping \
  --disable-doc \
  --disable-programs \
  --disable-avdevice \
  --disable-network \
  --disable-vaapi --disable-vdpau --disable-vulkan --disable-cuda --disable-cuvid \
  --disable-hwaccels \
  --disable-muxers \
  --disable-encoders \
  --disable-filters \
  --disable-bzlib --disable-lzma --disable-iconv \
  --disable-sdl2 --disable-xlib --disable-libxcb --disable-libdrm \
  --disable-libx264 --disable-libx265 --disable-libvpx --disable-libdav1d \
  --disable-libaom --disable-libsvtav1 --disable-libvvenc --disable-librav1e \
  --disable-libmp3lame --disable-libopus --disable-libspeex --disable-libvorbis \
  --disable-libtheora --disable-libfdk-aac --disable-libzimg --disable-libass \
  --disable-libfreetype --disable-libharfbuzz --disable-libfribidi --disable-libfontconfig \
  --disable-libdvdread --disable-libdvdnav --disable-libbluray --disable-libopenmpt \
  --disable-libjxl --disable-lcms2 --disable-libwebp --disable-libplacebo \
  --disable-openssl --disable-gnutls --disable-libtls --disable-libsmbclient \
  --disable-libxml2 --disable-libssh --disable-libzmq --disable-librsvg \
  --enable-zlib \
  --enable-encoder=aac --enable-encoder=ac3 --enable-encoder=eac3 --enable-encoder=alac \
  --enable-encoder=flac --enable-encoder=mpeg2video --enable-encoder=mpeg4 \
  --enable-encoder=dnxhd --enable-encoder=prores --enable-encoder=ffv1 \
  --enable-encoder=movtext --enable-encoder=subrip --enable-encoder=truehd \
  --enable-encoder=pcm_s16le --enable-encoder=pcm_s24le \
  --enable-decoder=av1 \
  --enable-filter=format --enable-filter=crop --enable-filter=scale --enable-filter=pad \
  --enable-filter=transpose --enable-filter=hflip --enable-filter=vflip \
  --enable-filter=yadif --enable-filter=bwdif --enable-filter=deblock \
  --enable-filter=tonemap --enable-filter=monochrome \
  --enable-filter=hwdownload --enable-filter=hwmap --enable-filter=hwupload \
  --enable-muxer=matroska --enable-muxer=webm --enable-muxer=mov --enable-muxer=mp4 \
  --enable-muxer=psp --enable-muxer=ipod --enable-muxer=ass --enable-muxer=srt \
  --enable-muxer=sup \
  --extra-cflags="-O2 -fPIC" \
  > "$LOGS/ffmpeg-configure.log" 2>&1 || {
    echo "=== ffmpeg configure FAILED, tail: ==="; tail -60 "$LOGS/ffmpeg-configure.log"; exit 1; }
log "ffmpeg: configure OK"

log "ffmpeg: make -j$JOBS (this takes a while)"
make -j"$JOBS" > "$LOGS/ffmpeg-build.log" 2>&1 || {
    echo "=== ffmpeg build FAILED, tail: ==="; tail -80 "$LOGS/ffmpeg-build.log"; exit 1; }
log "ffmpeg: make OK"
make install >> "$LOGS/ffmpeg-build.log" 2>&1
log "ffmpeg: installed to $PREFIX"

ls -l "$PREFIX/lib/" | grep -E "libav|libsw" || true
