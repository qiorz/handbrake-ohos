@echo off
rem OHOS arm64 C++ compiler driver for CMake/Ninja builds.  See ohos-cc.cmd.
"D:\ohosndk\llvm\bin\clang++.exe" --target=aarch64-linux-ohos --sysroot=D:/ohosndk/sysroot -D__MUSL__ %*
