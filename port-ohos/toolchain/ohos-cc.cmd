@echo off
rem OHOS arm64 C compiler driver for CMake/Ninja builds (MSYS2 variants exist in
rem tools/ohos-cc, but those are shell scripts and CMake+Windows CreateProcess
rem cannot exec a shebang script).
rem
rem Why a .cmd wrapper is needed at all: CMake injects --target only for regular
rem compile rules, NOT for add_custom_command.  x265 assembles its aarch64 .S
rem files through add_custom_command with ${CMAKE_CXX_COMPILER}, so the target
rem has to be baked into the compiler command itself.  Ninja on Windows runs
rem commands through cmd.exe /C, so a .cmd file works.
rem
rem Lives under an ASCII path on purpose: CMake+Ninja mis-encode non-ASCII paths.
"D:\ohosndk\llvm\bin\clang.exe" --target=aarch64-linux-ohos --sysroot=D:/ohosndk/sysroot -D__MUSL__ %*
