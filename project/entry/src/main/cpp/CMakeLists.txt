# NAPI module that exposes HandBrake to ArkTS.
#
# Design decision: rather than re-implementing libhb's job setup in glue code, we
# compile HandBrake's *own* CLI driver (test/test.c + test/parsecsv.c) into this
# module and call its entry point.  That is exactly the logic HandBrakeCLI uses,
# so the whole CLI feature set (presets, option parsing, job pipeline, progress)
# becomes available to the app with almost no porting surface.
#
# Two renames are required, applied only to test.c:
#   main -> hbcli_main   : we must not define a second `main` inside a HAP.
#   exit -> hbcli_exit   : test.c calls exit() once (line ~1115); calling the real
#                          exit() from inside an app would kill the process, so it
#                          is redirected to a longjmp-based shim in napi_init.cpp.
# (Macro replacement never touches string literals, so CLI help text is unaffected.)
#
# The cross-built HandBrake prefix and source root are passed in by hvigor via
# entry/build-profile.json5 -> buildOption.externalNativeOptions.arguments.
cmake_minimum_required(VERSION 3.16)
project(handbrake_napi C CXX)

set(HB_PREFIX "" CACHE PATH "OHOS cross-built HandBrake + dependency prefix")
set(HB_SRC    "" CACHE PATH "HandBrake source root")

if(NOT HB_PREFIX OR NOT HB_SRC)
  message(FATAL_ERROR "Pass -DHB_PREFIX=<prefix> -DHB_SRC=<handbrake src>")
endif()

add_library(handbrake SHARED
    napi_init.cpp
    ${HB_SRC}/test/test.c
    ${HB_SRC}/test/parsecsv.c)

# Only test.c gets the renames; napi_init.cpp keeps normal semantics.
set_source_files_properties(${HB_SRC}/test/test.c PROPERTIES
    COMPILE_DEFINITIONS "main=hbcli_main;exit=hbcli_exit")

target_include_directories(handbrake PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}
    ${HB_PREFIX}/include      # generated handbrake/project.h
    ${HB_SRC}/libhb           # handbrake/*.h
    ${HB_SRC}/test)

# NOTE: __LIBHB__ is deliberately NOT defined here.  It is a libhb-internal
# switch (upstream sets it only for LIBHB.GCC.D) and it makes handbrake.h pull in
# handbrake/internal.h, which contains C-only constructs that a C++ translation
# unit cannot parse.  HandBrake's own CLI (test.c) is built without it too.
target_compile_definitions(handbrake PRIVATE
    SYS_LINUX
    _LARGEFILE_SOURCE
    _FILE_OFFSET_BITS=64
    HAS_STRERROR_R)

target_link_libraries(handbrake PUBLIC
    libace_napi.z.so
    libhilog_ndk.z.so
    ${HB_PREFIX}/lib/libhandbrake.a
    ${HB_PREFIX}/lib/libavformat.a
    ${HB_PREFIX}/lib/libavfilter.a
    ${HB_PREFIX}/lib/libavcodec.a
    ${HB_PREFIX}/lib/libswresample.a
    ${HB_PREFIX}/lib/libswscale.a
    ${HB_PREFIX}/lib/libavutil.a
    ${HB_PREFIX}/lib/libx264.a
    ${HB_PREFIX}/lib/libx265.a
    ${HB_PREFIX}/lib/libjansson.a
    ${HB_PREFIX}/lib/libogg.a
    ${HB_PREFIX}/lib/libturbojpeg.a
    ${HB_PREFIX}/lib/libjpeg.a
    # subtitle burn-in: libass -> harfbuzz/freetype/fribidi
    ${HB_PREFIX}/lib/libass.a
    ${HB_PREFIX}/lib/libharfbuzz.a
    ${HB_PREFIX}/lib/libfreetype.a
    ${HB_PREFIX}/lib/libfribidi.a
    ${HB_PREFIX}/lib/libmp3lame.a
    z m dl pthread)

# Same reason as for libhandbrake.so: FFmpeg's aarch64 assembly uses
# R_AARCH64_ADR_PREL_PG_HI21 against globals that lld treats as preemptible.
target_link_options(handbrake PRIVATE -Wl,-Bsymbolic -Wl,--exclude-libs,ALL)
