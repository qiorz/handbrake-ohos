# HandBrake → HarmonyOS（OHOS arm64）移植

> [!IMPORTANT]
> **状态说明（置顶）**
>
> - **未做 UI 美化**：界面只做到“能操作”，没有视觉设计、没有动效，控件与布局都很朴素。
> - **更新随缘**：个人业余项目，更新节奏不固定，issue / PR 可能长期不处理，不承诺任何时间点。
> - **相关项目**：[Aegisub → HarmonyOS 移植](https://github.com/qiorz/aegisub-ohos)

把 [HandBrake](https://handbrake.fr) 的视频转码引擎（libhb + 其自带 CLI 驱动）交叉编译为
OHOS arm64 动态库，通过 NAPI 暴露给 ArkTS 应用，在 HarmonyOS 设备上直接跑 HandBrakeCLI 的
完整能力（preset、参数解析、job pipeline、进度回调）。

> **English**: A port of HandBrake's transcoding engine (libhb + the CLI driver) to
> HarmonyOS / OpenHarmony arm64 (musl), packaged as a NAPI module inside an ArkTS app.
> Licensed GPL-2.0. No binaries, SDK files or signing material are distributed here.

## 当前状态

- 引擎（libhb）交叉编译通过，HAP 可构建，真机 x264 转码已跑通。
- 详细进度、已知问题与踩坑记录见 [`docs/`](docs/)。
- 可安装的 HAP 见本仓库 **Releases**（二进制不入库）。

## 目录结构

```
port-ohos/        交叉编译 libhb 所需的 CMake 工程、补丁、shim、stub
tools/            依赖构建脚本（x264 / x265 / ffmpeg / jansson / libogg / libjpeg / libhb）
toolchain/        参考交叉工具链配置（clang wrapper、CMake / Meson cross file）
project/          HarmonyOS 应用工程（entry 模块 + NAPI + ArkTS 页面）
docs/             移植心得、验证报告
build-ffmpeg-mp3.sh  FFmpeg（含 libmp3lame）单编脚本
```

## 上游基线

| 项 | 值 |
|---|---|
| 上游项目 | HandBrake 1.11.2 |
| 上游 commit | `9eb6c936803e8b071035b1a77662cb0db58441ea` |
| 目标平台 | HarmonyOS 7.0 / API 26 / arm64-v8a / musl |
| 工具链 | DevEco Studio 26.0.0.851，OHOS NDK clang 15.0.4 |

## 构建前提

1. DevEco Studio（含 OHOS NDK），并让 `hvigorw` 可用；
2. bash 环境（Windows 下为 MSYS2），脚本按 MSYS2 路径书写；
3. **纯 ASCII 路径**：hvigor 会以 `00306003 Invalid project path` 拒绝非 ASCII 工程路径，
   CMake+Ninja 也会在 link response file 里把中文路径编码坏掉；
4. 自行准备依赖源码（见下节）。

## 准备依赖源码

本仓库**不包含**上游与第三方源码包（体积原因）。请把它们放到 `src/` 下：

```bash
export HBROOT=$PWD
mkdir -p src/downloads
# HandBrake 源码（必须是上表 commit）
git clone https://github.com/HandBrake/HandBrake.git src/handbrake
git -C src/handbrake checkout 9eb6c936803e8b071035b1a77662cb0db58441ea
# 第三方源码包放入 src/downloads/：ffmpeg、x264、x265、jansson、libogg、libjpeg-turbo
```

`tools/env.sh` 会自动把 `HBROOT` 取成脚本所在目录的上一级，解压即用；
若仓库放在非 ASCII 路径下，必须显式 `export HBROOT=/ascii/path`。

## 构建

```bash
bash tools/build-x264.sh
bash tools/build-ffmpeg.sh
bash tools/patch-ffmpeg.sh      # 必需：给 FFmpeg 打 HandBrake 的 25 个补丁
bash tools/build-jansson.sh
bash tools/build-libogg.sh
bash tools/build-jpeg.sh
bash tools/build-x265.sh
bash tools/build-libhb.sh       # 产出 out/ohos-arm64/lib/libhandbrake.{a,so}
```

## 构建 HAP

```bash
cd project
hvigorw assembleHap --no-daemon
# 未签名产物：entry/build/default/outputs/default/entry-default-unsigned.hap
```

签名需要**你自己的**华为开发者证书与 profile（`bundle-name` 必须为 `com.handbrake.ohos`，
且 profile 的 `debug-info.device-ids` 包含你的设备 UDID）。把签名配置填进
`project/build-profile.json5` 的 `signingConfigs`。本仓库不含任何签名材料。

`project/entry/build-profile.json5` 里 `externalNativeOptions.arguments` 的两个 `-D` 路径
（`HB_PREFIX`、`HB_SRC`）指向本机的构建产物目录，**换机器后需要改成你的实际路径**。

## 相关项目

- [Aegisub → HarmonyOS 移植](https://github.com/qiorz/aegisub-ohos) —— 字幕编辑 / 打轴工具的 OHOS 移植，
  与本项目同源思路（OHOS NDK 交叉编译 + ArkTS 外壳）。

## 许可与合规

- 上游 HandBrake 采用 **GPL-2.0**；本项目是它的派生作品，同样以 GPL-2.0 发布，全文见 [LICENSE](LICENSE)。
- 本项目链接了 `--enable-gpl` 的 FFmpeg 以及 x264 / x265，因此产出的
  `libhandbrake.so` **只能按 GPL 分发**，并须附带对应源码。
- 本仓库是**修改版**：修改集中在 `port-ohos/patches/`、`port-ohos/shims/`、
  `port-ohos/stubs/` 与 `project/entry/src/main/cpp/`。上游原始文件未被重写。
- 本仓库**不包含**：HandBrake 官方二进制、DevEco / OHOS SDK 的头文件或库（华为许可限制）、
  任何签名证书与私钥、设备日志。
- “HandBrake” 名称与图标归上游项目所有，本项目与上游无隶属关系。

## 获取二进制

HAP 安装包、完整的移植交接包等大文件放在 **Releases**，不放入 git 历史，
以免触发 GitHub 单文件 100 MB 上限、并保持仓库可快速 clone。
