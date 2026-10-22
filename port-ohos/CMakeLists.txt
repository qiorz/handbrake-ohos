# CMake project that builds HandBrake's libhb for HarmonyOS / OpenHarmony arm64.
#
# This deliberately bypasses HandBrake's own GNU-make build system.  Reasons:
#   * `LIBHB.c` is a `$(wildcard libhb/*.c)` -- there is no supported way to
#     drop individual translation units, and the contrib bootstrap for the ~26
#     third-party libraries is not targetable at OHOS from a Windows host.
#   * We already cross-built the libraries libhb genuinely needs (FFmpeg, x264,
#     jansson, libogg, libjpeg-turbo) with tools/build-*.sh.
# See docs/ for the full porting write-up.
#
# Configure with the OHOS NDK toolchain file shipped by DevEco Studio, e.g.
#   cmake -G Ninja \
#     -DCMAKE_TOOLCHAIN_FILE=D:/ohosndk/build/cmake/ohos.toolchain.cmake \
#     -DOHOS_ARCH=arm64-v8a -DCMAKE_BUILD_TYPE=Release \
#     -DHB_SRC=<handbrake source> -DHB_DEPS=<cross-built prefix> ..
cmake_minimum_required(VERSION 3.16)
project(handbrake_ohos C CXX)

set(HB_SRC  "" CACHE PATH "HandBrake source root (contains libhb/)")
set(HB_DEPS "" CACHE PATH "Prefix of the OHOS cross-built dependencies")
if(NOT HB_SRC OR NOT HB_DEPS)
  message(FATAL_ERROR "Set -DHB_SRC=<handbrake src> and -DHB_DEPS=<prefix>")
endif()

set(HB_GENERATED "${CMAKE_CURRENT_SOURCE_DIR}/generated")

# ---------------------------------------------------------------------------
# libhb sources, minus the translation units whose third-party dependency is
# not part of this port (see stubs/ohos_stubs.c for the matching replacements).
# ---------------------------------------------------------------------------
file(GLOB LIBHB_ALL "${HB_SRC}/libhb/*.c")
set(LIBHB_EXCLUDE
    enctheora.c    # libtheora
    encvorbis.c    # libvorbis
    encsvtav1.c    # SVT-AV1
    dvd.c          # libdvdread
    dvdnav.c       # libdvdnav
    bd.c           # libbluray
)
set(LIBHB_SOURCES "")
foreach(f ${LIBHB_ALL})
  get_filename_component(_n "${f}" NAME)
  list(FIND LIBHB_EXCLUDE "${_n}" _i)
  if(_i EQUAL -1)
    list(APPEND LIBHB_SOURCES "${f}")
  endif()
endforeach()
list(APPEND LIBHB_SOURCES "${CMAKE_CURRENT_SOURCE_DIR}/stubs/ohos_stubs.c")
list(LENGTH LIBHB_SOURCES LIBHB_COUNT)
message(STATUS "libhb: compiling ${LIBHB_COUNT} translation units")

# Static archive: this is what the NAPI module inside the HAP links against.
add_library(handbrake STATIC ${LIBHB_SOURCES})
# Shared library: forces every symbol to resolve, which is a cheap and very
# effective completeness check for the stub layer above.
add_library(handbrake_shared SHARED ${LIBHB_SOURCES})

set(DEPS_LIBS
    "${HB_DEPS}/lib/libavformat.a"
    "${HB_DEPS}/lib/libavfilter.a"
    "${HB_DEPS}/lib/libavcodec.a"
    "${HB_DEPS}/lib/libswresample.a"
    "${HB_DEPS}/lib/libswscale.a"
    "${HB_DEPS}/lib/libavutil.a"
    "${HB_DEPS}/lib/libx264.a"
    # x265 是 C++，且是多比特位合并库（8/10/12-bit 三个命名空间）。
    # 链接它会把 libc++ 依赖带进来，所以下面 handbrake_shared 用 C++ 驱动做链接。
    "${HB_DEPS}/lib/libx265.a"
    "${HB_DEPS}/lib/libjansson.a"
    "${HB_DEPS}/lib/libogg.a"
    "${HB_DEPS}/lib/libturbojpeg.a"
    "${HB_DEPS}/lib/libjpeg.a"
    # subtitle burn-in (libass -> harfbuzz -> freetype/fribidi)
    "${HB_DEPS}/lib/libass.a"
    "${HB_DEPS}/lib/libharfbuzz.a"
    "${HB_DEPS}/lib/libfreetype.a"
    "${HB_DEPS}/lib/libfribidi.a"
    "${HB_DEPS}/lib/libmp3lame.a"
)

foreach(t handbrake handbrake_shared)
  target_include_directories(${t} PRIVATE
      "${HB_GENERATED}"          # handbrake/project.h
      "${CMAKE_CURRENT_SOURCE_DIR}/shims"  # libbluray/bluray.h shim (see file header)
      "${HB_SRC}/libhb"          # handbrake/*.h + templates/
      "${HB_DEPS}/include")
  target_compile_definitions(${t} PRIVATE
      __LIBHB__
      SYS_LINUX
      _LARGEFILE_SOURCE
      _FILE_OFFSET_BITS=64
      HAS_STRERROR_R)            # musl has a POSIX strerror_r; don't use the stub
  target_compile_options(${t} PRIVATE -O2 -fPIC -Wno-unused-parameter)
  target_link_libraries(${t} PUBLIC ${DEPS_LIBS} z m dl pthread)
endforeach()

# Statically linking FFmpeg into a shared object needs -Bsymbolic.
# FFmpeg's aarch64 assembly (e.g. libavutil/aarch64/tx_float_neon.S) reaches
# global data with R_AARCH64_ADR_PREL_PG_HI21 / ADD_ABS_LO12_NC, which assume a
# fixed PC-relative offset.  In a DSO those globals are preemptible by default,
# so lld rejects the relocations with "cannot be used against symbol ...
# recompile with -fPIC" even though the objects *were* built -fPIC.  Binding
# symbols locally (-Bsymbolic) makes the offsets fixed again; --exclude-libs,ALL
# additionally keeps the statically linked libraries' symbols out of the export
# table.  OpenHarmony's own FFmpeg build uses the same recipe.
target_link_options(handbrake_shared PRIVATE -Wl,-Bsymbolic -Wl,--exclude-libs,ALL -Wl,--error-limit=0)

set_target_properties(handbrake_shared PROPERTIES OUTPUT_NAME handbrake)

# libx265.a is C++, so the shared library has to be linked by the C++ driver
# (clang++), otherwise libc++ symbols such as operator new / __cxa_* stay
# unresolved.  All of libhb's own sources are C, so CMake would otherwise pick
# the C linker based on the sources alone.
set_target_properties(handbrake_shared PROPERTIES LINKER_LANGUAGE CXX)

install(TARGETS handbrake handbrake_shared
        ARCHIVE DESTINATION lib
        LIBRARY DESTINATION lib)
install(FILES "${HB_GENERATED}/handbrake/project.h"
        DESTINATION include/handbrake)
