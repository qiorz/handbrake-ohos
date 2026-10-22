# toolchain — 参考交叉配置

这些文件是在**参考构建机**上验证过的配置，换机器后需要改成本机路径。

| 文件 | 用途 |
|---|---|
| `aarch64-ohos-cc` / `-cxx` | clang wrapper，读环境变量 `OHOS_NDK`（指向 `<sdk>/default/openharmony/native`） |
| `ohos-cmake.ini` | CMake toolchain file，读 `HBROOT` 与 `OHOS_NDK` |
| `ohos-cross.ini` | Meson cross file **模板**，需先用 `envsubst` 替换 `@OHOS_NDK@` / `@HBROOT@` |

用法：

```bash
export HBROOT=$PWD
export OHOS_NDK=/path/to/sdk/default/openharmony/native
cmake -DCMAKE_TOOLCHAIN_FILE=toolchain/ohos-cmake.ini ...
```
