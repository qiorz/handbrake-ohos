#!/bin/bash
# Standalone FFmpeg (with libmp3lame) build for OHOS arm64 — Linux build host variant.
# Overridable: HBROOT (repo root), OHOS_NDK, HB_DOWNLOADS, HB_SRC.
set -e
B=${HBROOT:-$(cd "$(dirname "$0")" && pwd)}
NDK=${OHOS_NDK:?set OHOS_NDK to <sdk>/default/openharmony/native}
export OHOS_NDK HBROOT
PREFIX=$B/out/ohos-arm64
SRC=${HB_DOWNLOADS:-$B/src/downloads}
HB=${HB_SRC:-$B/src/handbrake}
[ -d "$HB" ] || HB=$B/src/handbrake-1.11.2
W=$B/ffmpeg-src

rm -rf $W && mkdir -p $W && cd $W
tar xf $SRC/ffmpeg-8.0.2.tar.bz2
cd ffmpeg-8.0.2
echo "== apply HandBrake patches =="
for p in $HB/contrib/ffmpeg/A*.patch; do
  patch -p1 --forward --batch --no-backup-if-mismatch -i "$p" >/dev/null 2>&1 || true
done
echo "== configure =="
CC="$B/toolchain/aarch64-ohos-cc"
./configure \
  --prefix=$PREFIX --target-os=linux --arch=aarch64 --cpu=armv8-a \
  --enable-cross-compile --host-cc=gcc --cc="$CC" --cxx="$B/toolchain/aarch64-ohos-cxx" \
  --ar="$NDK/llvm/bin/llvm-ar" --ranlib="$NDK/llvm/bin/llvm-ranlib" \
  --strip="$NDK/llvm/bin/llvm-strip" --nm="$NDK/llvm/bin/llvm-nm" \
  --enable-static --disable-shared --enable-gpl --disable-autodetect --enable-pthreads \
  --disable-stripping --disable-doc --disable-programs --disable-avdevice --disable-network \
  --disable-vaapi --disable-vdpau --disable-vulkan --disable-cuda --disable-cuvid \
  --disable-hwaccels --disable-muxers --disable-encoders --disable-filters \
  --disable-bzlib --disable-lzma --disable-iconv \
  --disable-sdl2 --disable-xlib --disable-libxcb --disable-libdrm \
  --disable-libx264 --disable-libx265 --disable-libvpx --disable-libdav1d \
  --disable-libaom --disable-libsvtav1 --disable-libvvenc --disable-librav1e \
  --enable-libmp3lame --disable-libopus --disable-libspeex --disable-libvorbis \
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
  --enable-encoder=pcm_s16le --enable-encoder=pcm_s24le --enable-encoder=libmp3lame \
  --enable-decoder=av1 \
  --enable-filter=format --enable-filter=crop --enable-filter=scale --enable-filter=pad \
  --enable-filter=transpose --enable-filter=hflip --enable-filter=vflip \
  --enable-filter=yadif --enable-filter=bwdif --enable-filter=deblock \
  --enable-filter=tonemap --enable-filter=monochrome \
  --enable-filter=hwdownload --enable-filter=hwmap --enable-filter=hwupload \
  --enable-muxer=matroska --enable-muxer=webm --enable-muxer=mov --enable-muxer=mp4 \
  --enable-muxer=psp --enable-muxer=ipod --enable-muxer=ass --enable-muxer=srt --enable-muxer=sup \
  --extra-cflags="-O2 -fPIC -I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib"
echo "== make =="
make -j2
echo "== install =="
make install
echo "FFMPEG_MP3_OK"
