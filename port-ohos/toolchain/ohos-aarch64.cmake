# ohos-aarch64.cmake -- cross-compilation toolchain for building third-party
# libraries for HarmonyOS / OpenHarmony arm64 (aarch64-linux-ohos, musl).
#
# This is an alternative to DevEco's own
#   $OHOS_SDK/native/build/cmake/ohos.toolchain.cmake
# and exists because of two concrete problems hit while porting x265:
#
#  1) CMAKE_SYSTEM_NAME is deliberately **Linux**, not OHOS.
#     x265's CMakeLists.txt (lines 89-92) does:
#         if(NOT CMAKE_SYSTEM_NAME MATCHES "Linux|Darwin|Windows")
#             set(AARCH64_RUNTIME_CPU_DETECT OFF CACHE BOOL "" FORCE)
#     so an "OHOS" system name makes x265 believe it is on an unknown platform,
#     disables run-time CPU feature detection, and takes its non-Linux branches.
#     HarmonyOS userland really is Linux+musl, so describing it as Linux is both
#     accurate and what such projects expect.
#
#  2) The compilers are .cmd wrappers that bake in --target/--sysroot.
#     CMake applies CMAKE_*_COMPILER_TARGET only to regular compile rules; it is
#     NOT injected into add_custom_command, which is exactly how x265 assembles
#     its aarch64 .S files.  Without the wrapper those commands fall back to the
#     host target and fail with "unknown target CPU 'armv8-a'".
#
# Paths are ASCII on purpose: CMake+Ninja mis-encode non-ASCII paths when writing
# the link response file, and hvigor rejects non-ASCII project paths outright.

set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR aarch64)

set(OHOS_TOOLCHAIN_ROOT "D:/ohosndk")
set(OHOS_SYSROOT        "D:/ohosndk/sysroot")

set(CMAKE_C_COMPILER   "D:/hbohos/port-ohos/toolchain/ohos-cc.cmd")
set(CMAKE_CXX_COMPILER "D:/hbohos/port-ohos/toolchain/ohos-cxx.cmd")
set(CMAKE_AR           "D:/ohosndk/llvm/bin/llvm-ar.exe")
set(CMAKE_RANLIB       "D:/ohosndk/llvm/bin/llvm-ranlib.exe")
set(CMAKE_STRIP        "D:/ohosndk/llvm/bin/llvm-strip.exe")
set(CMAKE_NM           "D:/ohosndk/llvm/bin/llvm-nm.exe")
set(CMAKE_LINKER       "D:/ohosndk/llvm/bin/ld.lld.exe")

set(CMAKE_SYSROOT "${OHOS_SYSROOT}")

# The wrappers already pass --target/--sysroot/-D__MUSL__, so nothing extra here.
set(CMAKE_C_FLAGS_INIT   "")
set(CMAKE_CXX_FLAGS_INIT "")

set(CMAKE_FIND_ROOT_PATH "${OHOS_SYSROOT}")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

# Static libraries get linked into a shared object later, so they must be PIC.
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
