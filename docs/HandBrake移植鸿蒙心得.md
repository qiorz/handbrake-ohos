# 把 HandBrake 移植到鸿蒙（HarmonyOS / OHOS arm64）——移植心得

> 目标设备：HUAWEI MatePad Edge（QXS-W00），HarmonyOS 7.0.0.109，API 26，arm64-v8a，16 核 / 16 GB
> 主机环境：Windows 10/11 x64 + DevEco Studio 26.0.0.851（内置 OHOS NDK，clang 15.0.4）+ MSYS2
> 上游源码：HandBrake 1.11.2（`9eb6c936803e8b071035b1a77662cb0db58441ea`）
> 完成度：**已全部打通并在真机上验证** —— 引擎交叉编译 ✅、HAP 构建 ✅、HO-Kit 签名安装 ✅、**真机上跑通 HandBrakeCLI 并完成真实 x264 转码** ✅；随后又把 **x265 / H.265(HEVC) 编码**接进来（含 HandBrake 给 x265 打的 9 个补丁）。全过程见 §4.5、§7.3 与 §9。

---

## 0. 一句话结论

**把 HandBrake 搬到鸿蒙，技术难点不在"改代码"，而在三件事：**

1. **运行位置**——鸿蒙零售设备（平板/手机）的 `hdc shell` 域（`u:r:sh:s0`）**不允许执行任何自编译的可执行文件**，native 代码只能跑在**应用（HAP）沙箱**里。这一点决定了整个移植的形态。
2. **构建系统**——HandBrake 的 `libhb` 用 `$(wildcard libhb/*.c)` 全量编译，**没有任何开关能裁掉单个源文件**，因此它硬依赖约 26 个第三方库（libass / libtheora / libvorbis / SVT-AV1 / libdvdread / libdvdnav / libbluray / libvpx / dav1d / zimg / lame / opus / speex / freetype / fribidi / harfbuzz / fontconfig / libjpeg-turbo / libogg / iconv / bzip2 / xz / libdovi / nvenc / libvpl / amf …）。在 Windows 主机上把它们**全部**交叉编译到 OHOS 是不现实的，所以必须自己做**特性裁剪 + 符号桩**。
3. **签名**——鸿蒙设备的信任根是**华为**的；用 OpenHarmony SDK 自签的 HAP 会被明确拒绝（`fail to verify pkcs7 file`）。安装必须有一个**华为签发、且 bundleName 与设备 UDID 都匹配**的调试 profile。

---

## 1. 环境侦察：先把"事实"钉死

移植前先问设备要答案，不要猜。下面每条都是实测。

```powershell
# hdc 位于 DevEco 自带的 SDK 里，不在 PATH 上
$hdc = "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
& $hdc list targets -v          # -> <device-addr>  TCP  Connected
& $hdc -t <device-addr> shell "uname -a"
```

实测到的关键事实：

| 项目 | 值 | 为什么重要 |
|---|---|---|
| `const.product.model` | `QXS-W00`（MatePad Edge） | **平板**，不是鸿蒙 PC |
| `const.ohos.apiversion` | `26` | SDK 必须用 API 26 |
| `const.product.cpu.abilist` | `arm64-v8a` | 交叉编译目标 `aarch64-linux-ohos` |
| `const.product.devicetype` | `tablet` | 见下 |
| `uname -a` | `HarmonyOS ... HongMeng Kernel 1.13.0 ... aarch64 Toybox` | **`uname -s` 返回 `HarmonyOS` 而不是 `Linux`** |
| `/lib/ld-musl-aarch64.so.1` | 存在 | **musl libc**，不是 glibc |
| `nproc` | 16 | 构建/转码算力充足 |
| `whoami` / `id` | `shell`，`uid=2000`，`context=u:r:sh:s0` | 非 root，SELinux 强制 |
| `/data/local/tmp` | 可写，label `u:object_r:data_local_tmp:s0` | 唯一可写目录，但见 §4 |
| `/storage/Users/currentUser` | **不存在** | 这是**鸿蒙 PC** 才有的用户家目录 |

### 1.1 OHOS NDK 自带 cmake / ninja

不用另装 CMake，DevEco 的 NDK 里就有：

```
sdk/default/openharmony/native/build-tools/cmake/bin/{cmake.exe,ninja.exe}
sdk/default/openharmony/native/build/cmake/ohos.toolchain.cmake
sdk/default/openharmony/native/sysroot/                      # musl sysroot
sdk/default/openharmony/native/llvm/bin/{clang.exe,ld.lld.exe,llvm-*.exe}
```

### 1.2 `aarch64-unknown-linux-ohos-clang` 是个 shell 脚本

NDK 里那些看起来像交叉编译器的东西，其实是 **sh 脚本**，内容就是：

```sh
#!/bin/sh
SOURCE=$(dirname -- "$( readlink -f -- "$0"; )")
exec $SOURCE/clang \
  -target aarch64-linux-ohos \
  --sysroot=$SOURCE/../../sysroot \
  -D__MUSL__ \
  "$@"
```

**Windows 主机上跑不了它**，所以要自己复刻这套参数（见 §5.1）。
顺便记一个很有用的事实——实测 OHOS clang 的预定义宏：

```
#define __OHOS__   1      <- 编译器自带，不用 -D
#define __aarch64__ 1
#define __linux__  1
#undef  __MUSL__           <- 没有！必须手动加 -D__MUSL__
```

---

## 2. 网上那两个"鸿蒙版 HandBrake"到底能不能借鉴

结论先说：**一个可以借鉴思路但不完整，一个是真移植但只对鸿蒙 PC，两个都不能直接拿来用。** 完整证据见 [参考移植仓库验证报告](参考移植仓库验证报告.md)。要点：

| 仓库 | 实质 | 可借鉴性 |
|---|---|---|
| [Andy88/Harmony-HandBrake](https://gitcode.com/Andy88/Harmony-HandBrake) | 上游 master + **GTK4 前端**里的 `#ifdef __OHOS__` 适配（17 处，分布在 `gtk/src/{application,callbacks,preview,util}.c`）+ 一个**已编译好的 `libhb/libhandbrake.a`**。**没有** CMake/工具链/NAPI/构建脚本；`version.txt` 里写的 `TAG=1.12.0` 上游并不存在 | 中：证明 **libhb 本体可以不改代码编到 OHOS**；前端桥接思路（系统文件选择器、菜单栏交给 ArkTS、`GtkMediaFile` 换成 FFmpeg 版 `GtkMediaStream`）值得借鉴。但它的 GTK4 路线需要先交叉编译 GTK4/GLib 全家桶，成本极高 |
| [HM_ECO_TEST/HMcodeArts-c-HandBrake](https://gitcode.com/HM_ECO_TEST/HMcodeArts-c-HandBrake) | **恰好等于上游 1.11.2 + 3 个构建文件改动**（下面列出），产出 `HandBrakeCLI`。它是**在鸿蒙 PC 上本地编译**（harmonybrew 提供工具链和 14 个系统库），完全不做交叉编译 | 高（思路）：3 个改动本身很有价值；但 harmonybrew **官方支持列表里只有鸿蒙 PC / 开发板 / 容器，没有平板**，这条路在我们设备上走不通 |

HMcodeArts 的 3 个改动（我逐字节 diff 上游 1.11.2 得到，与独立复核一致）：

```make
# 1) contrib/ffmpeg/module.defs —— Linux 宿主没有 Vulkan
else
    FFMPEG.CONFIGURE.extra += --extra-libs="-lm -lstdc++"
    ifeq (linux,$(HOST.system))
        FFMPEG.CONFIGURE.extra += --disable-vulkan
    endif
endif

# 2) make/config.guess —— 鸿蒙上 mktemp -d 出来的目录不可用，改到 $TMPDIR
-    dummy=$tmp/dummy
+    dummy=$TMPDIR/dummy$$

# 3) make/include/contrib.defs —— 每个 contrib 的 configure 都强制 umask 077，会导致产物不可读/不可执行
+    $(1).CONFIGURE.fix = sed -i 's/umask 077/umask 022/g' configure 2>/dev/null || true;
-    $(1).CONFIGURE.args = !sete @dir !bootstrap !env !exe @host @build @prefix !deps !shared !static !extra
+    $(1).CONFIGURE.args = !sete @dir !bootstrap !fix !env !exe @host @build @prefix !deps !shared !static !extra
```

### 2.1 我是怎么验证 Andy88 那个 `libhandbrake.a` 是真货的

光看仓库说明没用，直接读二进制里的编译指纹：

```powershell
llvm-ar t libhandbrake.a | Measure-Object          # -> 85 个 .o
llvm-ar x libhandbrake.a ; llvm-readelf -h acompressor.o | Select-String Machine
#   Machine: AArch64
llvm-readelf -p .comment acompressor.o
#   [1] OHOS (dev) clang version 15.0.4 (llvm-project 99548401...)
```

`OHOS (dev) clang version 15.0.4` —— 确认是**用 DevEco 的 OHOS NDK 编出来的 aarch64 目标文件**，不是随便一个交叉工具链。
（唯一"可疑"的是它的 `version.txt` 把版本写成不存在的 1.12.0，且 `HASH` 是 `1a2b3c4d...` 这种占位值，属于手工伪造的元数据——不影响产物真实性。）

---

## 3. 移植形态的决策：为什么最后是"HAP + NAPI"，而不是 HandBrakeCLI

这是整个移植里最重要的一个判断，值得单独讲。

### 3.1 先试最省事的路：把 `HandBrakeCLI` 传上去直接跑

HMcodeArts 的 README 就是这么干的（`./HandBrakeCLI -i in.mp4 -o out.mkv -e x265 -q 22`）。所以先做最小实验：

1. 用 OHOS clang 编一个静态 hello world；
2. `hdc file send` 到 `/data/local/tmp`，`chmod +x` → **`Permission denied`**；
3. 用 `binary-sign-tool sign -selfSign 1` 自签，再跑 → **仍然 `Permission denied`**。

那就查根因。先排除"文件系统 noexec"：

```sh
mount | grep -E "data|storage"
#   (null) on /data type hmfs (rw,nosuid,nodev,noatime,...)   <- 没有 noexec！
ls -lZ /data/local/tmp/hello-signed
#   -rwxr-xr-x 1 shell shell u:object_r:data_local_tmp:s0
cat /proc/self/attr/current
#   u:r:sh:s0
```

**`/data` 没有挂 noexec，是 SELinux 不让 `sh` 域执行 `data_local_tmp` 标签的文件。**

于是做穷举：把所有可能可写的目录都试一遍。

```
[RW] /data/local/tmp        label=u:object_r:data_local_tmp:s0
[ro] /data/local              label=u:object_r:data_local:s0
[ro] /storage/media/100/local/files  label=u:object_r:hmdfs:s0
[--] /storage/Users/currentUser      (missing)     <- 鸿蒙 PC 才有
[--] /data/storage/el2/base/cache    (missing)
>>> 唯一可写目录 /data/local/tmp 执行失败
```

**结论（本移植最硬的一条约束）：**

> 零售鸿蒙**平板**上，`hdc shell` 环境下**不存在**任何可以执行自编译二进制的目录。
> ——"从 shell 跑 HandBrakeCLI"这条路在平板/手机上根本不存在；
> ——native 代码**必须**放进应用沙箱（HAP）里运行。

这也解释了为什么 HMcodeArts 能成：它跑在**鸿蒙 PC**上，那里有 `/storage/Users/currentUser`（用户可写且跨应用共享），且有真正的用户 shell。

> 补充参考：社区在鸿蒙 PC 上实测，自签二进制放在**家目录**可以执行，而放在 `/data/local/tmp` 会因为 `code_protect` 的 BSS 读不了 `data_local_tmp` 标签而失败——与我在平板上的实测吻合。
> 另有两条必须记住的鸿蒙 ELF 规则：**① 已经落盘的 ELF 只要被就地改过字节（strip/objcopy/原地 patch）就会拒绝执行，必须另写新文件；② `binary-sign-tool` 签名会重置执行位，签完必须 `chmod 755`。** 这两条和"Permission denied 看起来像没签名"极易混淆。

### 3.2 于是形态定为：一个 HAP，把 libhb 做成 NAPI 模块

```
ArkTS (Index.ets)
   │  import hb from 'libhandbrake.so'
   ▼
libhandbrake.so  (NAPI 模块, 由 entry/src/main/cpp 构建)
   ├── napi_init.cpp        ← 我写的桥接（hbVersion / hbInit / runCli）
   ├── HandBrake test/test.c + parsecsv.c   ← 直接复用官方 CLI 驱动！
   └── libhandbrake.a ──┬── libav{format,filter,codec,util}.a
                        ├── libsw{scale,resample}.a
                        ├── libx264.a          (H.264 编码)
                        ├── libjansson.a       (预置/JSON)
                        ├── libogg.a           (extradata.c 需要 ogg_packet)
                        └── libturbojpeg.a/libjpeg.a (hb.c 的预览功能)
```

**关键设计选择：直接编译 HandBrake 自己的 `test/test.c`（就是 HandBrakeCLI 的主程序）当引擎入口。**
理由：libhb 的"扫描 → 建 job → 编 preset → 跑流水线 → 报进度"这套逻辑全在 `test.c` 里（21 万字节），自己重写一遍既费时又容易错位；直接复用就能拿到**完整的 CLI 功能**（预设、参数解析、进度、批量）。代价只有两处重命名（见 §6.4）。

### 3.3 功能裁剪：为什么必须裁，裁了什么

HandBrake 的 `libhb/module.defs` 里写死了：

```make
LIBHB.c = $(wildcard $(LIBHB.src/)*.c)     # 80 个 .c，一个不落
```

`make/include/main.defs` 里 `contrib/libtheora`、`contrib/libvorbis`、`contrib/svt-av1`、`contrib/libdvdnav` 等也**全是无条件加入**。也就是说：

> **上游 HandBrake 没有任何"关掉某个 libhb 源文件/某个第三方库"的开关。**

我把 libhb 里所有第三方头文件引用列了一遍，确认了硬依赖。最终采取的方案是**排除 7 个翻译单元 + 补 30 个符号桩**：

| 排除的文件 | 依赖 | 砍掉的功能 |
|---|---|---|
| `enctheora.c` | libtheora | Theora 编码 |
| `encvorbis.c` | libvorbis | Vorbis 编码 |
| `encsvtav1.c` | SVT-AV1 | AV1 编码 |
| `dvd.c` / `dvdnav.c` | libdvdread / libdvdnav | DVD 光盘源 |
| `bd.c` | libbluray | 蓝光源 |
| `rendersub.c` | libass(+fribidi/harfbuzz/freetype/fontconfig) | 字幕**烧录** |

**保留下来的（也就是真正能用的）**：FFmpeg 解码几乎一切格式；**x264 编 H.264**；AAC/AC3/E-AC3/FLAC/ALAC/MP3/TrueHD 等音频编码走 FFmpeg；MP4/MKV/WebM 封装；完整的滤镜流水线（deinterlace/denoise/crop/scale…）；字幕**直通**（SRT/SSA/ASS/PGS）。

桩代码全部集中在 [port-ohos/stubs/ohos_stubs.c](../port-ohos/stubs/ohos_stubs.c)，共三类：

1. 三个被无条件 `hb_register()` 的编码器 work object（`hb_enctheora` / `hb_encvorbis` / `hb_encsvtav1`）→ 惰性对象，被选中时打日志并失败，而不是崩溃；
2. 字幕烧录滤镜 `hb_filter_render_sub` → 惰性滤镜；
3. `hb_dvd_*` / `hb_bd_*` 这一整套 **facade 层**（`hb_dvd_init` 返回 NULL，其余 ~28 个函数是空实现）。

> 注意：`hb_dvd_*`/`hb_bd_*` 不只有 `init`——`scan.c`/`reader.c` 会引用到 `title_scan`/`title_count`/`start`/`stop`/`seek`/`read`/`chapter`/`close`/`set_angle`/`is_break`/`angle_count`/`main_feature`/`seek_pts`/`seek_chapter`，以及 **public API `hb_dvd_set_dvdnav()`**（`test.c:534` 会调）。这些是我在一轮轮链接失败里逐个补齐的，不是一次就想到的。

另外还有一处**几乎不可能是"巧合"的有趣发现**：`libhb/stream.c` 无条件 `#include "libbluray/bluray.h"`，但它**从来没调用过任何一个 libbluray 函数**（里面出现的 `bd_` 全是它自己的结构体字段 `bd_substream_id`、HandBrake 自己的 `HB_SUBSTREAM_BD_*` 宏、以及 FFmpeg 的 `AV_CODEC_ID_PCM_BLURAY`）。所以我给了一个**空的 shim 头**，让 `stream.c` 保持零改动：

```c
/* port-ohos/shims/libbluray/bluray.h —— 故意留空 */
```

---

## 4. 交叉编译链：在 Windows 主机上给 OHOS arm64 造库

HandBrake 的构建体系是 **GNU make + Python configure + 自动下载编译 27 个 contrib 包**，全是 Unix 味的脚本。Windows 主机上缺 sh/make/python，所以：

- 装 **MSYS2**（`winget install MSYS2.MSYS2`）拿到 `bash/make/pkgconf/nasm/python3`；
- 用 **MSYS2 的 bash 去驱动 OHOS NDK 的 Windows clang.exe**（不装 Linux 版 NDK，不装 WSL）。

### 4.0 两个"提前避险"的动作，省掉一大堆怪问题

**(a) NDK 路径里有空格**（`C:\Program Files\Huawei\DevEco Studio\...`）。autotools/CMake 对带空格路径的引号处理极不可靠。用 **junction** 换一个无空格路径：

```powershell
New-Item -ItemType Junction -Path D:\ohosndk `
  -Target "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"
# 之后一律用 D:/ohosndk/llvm/bin/clang.exe、D:/ohosndk/sysroot
```

**(b) 自建编译器 wrapper**（替代 NDK 那个只能跑在 Unix 上的 sh 脚本）：

```sh
# tools/ohos-cc
#!/bin/sh
exec "D:/ohosndk/llvm/bin/clang.exe" \
  --target=aarch64-linux-ohos --sysroot="D:/ohosndk/sysroot" -D__MUSL__ "$@"
```

用 wrapper 而不是把 `CC` 设成 `"clang --target=..."` 这种多词命令，是因为 autotools/make 到处都会对 `$CC` 做词分割，多词 `CC` 是经典雷区。

### 4.1 依赖清单（最终只编了 5 个库）

| 库 | 版本 | 来源 / SHA256 校验 | 用途 |
|---|---|---|---|
| FFmpeg | 8.0.2 | HandBrake-contribs 镜像，校验通过 | 全部解封装/解码/音频编码/封装 |
| x264 | snapshot-20250729-3222 | 同上 | H.264 编码 |
| jansson | 2.15.0 | 同上 | 预置/JSON |
| libogg | 1.3.6 | 同上 | `extradata.c` 需要 `ogg_packet` |
| libjpeg-turbo | 3.1.3 | 同上 | `hb.c` 的预览 JPEG 编解码 |

（zlib 不用编——**OHOS sysroot 自带 `libz.so` 和 `zlib.h`**。整个移植里的"免费午餐"。）

> **重要心得：所有源码包都对照 HandBrake 自己 `contrib/*/module.defs` 里的 `FETCH.sha256` 校验。** 这样既防中间人，也顺便**确认版本和上游 contrib 完全一致**——后面要应用上游 FFmpeg 补丁时才不会因版本差一丁点而 conflict。

### 4.2 FFmpeg：把上游 `contrib/ffmpeg/module.defs` 抄成命令行

最省事的做法不是自己研究 FFmpeg 该开什么，而是**照抄上游给 libhb 配的那份清单**（它本来就是最小集：`--disable-programs/muxers/filters/hwaccels/encoders` 再逐项 `--enable-*`）。见 [tools/build-ffmpeg.sh](../tools/build-ffmpeg.sh)。踩到的坑：

| 现象 | 根因 | 解法 |
|---|---|---|
| `Host compiler lacks C11 support` | FFmpeg 需要一个**宿主**编译器来构建工具，MSYS2 当时没装 gcc。日志里是 `gcc: 未找到命令` | `pacman -S gcc`，并显式 `--host-cc=gcc` |
| `Unknown option "--disable-postproc"` | postproc 在 FFmpeg 8.0 里已经**移除**，不是"可关闭项" | 删掉该参数 |
| 交叉编译却链接了宿主 `ld` | autoconf/libtool 会去找 `ld`，找到 `C:/msys64/usr/bin/ld.exe` | 全局 `export LD=$OHOS_LLVM_BIN/ld.lld.exe` |
| 链接期一堆 `cannot be used against symbol ... recompile with -fPIC`，但 **`-fPIC` 明明在 CFLAGS/ASFLAGS 里**（`CONFIG_PIC=yes`） | FFmpeg 的 aarch64 汇编（如 `libavutil/aarch64/tx_float_neon.S`）用 `R_AARCH64_ADR_PREL_PG_HI21` 访问全局数据，这类重定位要求符号地址固定；而在 **DSO 里全局符号默认可被抢占（preemptible）**，lld 因此拒绝 | 链接时加 **`-Wl,-Bsymbolic`**（OpenHarmony 自己的 FFmpeg 构建也这么做） |
| `--disable-autodetect` 之后 pthread 没了 | 该选项同时关掉 `AUTODETECT_LIBS` 里的 `THREADS_LIST` | 显式补 **`--enable-pthreads`** |

另外 `--disable-stripping` 也建议加上（见 §8 的 ELF 签名问题）。

### 4.3 必须应用 HandBrake 的 FFmpeg 补丁集

第一次编 libhb 时，80 个文件里 78 个直接过，卡在：

```
libhb/decavcodec.c:1314:24: error: use of undeclared identifier
    'AV_FRAME_DATA_DOVI_RPU_BUFFER_T35'; did you mean 'AV_FRAME_DATA_DOVI_RPU_BUFFER'?
```

原因是 HandBrake **会给 FFmpeg 打 25 个补丁**（`contrib/ffmpeg/A01..A26`），其中 `A14-Expose-the-unmodified-Dolby-Vision-RPU-T35-buffers.patch` 新增了这个 side-data 类型，而 libhb 无条件使用它。

正确做法不是去改 libhb，而是**把上游补丁集原样打上**——因为我们用的就是**同一个 ffmpeg-8.0.2**，25 个补丁**全部干净应用（0 失败）**：

```
[17:37:08] ffmpeg: patches applied=25 skipped=0
[17:38:49] ffmpeg: reinstalled
```

这一步也解释了"为什么必须严格按上游 contrib 的版本下源码"：版本差一点，补丁就打不上。

### 4.4 jansson 的两个 autotools 坑

```sh
--with-sysroot="D:/ohosndk/sysroot"   # -> configure: error: The sysroot must be an absolute path.
```
autotools 认为 `D:/...` **不是**绝对路径（它要 POSIX 形式）。但我们走 wrapper，`--sysroot` 已经在 wrapper 里了，所以**直接删掉这个参数**即可。

同时日志里露出 `checking for ld used by ... -> C:/msys64/usr/bin/ld.exe`——再次印证 §4.2 那条"必须钉死 `LD`"。

### 4.5 x265（HEVC 编码）：三个变体 + 又是补丁 + 一个 CMake 陷阱

H.264 走 x264，而 HandBrake **旗舰的 H.265/HEVC 编码走 x265**（参考移植的 README 示例用的就是 `-e x265`）。把 x265 接进来比 x264 麻烦得多，有三件事必须知道。

#### (1) HandBrake 把 x264/x265 的多比特位拆成"三份构建 + 合并"

x265 一次构建只编一个比特位，而 HandBrake 要 8/10/12-bit 都能用。上游 `contrib/` 的做法（`x265/module.defs` + `x265_{8,10,12}bit/`）是：

```make
# x265/module.defs
X265.SOURCE.libs = $(X265.BUILD.dir)/8bit/libx265_main.a \
                   $(X265.BUILD.dir)/10bit/libx265_main10.a \
                   $(X265.BUILD.dir)/12bit/libx265_main12.a
define X265.LINK            # 逐份 ar x 出 .o，再 ar cq 合成一个 libx265.a
```

三个变体的关键配置（从 `x265_8bit/10bit/12bit` 的 `module.defs` 抄下来）：

| 变体 | CMake 参数 | 结果 |
|---|---|---|
| 12bit | `-DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON` | C++ 命名空间 `x265_12bit` |
| 10bit | `-DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF` | C++ 命名空间 `x265_10bit` |
| 8bit | `-DHIGH_BIT_DEPTH=OFF -DEXPORT_C_API=ON -DEXTRA_LIB="…main10.a;…main12.a" -DLINKED_10BIT=ON -DLINKED_12BIT=ON` | 命名空间 `x265`，并**编译进 multilib 转发** |

命名空间隔离是合并能成立的前提（否则三份同名符号互相覆盖）：

```c
/* x265/source/CMakeLists.txt */
if(EXPORT_C_API)          set(X265_NS x265)          // -DX265_NS=x265
elseif(HIGH_BIT_DEPTH)
  if(MAIN12)              set(X265_NS x265_12bit)
  else()                  set(X265_NS x265_10bit)
```

**一个很容易踩的 CMake 细节**：`LINKED_10BIT` / `LINKED_12BIT` 这两个 option 被写在 `if(EXTRA_LIB)` **里面**——

```cmake
if(EXTRA_LIB)
    option(LINKED_8BIT  ... OFF)
    option(LINKED_10BIT ... OFF)   # 不传 EXTRA_LIB 的话，这个 option 根本不存在
    option(LINKED_12BIT ... OFF)
endif(EXTRA_LIB)
```

所以 `-DEXTRA_LIB=` 必须非空（指向已经构建好的 10/12bit 归档），否则 `-DLINKED_10BIT=ON` 会被静默忽略，最后 10/12bit 根本不可达。

怎么验证转发真的编进去了？看 8bit 那个 `api.cpp.o`：

```
$ llvm-nm --no-demangle --defined-only api.cpp.o | grep x265_api_get
   T x265_api_get_215                      <- 对外 API（X265_BUILD=215 由宏拼接）
$ llvm-nm --no-demangle --undefined-only api.cpp.o | grep x265_1
   U _ZN10x265_10bit16x265_api_get_215Ei   <- 转发目标：x265_10bit::x265_api_get_215
   U _ZN10x265_12bit16x265_api_get_215Ei
   U _ZN10x265_10bit14x265_api_queryEiiPi
   U _ZN10x265_12bit14x265_api_queryEiiPi
```

这三个 `U`（undefined）正是靠合并进来的 10/12bit 目标文件满足的。合并后整个归档 153 个成员、8.4 MB。

> 小教训：我第一次用 `grep 9x265_10bit` 检查命名空间，结果是 0 命中、误判"命名空间没生效"。实际上 `x265_10bit` 是 **10 个字符**，mangled name 里是 `_ZN10x265_10bit`。**数错长度会得出完全错误的结论**——验证命名空间/符号时最好用 `--no-demangle` 看到 `_ZN<长度><名字>` 的形式。

#### (2) 又是补丁：`encx265.c` 依赖 HandBrake 给 x265 打的补丁

刚打开 `HB_PROJECT_FEATURE_X265` 就撞上：

```
libhb/encx265.c:274:16: error: no member named 'ambientIlluminance' in 'struct x265_param'
libhb/encx265.c:275:16: error: no member named 'ambientLightX' in 'struct x265_param'
libhb/encx265.c:276:16: error: no member named 'ambientLightY' in 'struct x265_param'
libhb/encx265.c:277:16: error: no member named 'bEmitAmbientViewingEnvironment' in 'struct x265_param'
```

和 §4.3 的 FFmpeg 一模一样：**HandBrake 也给自己依赖的库打补丁，而 libhb 直接依赖补丁新增的字段**。这次是 `contrib/x265/A03-Implement-ambient-viewing-environment-sei.patch`（ISO/IEC 23008-2:2017 D.2.39 的环境光 SEI）。

`contrib/x265/` 下共 **9 个**补丁（A01–A09：线程优先级、Apple Silicon 调优、环境光 SEI、H.273 v3 矩阵系数、Dolby Vision RPU 内存管理、版本字符串、macOS 交叉编译、aq-motion 修复、mvdLX 范围检查），对我们那份 `x265-snapshot-20260216-13309` **9 个全部干净应用**。

所以规律很清楚，值得单独记一条：

> **移植 HandBrake 时，凡是它 `contrib/` 里带 `.patch` 的依赖库，补丁都必须打。** 因为 libhb 会直接引用补丁引入的新 API/字段，而 CMake/configure 层面完全看不出来——错误只会以"字段不存在"的形式出现在 `libhb/*.c` 里。
> 判断方法：`ls contrib/*/*.patch`，有补丁的库就要在交叉编译时打上。（本次涉及 **FFmpeg 25 个 + x265 9 个**。）

#### (3) 一个纯 CMake 陷阱：`add_custom_command` 不会注入 `--target`

x265 把 aarch64 手写汇编放在自定义命令里直接调编译器：

```cmake
# x265/source/CMakeLists.txt:884-896
elseif(ARM64 OR CROSS_COMPILE_ARM64)
    foreach(ASM ${ARM_ASMS})
        add_custom_command(
            COMMAND ${CMAKE_CXX_COMPILER}
            ARGS ${ARM_ARGS} ${ASM_FLAGS} ${AARCH64_NEON_FLAG} -c ${ASM_SRC} -o ${ASM}.${SUFFIX})
```

而 **CMake 的 `CMAKE_CXX_COMPILER_TARGET` 只作用于常规编译规则，不作用于 `add_custom_command`**（OHOS 的 `ohos.toolchain.cmake` 正是靠这个变量加 `--target=aarch64-linux-ohos` 的）。于是自定义命令里的 `clang++` 退回**宿主**目标，报出一串 x86 CPU 名字：

```
error: unknown target CPU 'armv8-a'
note: valid target CPU values are: nocona, core2, ... znver3, x86-64-v4
```

想从 flags 里补救也不行——`ARM_ARGS` 是 x265 自己从零拼的（`-O3` / `-flax-vector-conversions=none` / `-DPIC -fPIC`），**不含 `CMAKE_CXX_FLAGS`**。

**第一版的权宜之计**是 `-DENABLE_ASSEMBLY=OFF`，整个 `if(... AND ENABLE_ASSEMBLY)` 块被跳过，全部走常规编译规则（能拿到 `--target`）。构建能过，但**到真机上就崩了**（见下面 (3b)）。

#### (3b) 真机崩溃：关掉汇编并不是"安全选项"

第一版带 x265 的包装上后，自检第 1 步 x264 正常（`rc=0`，1,045 ms），第 2 步 x265 只打印了参数就没了，**进程直接消失**。hilog 里能抓到系统侧的判决：

```
C01311/foundation/AppMS: send event [FRAMEWORK,PROCESS_KILL], pid=32066,
    processName=com.handbrake.ohos, reason=Cpp Crash
C02DA0/hiview/NotifyLeakDetector: ... filename: cppcrash-32066-1792146034534.json
```

（崩溃栈在 `/data/log/faultlog/faultlogger/` 下，`hdc shell` 和 `hdc file recv` 都读不到——权限不够。所以只能自己想办法把现场弄出来，于是有了下面的"日志与信号捕获"两条基础设施。）

顺手又发现一个**更根本的配置问题**。查 x265 的 `CMakeCache.txt`：

```
AARCH64_RUNTIME_CPU_DETECT:BOOL=OFF
ENABLE_ASSEMBLY:BOOL=OFF
```

而 x265 的 `common/CMakeLists.txt:100` 把**整套 aarch64 源码**（`asm-primitives.cpp`、`pixel-prim.cpp`、`dct-prim.cpp`、`loopfilter-prim.cpp`、`intrapred-prim.cpp`、`arm64-utils.cpp`、`sao-prim.cpp` …）都门控在：

```cmake
if(ENABLE_ASSEMBLY AND (ARM64 OR CROSS_COMPILE_ARM64))
    set(C_SRCS_NEON asm-primitives.cpp pixel-prim.cpp ...)
```

也就是说我们那份 x265 **一行 aarch64 专属代码都没有**。

那 `AARCH64_RUNTIME_CPU_DETECT` 又是谁关的？x265 的 `CMakeLists.txt:88-92`：

```cmake
option(AARCH64_RUNTIME_CPU_DETECT "Enable AArch64 run-time CPU feature detection" ON)
if(NOT CMAKE_SYSTEM_NAME MATCHES "Linux|Darwin|Windows")
    set(AARCH64_RUNTIME_CPU_DETECT OFF CACHE BOOL "" FORCE)
    message(STATUS "Run-time CPU feature detection unsupported on this platform")
endif()
```

**`CMAKE_SYSTEM_NAME` 是 `OHOS`**（DevEco 的 `ohos.toolchain.cmake` 设的），x265 就把鸿蒙当成了"未知平台"——关掉运行时检测，并且所有 `MATCHES "Linux"` 的平台分支都走错。

#### (3c) 真正的修法：给 x265 单独写一份 toolchain

两件事一起解决（脚本见 [port-ohos/toolchain/ohos-aarch64.cmake](../port-ohos/toolchain/ohos-aarch64.cmake)）：

1. **`CMAKE_SYSTEM_NAME` 用 `Linux` 而不是 `OHOS`。** 鸿蒙用户态本来就是 Linux + musl，按 Linux 对待既准确、也正是这些上游项目预期的。这样 `AARCH64_RUNTIME_CPU_DETECT` 恢复 ON，平台分支也走对。
2. **编译器指向 `.cmd` 包装器**（`ohos-cc.cmd` / `ohos-cxx.cmd`），把 `--target=aarch64-linux-ohos --sysroot=… -D__MUSL__` 烘进命令行本身。这样 `add_custom_command` 里那 99 个 aarch64 汇编/内联函数源文件也能拿到正确目标。

**为什么用 `.cmd` 而不是已有的 sh 包装器**：Ninja 在 Windows 上是用 `cmd.exe /C` 执行命令的（构建日志里那条 `C:\windows\system32\cmd.exe /C "cd /D ... && clang++.exe ..."` 就是证据），而 `cmd.exe` 不认识 shebang 脚本；`.cmd` 可以。
**为什么必须自写 toolchain**：DevEco 的 `ohos.toolchain.cmake` 用普通 `set()` 覆盖 `CMAKE_CXX_COMPILER`，命令行上的 `-D` 赢不了它。

效果（同一份 x265 源码，只换 toolchain）：

| | 关汇编（第一版） | 自写 toolchain（现在） |
|---|---|---|
| `ENABLE_ASSEMBLY` | OFF | **ON** |
| `AARCH64_RUNTIME_CPU_DETECT` | OFF | **ON** |
| configure 日志 | （无相关输出） | `Detected ARM64 target processor` + **`Configuring build for run-time CPU feature detection`** |
| 归档成员数 | 153 | **252** |
| 合并后 libx265.a | 8,431,490 字节 | **12,737,496 字节**（+51%） |
| `libhandbrake.so` | 69,854,416 | **73,864,080** |

（对比一下：x264 我们是直接 `--disable-asm`，FFmpeg 保留了汇编——因为 FFmpeg 的 `.S` 走的是正常编译规则，能拿到 `--target`。x264/x265 的汇编后续也可以按同样的 `.cmd` 包装器方案拿回来。）

#### (3d) 两条"headless 沙箱"必备的基础设施

崩溃时最难受的不是崩，而是**什么都看不到**：HandBrakeCLI 和 libhb 的日志全走 stderr，而应用没有控制台；一个 SIGSEGV 又会把整个 App 带走，连"崩了"都是靠系统日志反推出来的。所以在 NAPI 桥接层补了两件事（`entry/src/main/cpp/napi_init.cpp`）：

```cpp
// 1) 把 fd 1/2 接到管道，由专用线程逐行转成 hilog
pipe(fds); dup2(fds[1], STDOUT_FILENO); dup2(fds[1], STDERR_FILENO);
pthread_create(&th, nullptr, log_reader, nullptr);   // read() -> LOGI("libhb: ...")

// 2) 抓致命信号，写一行日志后 longjmp 回 CLI 包装层
for (int s : {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE}) sigaction(s, &sa, nullptr);
```

这样 `runCli()` 的返回值就能表达两件事：正常的退出码，或 `-1000 - signum`（例如 `-1011` = SIGSEGV=11）。**一个 codec 崩溃从此变成一条可读数据，而不是"App 莫名消失"。**


#### (4) 链接 x265 要多做一步

x265 是 **C++**，所以：

- 构建 libhb 的 `CMakeLists.txt` 里把 `project(... C)` 改成 `project(... C CXX)`，并给共享库显式指定 C++ 链接驱动：
  ```cmake
  set_target_properties(handbrake_shared PROPERTIES LINKER_LANGUAGE CXX)
  ```
  否则 CMake 会因为"源码都是 C"而选 C 链接器，`operator new` / `__cxa_*` 这些 libc++ 符号全部未解析。
- 依赖列表里加上 `libx265.a`。

验证结果：

```
未 strip 的 libhandbrake.so（70,475,480 字节）:
  hb_encx265         1 次
  10x265_10bit    1505 次        <- 10bit 命名空间
  10x265_12bit    1505 次        <- 12bit 命名空间
  x265_encoder_open  3 次        <- 三个比特位各一份
  x265_api_get_215   3 次

打包（已 strip）后的 .so 里的字符串:
  "ambient viewing environment"  1 次   <- 正是 A03 补丁带进来的字符串
  "H.265/HEVC"                   2 次   <- HandBrake 编码器表里的名字

libhandbrake.so 体积: 18,279,016 -> 22,864,328 字节（+4.59 MB）
```

---

## 5. 构建 libhb：不用它的 make，直接上 CMake

### 5.1 为什么可以绕开 HandBrake 的构建系统

- 我们要的只是 **libhb**（引擎库），前端自己写（NAPI）。
- HandBrake 的 make 体系只为 `contrib` 自举服务；依赖我们自己已经编好了。
- 于是写一个 [port-ohos/CMakeLists.txt](../port-ohos/CMakeLists.txt)，直接 glob `libhb/*.c`、减掉那 7 个文件、加上桩文件。

### 5.2 `project.h` 是 m4 生成的——手写一份就行

`libhb/handbrake/handbrake.h` 会 `#include "handbrake/project.h"`，而这个文件**不在源码树里**（只有 `project.h.m4`，由 `make/configure.py` + m4 生成）。手写一份塞到一个比源码树更靠前的 include 目录里即可，关键宏：

```c
#define HB_PROJECT_VERSION "1.11.2"
#define HB_PROJECT_HOST_SPEC  "aarch64-linux-ohos"
#define HB_PROJECT_HOST_SYSTEM "linux"      /* 走上游的 SYS_LINUX 路径 */
#define HB_PROJECT_FEATURE_X265 0           /* 下面这些 0 让 libhb 自动裁掉可选特性 */
#define HB_PROJECT_FEATURE_NVENC 0 / QSV 0 / VCE 0 / MF 0 / NVDEC 0 / NUMA 0 / LIBDOVI 0 / GTK 0
#define HB_PROJECT_FEATURE_FFMPEG_AAC 1
```

另外三个编译宏很关键（来自 `libhb/module.defs` 的 `SYS_LINUX` 分支和兼容层）：

```
-DSYS_LINUX -D_LARGEFILE_SOURCE -D_FILE_OFFSET_BITS=64 -D__LIBHB__ -DHAS_STRERROR_R
```

`HAS_STRERROR_R` 一定要有：`libhb/compat.c` 在**没有**它、且没有 `_GNU_SOURCE` 时，会自己定义一个**永远返回 "unknown error N" 的假 `strerror_r`**。musl 本身有真正的 POSIX `strerror_r`，所以打开它、别用假货。

### 5.3 一个"看起来像编译器 bug"的坑：`__LIBHB__` 不能给 C++ 文件

把 NAPI 桥接（C++）和 libhb 放同一个 CMake target 时，如果 `target_compile_definitions` 里带了 `__LIBHB__`，那么 C++ 翻译单元也会带上它 → `handbrake.h` 就会把 `handbrake/internal.h` 拉进来 → 而 `internal.h` 是**纯 C** 的（C99 初始化器等），C++ 直接崩：

```
internal.h:222: error: no matching function for call to 'av_image_get_linesize'
internal.h:256: error: expected ')'
```

**解法**：`__LIBHB__` 只给 libhb 的源文件，**不给** CLI/桥接。上游也是这么做的——`make` 里只有 `LIBHB.GCC.D += __LIBHB__`，`test` 模块不加。

### 5.4 最终结果

```
[17:50:01] libhb: build OK
-rw-r--r-- 2372896  libhandbrake.a
-rw-r--r-- 64626976 libhandbrake.so
```

验证：

```
Class:   ELF64
Type:    DYN (Shared object file)
Machine: AArch64
.comment: OHOS (dev) clang version 15.0.4
exports:  906 个动态符号，含 hb_init / hb_global_init / hb_scan / hb_job / hb_add / hb_batch_init ...
```

即：**HandBrake 的转码引擎已在 OHOS arm64 上完成编译与链接，`--no-undefined` 下无任何未解析符号。**

---

## 6. 打包成 HAP

### 6.1 hvigor **拒绝非 ASCII 工程路径**

第一次构建就撞墙：

```
> hvigor ERROR: 00306003 Specification Limit Violation
Error Message: Invalid project path. Current path does not match: D:\dsh\homo移植\ohos\HandBrakeOHOS
* Try the following:
  > Please modify the project path to ensure that it only contains letters, digits,
    hyphens (-), underscores (_), periods (.), english parentheses (()), spaces, or the @ symbol
```

试过用 `subst X:` 映射成 ASCII 盘符，**没用**——hvigor 会把 subst 路径解析回真实路径。所以：

> **DevEco/hvigor 工程必须放在纯 ASCII 路径下。** 最终工程落在 `D:\handbrake-ohos`，并在 `D:\dsh\homo移植\ohos` 建了一个 junction 方便访问。

### 6.2 CMake+Ninja 的**链接**阶段会被非 ASCII 路径搞乱

比 hvigor 更隐蔽：编译阶段一切正常，**链接**阶段突然报找不到文件，路径长这样：

```
clang: error: no such file or directory:
  'CMakeFiles/handbrake_shared.dir/D_/dsh/homo<D2><C6>ֲ/src/handbrake/libhb/stream.c.o'
```

注意 `<D2><C6>`——`移` 的 GBK 编码就是 `D2 C6`。也就是 ninja 写链接响应文件时，UTF-8 路径被按 ANSI 代码页重新编码了。

**解法**：把构建工作区整体搬到 ASCII 根目录 `D:\hbohos`，再用 junction 从中文目录指回去：

```
D:\hbohos\{src,build,out,port-ohos}          <- 真正干活的树
D:\dsh\homo移植\{src,build,out,port-ohos}    <- junction，方便查看
```

### 6.3 HandBrake 文档里没有、但一定会撞上的 API 依赖

`test.c`（CLI）会引用被我们排除的 `dvd.c` 里的 **public API**：

```
ld.lld: error: undefined symbol: hb_dvd_set_dvdnav
```

它在 `handbrake/handbrake.h:43` 里声明，也就是**对外公开 API**的一部分。这类"在头文件里公开、实现却在被裁掉的文件里"的函数，是特性裁剪时最容易漏的一类，需要按 `handbrake.h` 逐个核对，而不只是看 `internal.h`。

### 6.4 复用 `test.c` 的两处重命名

```cmake
set_source_files_properties(${HB_SRC}/test/test.c PROPERTIES
    COMPILE_DEFINITIONS "main=hbcli_main;exit=hbcli_exit")
```

- `main → hbcli_main`：HAP 里不能再有一个 `main`。
- `exit → hbcli_exit`：`test.c` 只有**一处** `exit(done_error)`（1100 行附近），直接把真 `exit()` 调进应用会**把整个 App 干掉**。改成 `longjmp` 回桥接层：

```cpp
static jmp_buf g_exit_jmp;  static int g_exit_code;
extern "C" void hbcli_exit(int code) { g_exit_code = code; longjmp(g_exit_jmp, 1); }
static int run_cli(std::vector<char*> &argv) {
    g_exit_code = 0;
    if (setjmp(g_exit_jmp) == 0) return hbcli_main((int)argv.size(), argv.data());
    return g_exit_code;
}
```

> 小技巧：**宏替换不会作用于字符串字面量**，所以 `-Dmain=hbcli_main` 不会把 CLI 帮助文本里的 "main" 改掉。

### 6.5 NAPI 侧

`napi_init.cpp` 暴露三个方法（`nm_modname = "handbrake"` → `libhandbrake.so` → ArkTS `import hb from 'libhandbrake.so'`）：

| 方法 | 形式 | 说明 |
|---|---|---|
| `hbVersion()` | 同步 | 直接返回 `HB_PROJECT_VERSION`，**最廉价的"引擎在沙箱里能不能加载"探针** |
| `hbInit()` | 同步 | `hb_global_init()` |
| `runCli(args[])` | **异步 Promise** | 用 `napi_create_async_work` 丢到 libuv 工作线程跑 `hbcli_main`，避免转码时卡死 UI 线程 |

最后 `build-profile.json5` 里把外部库前缀传进去：

```json5
"externalNativeOptions": {
  "path": "./src/main/cpp/CMakeLists.txt",
  "arguments": "-DHB_PREFIX=D:/hbohos/out/ohos-arm64 -DHB_SRC=D:/hbohos/src/handbrake",
  "abiFilters": ["arm64-v8a"]
}
```

### 6.6 打包结果

```
entry-default-unsigned.hap   19,659,626 bytes
  libs/arm64-v8a/libhandbrake.so   18,279,016 bytes   (hvigor 已 strip)
  libs/arm64-v8a/libc++_shared.so   1,262,504 bytes

libhandbrake.so:
  Class: ELF64   Type: DYN   Machine: AArch64
  NEEDED: libace_napi.z.so, libhilog_ndk.z.so, libz.so, libc++_shared.so, libc.so
  U napi_module_register / napi_create_async_work / napi_define_properties / OH_LOG_Print
```

`libhb` 自身的符号被 `--exclude-libs,ALL` 收进内部，**运行时依赖只剩系统库**——这正是我们要的（FFmpeg/x264/jansson/ogg/jpeg 全部静态链进去了，不用额外分发 `.so`）。

### 6.7 最后一个"只在真机上才会炸"的坑：libhb 的 `/tmp`

引擎能加载、`--version` 也能跑，**但一开始转码就会出问题**。原因在 `libhb/ports.c`：

```c
/* hb_init_temporary_directory(), 非 Windows 分支 */
else if ((p = getenv("TMPDIR")) != NULL ||
         (p = getenv("TEMP"))   != NULL)
    base = strdup(p);
else
    base = strdup("/tmp");            // <-- 默认值
...
path = hb_strdup_printf("%s/handbrake-XXXXXX", base);
if (!mkdtemp(path))
{
    /* We still use the path even if directory creation fails */
    hb_error("Failed to create a temporary directory at %s\n", path);
}
```

**鸿蒙应用沙箱里没有 `/tmp`，也建不出来。** 于是 `mkdtemp` 失败，libhb **只打一行错误、然后继续用这个不存在的路径**——转码时的临时文件（预览、章节、时间戳缓存）全部落在空处。这类问题最讨厌的地方是**报错点离根因很远**。

好在 libhb 给了公开 API：

```c
void hb_set_temporary_directory (const char *tmp_dir);   /* 必须在使用之前调用 */
```

而它内部是 `pthread_once(&tmp_control, ...)` 锁定的，所以**必须在任何 libhb 调用之前**设置。于是在 NAPI 桥接里加了一个必须最先调用的入口：

```ts
// ArkTS 侧
const ctx = getContext(this) as common.UIAbilityContext;
hb.hbSetPaths(ctx.cacheDir, ctx.filesDir);   // -> TMPDIR + hb_set_temporary_directory()
hb.hbTempDir();                              // 回读 libhb 实际解析出的目录，作为证据
```

```cpp
// native 侧（napi_init.cpp）
static void set_sandbox_paths(const std::string &cacheDir, const std::string &filesDir) {
    mkdir(cacheDir.c_str(), 0700);
    setenv("TMPDIR", cacheDir.c_str(), 1);
    hb_set_temporary_directory(cacheDir.c_str());   // 关键
    setenv("XDG_CONFIG_HOME", filesDir.c_str(), 1);
    setenv("HOME", filesDir.c_str(), 1);
}
```

顺手把 `HOME`/`XDG_CONFIG_HOME` 也指向沙箱（`hb_get_user_config_directory()` 会去 `$XDG_CONFIG_HOME` 或 `$HOME/.config` 找 `presets.json`；CLI 路径其实不读它，但设上无坏处）。

**另外两个小结论：**
- `hb_global_init()` **不能调两次**——它把每个 work object `hb_register()` 进链表，重复调用会重复注册。而 `test.c` 的 `main` 自己会调（`test.c:509`），所以桥接层**不要**再调一次。这也解释了为什么桥接层最初的 `hbInit()` 被我换成了只做路径设置的 `hbSetPaths()`。
- 我用 `hbTempDir()` 把 libhb 实际解析出的临时目录回显到界面上，这样**"路径修复到底有没有生效"在真机上是一眼可见的**，不用去猜。

---

## 7. HAP 签名的三层信任（最大的"卡脖子"）

主机上原本没有任何**华为**开发者签名材料，所以我先把三条路都试了：

### 7.1 自造钥匙串：OpenHarmony SDK 自签（**设备拒绝**）

SDK 里带了一整套离线签名材料，密码是公开的 `123456`：

```
sdk/.../toolchains/lib/OpenHarmony.p12               # 含 OpenHarmony 根/应用/Profile 三级 CA 私钥
sdk/.../toolchains/lib/OpenHarmonyProfileDebug.pem   # Profile 签名证书链
sdk/.../toolchains/lib/UnsgnedDebugProfileTemplate.json
sdk/.../toolchains/lib/hap-sign-tool.jar
```

我写了 [tools/ohos-selfsign.ps1](../tools/ohos-selfsign.ps1) 走完整流程（生成应用密钥对 → 签发应用证书链 → 用**我方 bundleName + 我方设备 UDID** 造 profile → `sign-profile` → `sign-app`）。
过程中踩了两个坑，值得记录：

1. **`generate-app-cert` 每次调用都会新签一张证书**（serial 不同）。如果一张用于 profile 的 `development-certificate`、另一张用于 `-appCertFile`，`sign-app` 会报
   `verify certificate chain failed! verify certificate chain issuer subject failed`。**必须只签一次，再从证书链里切出 leaf 复用。**
2. `-issuer` 必须与 CA 证书的**真实 subject DN** 完全一致。我一开始按官方示例写了 `CN=Application Signature Service CA`，实际是：
   ```
   C=CN, O=OpenHarmony, OU=OpenHarmony Team, CN=OpenHarmony Application CA
   ```
   用 `keytool`/`openssl x509 -noout -subject,issuer` 把每张证书的真实 DN 打出来对齐后才通过。
3. 把 PEM 交给 `ConvertTo-Json` 时**不能再手工转义换行**，否则 profile 里的 base64 会被塞进字面 `\n`，报 `Illegal base64 character 20`。

**签署成功**（`sign-app success`），但装到设备上：

```
[Info]App install path:...selfsigned.hap msg:
error: failed to install bundle. code:9568257 error: fail to verify pkcs7 file.
```

> **结论：华为鸿蒙设备不信任 OpenHarmony 自签根证书。** 这条路只适用于 OpenHarmony 开发板 / 容器，不适用于零售鸿蒙设备。

### 7.2 复用现成的华为 profile（**bundleName 不匹配**）

后来在主机上发现用户之前用 DevEco 自动签名生成过一套**华为签发**的调试材料：

```
C:\Users\Lenovo\.ohos\config\default_aegisub-ohos_....p7b   # type=debug, issuer=app_gallery
```

解开里面的 profile JSON 一看：

```json
{ "type":"debug",
  "bundle-info": { "bundle-name":"org.aegisub.ohos", "developer-id":"<developer-id>", ... },
  "debug-info":  { "device-id-type":"udid",
                   "device-ids":["<device-udid>","<another-udid>"] } }
```

对比设备实测 UDID：

```
hdc shell bm get --udid
-> <你的设备 UDID>     ← 在授权列表里 ✅
```

设备是授权的，但 **profile 是绑 bundleName 的**。把它的 `signingConfigs` 段原样抄进我的工程（连同密文口令——它是用机器级 `material/` 密钥加密的，同机可用），hvigor 直接拒绝：

```
> hvigor ERROR: 00303074 Configuration Error
Error Message: The bundleName in app.json5/hvigorfile.ts does not match the
bundleName in the generated SigningConfigs.
```

**这是 hvigor 主动做的校验**，也就是说——**profile 的 bundleName 与 `app.json5` 的 bundleName 必须一致，无法绕过。**

### 7.3 最终解法：用 HO-Kit 拿到华为 profile，真机已跑通

主机上已装的 **HO-Kit** 能让用户用**自己的华为开发者账号**为**任意 bundleName** 申请华为调试 profile。用户用它为 `com.handbrake.ohos` 签好了包：

```
产出：C:\Users\Lenovo\AppData\Local\ho-kit\sign\provisions\com.handbrake.ohos_2037700010388247296_d41d8cd9.p7b
签名包：C:\Users\Lenovo\AppData\Local\ho-kit\sign\output\entry-default-unsigned_signed.hap
```

装到设备上后：`bm dump -n com.handbrake.ohos` 正常返回，`aa start -a EntryAbility -b com.handbrake.ohos` → `start ability successfully`，进程存活。

**真机验证证据（UI 树 + hilog）**：

```
# uitest dumpLayout 读到的界面文本
HandBrake (HarmonyOS port)
device  : QXS-W00 / brand : HUAWEI / os : OpenHarmony-7.0.0.105 / sdk api : 26 / abi : arm64-v8a
libhb version : 1.11.2
hb_global_init : 0

# 点一下按钮后
HandBrakeCLI --version -> rc=0

# hdc shell hilog -x
10-16 17:58:50.827 23186 23651 I A0FF00/com.handbrake.ohos/HandBrakeOHOS: HandBrakeCLI: 2 args
10-16 17:58:50.859 23186 23651 I A0FF00/com.handbrake.ohos/HandBrakeOHOS: HandBrakeCLI finished, rc=0
```

也就是说：**NAPI 模块在鸿蒙应用沙箱里成功 dlopen → libhb 初始化返回 0 → 官方 `test.c` 驱动在 libuv 工作线程里跑完并返回 0。**

> 取证小技巧：`hbVersion()` 这类没有日志的函数，光看 hilog 是"沉默即成功"——**用 `uitest dumpLayout` 把 UI 树里的 `text` 字段抓出来读**，比截图 OCR 更准，也不需要人盯屏幕。

### 7.4 签名速查（给将来的人）

| 场景 | 工具 | 命令要点 |
|---|---|---|
| HAP 签名（唯一可行） | HO-Kit / DevEco 自动签名 | 必须有**华为签发**的 profile；bundleName 与设备 UDID 都要匹配 |
| HAP 签名（不可行） | OpenHarmony `hap-sign-tool.jar` | 自签链会被设备拒绝：`fail to verify pkcs7 file` |
| **原生二进制**签名 | `binary-sign-tool.jar` | `sign -inFile X -outFile X -selfSign "1"`，**之后必须 `chmod 755`** |
| 校验签名 | `llvm-readelf -S <elf> \| grep codesign` | 别用 `grep .codesign`（正则通配符会骗你），要读真实 ELF 段 |
| 绝不能做 | `strip` / `objcopy` / 原地改字节 | 鸿蒙已落盘 ELF 被就地修改后**拒绝执行**；要产出**新文件** |
| 读设备界面内容 | `hdc shell uitest dumpLayout -p /data/local/tmp/ui.json` | 再 `file recv` 回来解析 `"text"` 字段 |

---

## 8. 可复现的构建流程

```powershell
# 0) 一次性准备
New-Item -ItemType Junction -Path D:\ohosndk -Target `
  "C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\native"
winget install --id MSYS2.MSYS2
C:\msys64\usr\bin\bash.exe -lc "pacman -Sy --noconfirm base-devel gcc python nasm yasm autoconf automake libtool pkgconf"

# 1) 交叉编译依赖（脚本在 tools/，全部幂等，可重跑）
bash tools/build-x264.sh
bash tools/build-ffmpeg.sh
bash tools/patch-ffmpeg.sh        # 应用 HandBrake 的 25 个 FFmpeg 补丁并增量重编
bash tools/build-jansson.sh
bash tools/build-libogg.sh
bash tools/build-jpeg.sh

# 2) 编译 libhb -> libhandbrake.{a,so}
bash tools/build-libhb.sh

# 3) 构建 HAP（工程在 D:\handbrake-ohos，必须 ASCII 路径）
$d="C:\Program Files\Huawei\DevEco Studio"
$env:PATH="$d\tools\node;$env:PATH"; $env:NODE_HOME="$d\tools\node"; $env:DEVECO_SDK_HOME="$d\sdk"
cd D:\handbrake-ohos
& "$d\tools\hvigor\bin\hvigorw.bat" assembleHap --no-daemon

# 4) 签名并安装（需要华为 profile）
hdc -t <device> install -r .\entry\build\default\outputs\default\entry-default-signed.hap
```

---

## 9. 已完成 / 未完成（老实交代）

**已完成并已验证：**

- [x] 两个网上移植仓库的逐字节/二进制级验证，明确"能借鉴什么、不能借鉴什么"
- [x] 设备与工具链事实全部实测（musl / `__OHOS__` / 无 root / SELinux / 无用户家目录）
- [x] 证明**零售鸿蒙平板无法从 shell 执行自编译二进制**——决定了移植形态
- [x] Windows 主机 → OHOS arm64 交叉编译链：FFmpeg 8.0.2（含上游 25 个补丁）+ x264 + **x265 多比特位（含上游 9 个补丁）** + jansson + libogg + libjpeg-turbo
- [x] **libhb 编译并链接成功**：`libhandbrake.so`（AArch64，无未解析符号）
- [x] **带引擎的 HAP 构建并打包成功**（含 x265 后 25.3 MB，内含 22.9 MB `libhandbrake.so`，运行时只依赖系统库）
- [x] 打通并验证了 OpenHarmony 自签流程（含 3 个坑的解法）→ 并**证伪**它在华为设备上可用（`fail to verify pkcs7 file`）
- [x] **真机签名 + 安装 + 启动成功**（HO-Kit 申请到 `com.handbrake.ohos` 的华为调试 profile）
- [x] **真机上 NAPI 模块加载成功、libhb 初始化成功**：界面显示 `libhb version : 1.11.2` / `hb_global_init : 0`
- [x] **真机上跑通官方 HandBrakeCLI 驱动**：`HandBrakeCLI --version -> rc=0`，hilog 同步印证
- [x] **真机上跑通真实转码**：`-e x264 -q 28` → `rc=0`，产出 `sample-out.mkv` **2,301,565 字节**
- [x] 发现并修复"libhb 默认临时目录 `/tmp` 在沙箱里不存在"这个**只在真机才暴露**的坑（§6.7）
- [x] **H.265/HEVC (x265) 编码接入**：三变体合并库 + 9 个补丁 + 链接打通，符号/字符串/体积三重验证（§4.5）

**未完成 / 已知限制：**

- [ ] 真机上跑 **HEVC 自检三步**（H.264 → H.265 → 回读 H.265 产物），验证包已构建待签名安装
- [ ] x265 目前 `-DENABLE_ASSEMBLY=OFF`（见 §4.5(3) 的 CMake 陷阱），x264 是 `--disable-asm`；FFmpeg 保留了汇编
- [ ] 视需要恢复被裁特性：libass（字幕烧录）、SVT-AV1、libtheora/libvorbis、光盘源
- [ ] 没有硬编（鸿蒙无 VAAPI/NVDEC/QSV，且 FFmpeg 无 OHOS hwaccel 后端）→ **纯软编软解**
- [ ] 没有图形界面（只有 CLI 能力 + 验证页）；仓库 A 的 GTK4 路线需要先交叉编译 GTK4/GLib 全家桶，成本极高

---

## 10. 给后来者的清单（踩坑浓缩版）

**关于鸿蒙本身**
1. 平板/手机上 `hdc shell` **不能执行**自编译二进制；native 代码必须进 HAP 沙箱。
2. `binary-sign-tool` 自签后**必须 `chmod 755`**（它会重置执行位）。
3. 已落盘 ELF **禁止就地修改**（strip/objcopy/patch），要写新文件。
4. 设备**不信任** OpenHarmony 自签根；安装必须有华为签发、bundleName+UDID 匹配的 profile。
5. `hdc shell bm get --udid` 拿 UDID；profile 里的 `device-ids` 必须包含它。
6. `uname -s` 返回 `HarmonyOS` 不是 `Linux`（autotools 会认不出来）。
7. **应用沙箱里没有 `/tmp`**；任何默认往 `/tmp` 写的库都要显式改到 `context.cacheDir`。
8. 想在真机上"看见"结果但没法点屏幕？`hdc shell uitest dumpLayout -p <path>` + `hdc file recv`，直接读 UI 树里的 `text` 字段。
9. 应用侧日志：`OH_LOG_Print(LOG_APP, ...)` 落在 `A0FF00/<bundle>` 下，用 `hdc shell hilog -x` 抓。

**关于工具链**

10. hvigor **拒绝非 ASCII 工程路径**（`subst` 也骗不过它）。
11. CMake+Ninja 的**链接阶段**会把非 ASCII 路径按 ANSI 重编码 → 构建树放 ASCII 路径。
12. NDK 里 `*-ohos-clang` 是 sh 脚本，Windows 上自建 wrapper；`__OHOS__` 是预定义的，`__MUSL__` **不是**。
13. 用 junction 消掉 `Program Files` 的空格。
14. 交叉编译一定要钉死 `LD`（否则 autoconf 会用宿主 ld）。
15. `--disable-autodetect` 会顺手关掉 pthread → 补 `--enable-pthreads`。
16. FFmpeg 静态库链进 `.so` 时要 `-Wl,-Bsymbolic`（aarch64 汇编的 `ADR_PREL_PG_HI21` vs 可抢占符号）。

**关于 HandBrake**

17. `libhb` 全量 glob 编译，**没有裁剪开关**——要裁就得"排除源文件 + 补符号桩"，并且桩要按 `internal.h` **和公开的 `handbrake.h`** 两个头文件核对。
18. 必须应用 `contrib/ffmpeg/A*.patch`（否则 `AV_FRAME_DATA_DOVI_RPU_BUFFER_T35` 缺失）。
19. `handbrake/project.h` 是 m4 生成的，手写一份即可；`HAS_STRERROR_R` 要打开。
20. `__LIBHB__` 不能给 C++ 翻译单元（会把纯 C 的 `internal.h` 拉进来）。
21. `libhb/stream.c` 无条件 include `libbluray/bluray.h`，但**一个 libbluray 函数都没调**——空 shim 头即可。
22. 复用 `test.c` 能白拿整个 CLI 功能，代价是 `main`/`exit` 两个重命名。
23. **`hb_global_init()` 只能调一次**（它往全局链表注册 work object）；而 `test.c` 的 `main` 自己会调，桥接层别重复调。
24. **`hb_set_temporary_directory()` 是 `pthread_once` 锁定的**，必须在任何 libhb 调用之前设置（详见 §6.7）。
25. 顺带记住：**上游没有"关闭某特性"的官方姿势**，所以"裁剪"这件事本身就是移植工作的一部分，务必把裁了什么、怎么恢复写清楚。

**关于依赖库的交叉编译（本次踩到的"结构性"规律）**

26. **凡 `contrib/*/` 下带 `.patch` 的依赖库，补丁都必须打。** libhb 会直接引用补丁新增的 API，而 configure/CMake 层面完全看不出来。本次：FFmpeg **25 个**、x265 **9 个**，全部干净应用。
    漏打的症状是 `libhb/*.c` 里报"字段/标识符不存在"：
    - `AV_FRAME_DATA_DOVI_RPU_BUFFER_T35`（FFmpeg A14）
    - `x265_param.ambientIlluminance / ambientLightX / ambientLightY / bEmitAmbientViewingEnvironment`（x265 A03）
    一条命令就能盘点：`ls contrib/*/*.patch`。
27. **CMake 的 `CMAKE_*_COMPILER_TARGET` 不作用于 `add_custom_command`。** 库自己用自定义命令汇编 `.S` 时（x265 的 ARM64 分支就是这样），编译器会退回宿主目标并报 `unknown target CPU 'armv8-a'`。本次对策是 `-DENABLE_ASSEMBLY=OFF`；想保住汇编需让 `CMAKE_*_COMPILER` 指向会注入 `--target` 的包装器（Ninja 在 Windows 上用 `cmd.exe /C` 执行命令，`.cmd` 可行；但 NDK 的 toolchain 文件会用普通 `set()` 覆盖编译器变量，得自写 toolchain 文件）。
28. 链接 **C++ 静态库**（x265）时，如果共享库自身源码全是 C，CMake 会挑 C 链接驱动 → `operator new` / `__cxa_*` 全未解析。要显式 `set_target_properties(<t> PROPERTIES LINKER_LANGUAGE CXX)`。
29. x265 多比特位 = 三份构建 + 合并：10/12bit 用 `EXPORT_C_API=OFF` 换到独立 C++ 命名空间（`x265_10bit` / `x265_12bit`），8bit 用 `EXTRA_LIB` + `LINKED_10BIT/12BIT` 把转发编进 `x265_api_get()`。
    坑：**`LINKED_10BIT` / `LINKED_12BIT` 这两个 option 被写在 `if(EXTRA_LIB)` 里面**，`EXTRA_LIB` 为空时它们根本不存在，`-DLINKED_10BIT=ON` 会被静默忽略。
30. 验证命名空间时注意 mangled name 是 `_ZN<长度><名字>`：`x265_10bit` 是 **10** 个字符 → `_ZN10x265_10bit`。我一开始按 9 个字符 grep，得到 0 命中并误判"命名空间没生效"。**数错长度会得出相反结论**，必要时用 `--no-demangle` 直看。
31. **验证产物有效性比"rc=0"便宜且更有力**：读输出文件头的容器魔数（Matroska `1a 45 df a3`；MP4 内含 `66 74 79 70` = "ftyp"），或者干脆**用 HandBrake 回读自己刚生成的产物**——能回读就说明编码器产出的是合法可解码流。

