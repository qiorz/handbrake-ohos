# HandBrake HarmonyOS 2.0.0 —— 从测试台到可用 App

## 界面

```
HandBrake
QXS-W00 · API 26 · arm64-v8a
┌ 输入 ────────────────────────────┐
│ 选中的文件名 / 大小     [选择视频] │
└──────────────────────────────────┘
┌ 编码参数 ────────────────────────┐
│ [H.264 (x264)] [H.265 (x265)]     │
│ [极速] [快速] [中等]               │
│ 质量 (RF)                    24   │
│ ──────●──────────────             │
└──────────────────────────────────┘
┌ [开始转码]            [取消] ─────┐
│ ▓▓▓▓▓▓░░░░░  转码中 62.4%         │
└──────────────────────────────────┘
┌ 结果 ────────────────────────────┐
│ 3.2 MB                    12.4 s  │
│ [导出视频]                        │
└──────────────────────────────────┘
┌ 诊断 ────────────────────────────┐
│ [自检] [导出日志]                  │
└──────────────────────────────────┘
```

## 交互流程

1. **选择视频** → 系统文件选择器 → 拷贝进沙箱 `files/input-<时间戳>.<ext>`
2. **开始转码** → 子进程跑 HandBrakeCLI，进度来自它自己的
   `Encoding: task 1 of 1, 62.4 %` 输出
3. **取消** → `hbCancel()` 给子进程发 `SIGKILL`，UI 立即回到可用状态
4. **导出视频** → 系统保存对话框 → 从沙箱拷贝到用户选择的位置
5. **自检** → 依次跑 x264 / x265 / 回读，结果只显示三行 rc（完整日志仍写文件）

## 实现要点

| 能力 | 实现 |
|---|---|
| 进度 | 日志读取线程按 `\r` 切分（CLI 用回车刷新进度），正则提取百分比，经 `napi_threadsafe_function` 投递到 JS 线程 |
| 取消 | `fork` 出的子进程 pid 存在 `g_child_pid`，`kill(pid, SIGKILL)`；父进程 `waitpid` 得到 `WTERMSIG=9`，UI 显示"已取消" |
| 崩溃隔离 | 每个任务独立子进程，编码器崩了只影响那一次任务 |
| 文件进出 | 输入用 `DocumentViewPicker.select` + 沙箱拷贝；输出用 `DocumentViewPicker.save` + 反向拷贝 |
| 日志 | 仍然每行 tee 到 `files/logs/handbrake-*.log`，`导出日志` 按钮可保存到下载目录 |

## 尚未在设备上验证

UI 层（文件选择器、拷贝、进度回调、取消）是这次新写的，编译通过但**没在真机上跑过**。
需要确认：

1. 选文件 → 导入是否成功（大小显示对不对）
2. 进度条是否真的在动（如果不动，说明 CLI 的进度输出没被解析到）
3. 取消是否真的能停下（`SIGKILL` 是否被沙箱允许）
4. 导出视频是否落到下载目录

## 已知限制

- 输出固定 MKV（`-f mkv`）；MP4 需要按音轨/字幕兼容性再判断
- 字幕烧录仍不可用（libass 未编译，`rendersub.c` 被裁）
- 缩放走 swscale（zscale 不可用），画质够用但不是 lanczos 精确色彩管理
- 一次只跑一个任务，没有队列

---

# 2.1.0 更新（修 rc=2 + 加预览）

## 1. 转码失败 rc=2 的根因：导入的文件是残缺的

日志：

```
libhb: Opening .../input-20261021-205404.mp4...
libhb: [mov,mp4,m4a,...] moov atom not found
libhb: hb_stream_open: ... failed
libhb: scan: unrecognized file type -> No title found. rc=2
```

不是编码器的问题，是**拷贝进沙箱时截断了**。

原因：我按 Node.js 的 `fs.writeSync(fd, buf, offset, length, position)` 语义写了循环，
但 HarmonyOS 的 `WriteOptions.offset` 定义是"**文件写入起始位置（当前 filePointer
+ offset）**"，不是缓冲区偏移。每块数据都落在错误的文件位置上，最终文件只有最后一块
的内容，MP4 的 `moov` 在尾部 → FFmpeg 直接判定文件无效。

修复：改用 `fs.copyFileSync(srcFile.fd, destPath)`（SDK 明确支持 `string | number`，
也是官方处理 picker URI 的推荐写法），并在拷贝后**比对字节数**，不一致立即报错，
不让残缺文件再流到编码器。

## 2. 新增预览

选完视频后：

- 缩略图：`media.createAVImageGenerator()` + `fetchFrameByTime()`，取第 1 秒关键帧，
  失败自动回退到第 0 帧；480×270 显示
- 元数据：`media.createAVMetadataExtractor().fetchMetadata()` 取 `videoWidth` /
  `videoHeight` / `duration`，显示为 `1920×1080 · 12.5s`

两者都是可选增强：失败只记日志，不影响选择文件和转码。

## 3. 待验证

- 导入后大小是否与源文件一致（现在有不一致就报错）
- 缩略图是否显示、元数据是否正确
- 转码是否不再 rc=2

---

# 2.2.1 更新（修导出 0 字节 + 打开文件夹 + 容器选择）

## 1. 导出 0 字节：写目标 URI 时根本没写进去

`exportResult()` 里调用的是导入用的 `copyTo()`，它做的是：

```ts
fs.copyFileSync(srcFile.fd, destStr)   // destStr 是 picker 返回的 URI
```

`copyFileSync` 的 dest 虽然签名上接受 `string | number`，但传一个 **picker URI 字符串**
并不会解析成那个文档，写入实际没有落到目标文件上；而系统保存对话框**已经创建了一个
空文件**，所以用户看到的就是 0 KB。

日志也是 0 字节，原因完全相同 —— 导出日志复用了同一个函数。

修复：新增专用的 `writeToUri()`，先打开目标 URI 拿 fd，再两条路径兜底：

1. `fs.copyFileSync(src.fd, dst.fd)`（fd → fd）
2. 顺序读写：`fs.writeSync(dst.fd, buf, { length: n })`
   —— **不传 offset**。`WriteOptions.offset` 是"文件位置偏移"，传 0 会让每个
   1 MB 块都回到文件开头，最终只剩最后一块（2.1.0 之前的导入截断就是这个原因）

两条路都以 `fs.statSync(dst.fd).size === 源大小` 作为通过条件，不一致直接报错。

## 2. 容器选择提到转码前

之前固定 `-f mkv`，但导出时允许存成 `.mp4` —— 内容是 MKV、后缀是 MP4，播放器当然不认。
现在界面上先选 **MKV / MP4**，`-f` 跟着变，导出对话框的默认后缀和可选后缀也锁定为同一种。

## 3. 打开输出文件夹

导出成功后会记住目标 URI，结果卡片上多一个「打开输出文件夹」：

- 先尝试 `startAbility({ action: 'ohos.want.action.viewData', uri: <目录URI> })`
- 系统不认目录时，退化为用默认播放器打开该文件

鸿蒙没有"在文件管理器中定位到某文件"的公开 API，这是能拿到的最接近的行为。

## 4. 仍在的已知问题

- 输出只有 MKV / MP4 两种容器，音轨固定 AAC 128k，没有多音轨/字幕轨选择
- 字幕烧录仍不可用（libass 未编译）

---

# 2.3.1 更新（修「选项点不动」+ 移除打开文件夹）

## 1. 根因：@Builder 按值传参不刷新

参数芯片原来是这么写的：

```ts
@Builder chip(label: string, active: boolean, onTap: () => void) { ... }
...
this.chip('H.265 (x265)', this.encoder === 'x265', () => { this.encoder = 'x265'; })
```

ArkUI 的 `@Builder` **按值传参时参数变化不会引起刷新**，实测连回调里的状态赋值也没能
体现在下一次渲染/下一次 `start()` 读取上。证据是 21:18 的日志：

```
+ container: Matroska (libavformat)
+ encoder: H.264 (libx264)
+ preset:  fast
```

用户界面上点过 H.265 / MP4，但实际编码仍是最初的默认值 —— 说明点击没有改变状态。

## 2. 修法

- 删掉 `@Builder chip`
- 三组选项全部改成 `Button`（同页面里「选择视频」「开始转码」「导出视频」都工作正常，
  是最可靠的控件），高亮状态直接写在 `build()` 的属性表达式里：

```ts
Button('H.265 (x265)')
  .backgroundColor(this.encoder === 'x265' ? '#0A59F7' : '#F1F3F5')
  .fontColor(this.encoder === 'x265' ? Color.White : '#333333')
  .onClick(() => { this.encoder = 'x265'; })
```

这样状态变化会走正常的 @State 重绘路径。

## 3. 移除「打开输出文件夹」

`startAbility` 对目录 URI 的落点不可控（跳到了错误位置），功能先摘掉，
`exportedUri` 状态保留，等有可靠接口再做。

## 4. 待验证

装上 2.3.1 后点 H.265 / MP4 / 极速，应当立即高亮，并且日志里
`+ encoder:` / `+ container:` / `+ preset:` 跟着变。

---

# 2.4.0 更新（字幕烧录）

## 1. 补上的依赖

| 库 | 版本 | 用途 |
|---|---|---|
| libass | 0.17.4 | 字幕渲染 |
| harfbuzz | 8.5.0 | 文字整形（libass 0.17 强制依赖） |
| freetype | 2.13.3 | 字形栅格化 |
| fribidi | 1.0.16 | 双向文本 |

全部静态交叉编译到 `out/ohos-arm64/lib/`。harfbuzz 用 meson 交叉编译（cross file 里
`pkgconfig` 要写成不带连字符的键，且**不能**设 `sys_root`，否则会把 pkg-config 返回的
绝对路径再拼一次前缀）。

## 2. 代码改动

- `port-ohos/CMakeLists.txt`：`rendersub.c` 从排除列表移回，`DEPS_LIBS` 增加
  `libass/libharfbuzz/libfreetype/libfribidi`
- `stubs/ohos_stubs.c`：删掉 `hb_filter_render_sub` 桩
- `libhb/rendersub.c`：**字体**。libass 没有 fontconfig，`ass_set_fonts(..., "Arial", fc=1)`
  解析不到字体。改成：
  1. 先读环境变量 `HB_SUB_FONT`（App 设置）
  2. 否则依次探测 `/system/fonts/` 下的常见字体
  3. 传 `haveFontConfig=0` + 明确的字体路径，并打日志 `rendersub: using font ...`
- 新增 NAPI `hbSetEnv(key, value)`，App 启动时扫描 `/system/fonts` 找 `.ttf/.ttc`，
  优先选含 `sans` 且含 `sc/cjk` 的，写入 `HB_SUB_FONT`

## 3. CLI 用法（实测通过）

```
HandBrakeCLI -i in.mp4 -o out.mkv -e x264 --srt-file sub.srt --srt-lang chi --srt-burn
```

注意：烧录 SRT 用的是 **`--srt-burn`**，不是 `--subtitle-burned`（后者对导入的 SRT
不生效，会退化成直通）。本地 qemu 实测日志：

```
rendersub: using font /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf
* subtitle track 1, English (SRT) ... -> Render/Burn-in
libhb: work result = 0
```

## 4. 界面

新增「字幕」卡片：选择 SRT + 「烧录到画面」开关 + 当前使用的字体名。
MP4 容器不能承载 SRT 软字幕，所以 MP4 会强制烧录。

## 5. 待验证

- 设备上 `/system/fonts` 能否被列出（界面会显示探测到的字体名）
- 烧录后画面里是否真的出现字幕（如果没有，日志会显示 `rendersub: no usable font file found`）
- 中文字幕是否正常（需要系统里有中文字形）

---

# 2.4.1 更新（ASS / SSA 字幕）

## 1. 两种字幕走不同的 CLI 参数

| 输入 | 参数 |
|---|---|
| `.srt` | `--srt-file <path> --srt-lang chi --srt-codeset UTF-8`，烧录加 `--srt-burn` |
| `.ass` / `.ssa` | `--ssa-file <path> --ssa-lang chi`，烧录加 `--ssa-burn` |

ASS/SSA **没有** `--ssa-codeset`（这类文件自带编码与样式），所以不加这个参数。
App 按选中文件的扩展名自动选择。

## 2. 顺手修了 SRT 的中文乱码隐患

上一版没传 `--srt-codeset`，HandBrake 默认按 **ISO-8859-1** 解释（设备日志里可以看到
`charset: ISO-8859-1`），中文字幕会变乱码。现在固定传 `UTF-8`，日志里变成
`charset: UTF-8`。

## 3. 本地实测（qemu，同一份 libass 构建）

```
# ASS
* subtitle track 1, 中文 (SSA) (track 0, id 0xff000000, Text) -> Render/Burn-in
libhb: work result = 0

# 中文 SRT + UTF-8
* subtitle track 1, 中文 (SRT) ... -> Render/Burn-in, charset: UTF-8
libhb: work result = 0
```

## 4. 设备侧已确认

2.4.0 的日志里字体探测正确：

```
rendersub: using font /system/fonts/HarmonyOS_Sans_SC.ttf
```

注意实际文件名是 `HarmonyOS_Sans_SC.ttf`（不是我在源码里写死的
`HarmonyOS_Sans_SC_Regular.ttf`），所以 App 里"扫描 /system/fonts 动态挑选"的做法是对的。

## 5. 待验证

- 选 `.ass` 文件烧录，样式（颜色/描边/位置）是否按 ASS 脚本呈现
- 中文字幕是否不再乱码

---

# 2.5.0 更新（扫描真实轨道 + 多音轨/内嵌字幕选择）

## 1. 为什么需要扫描

之前只能选**外部** SRT/ASS 文件，源文件里自带的音轨和字幕轨完全不可见、不可选。
HandBrakeCLI 的 `--scan` 会打印标题信息，其中：

```
  + audio tracks:
    + 1, English (AAC) (2.0 ch) (iso639-2: eng)
  + subtitle tracks:
    + 1, 中文 (UTF-8)
```

## 2. 实现

- native 新增 `hbSetLogCallback(fn)`：把 CLI 的每一行非进度输出投递给 ArkTS
  （进度行仍走 `hbSetProgressCallback`，两者互斥，避免刷屏）
- 选完文件后自动跑一次 `--scan`，ArkTS 按 `+ audio tracks:` / `+ subtitle tracks:`
  分段解析出「序号 + 描述」
- 界面上渲染成两组开关：音轨默认全开，内嵌字幕默认全关
- 转码时拼参数：
  - 音轨：`--audio 1,2`
  - 内嵌字幕：`--subtitle 1,2`，若开启「烧录到画面」再加 `--subtitle-burned <第一个选中的>`

## 3. 解析验证

用软字幕合成的 MKV（`--srt-file --subtitle 1`，不烧录）实测扫描输出，解析结果为：

```
subs : ['1|中文 (UTF-8)']
```

## 4. 待验证

- 选一个**带音轨和字幕轨**的视频，看列表是否完整列出
- 关掉某些音轨后，输出文件里是不是真的少了对应的轨
- 内嵌字幕烧录（`--subtitle-burned`）与外部 SRT 烧录（`--srt-burn`）是两条不同的
  代码路径，都要各试一次

---

# 2.5.1 修复（取消全部音轨后仍然有声音）

## 原因

原逻辑只在「至少选中一条音轨」时才拼 `--audio`：

```ts
if (aud.length > 0) { args.push('--audio', aud.join(',')); }
```

**不传 `--audio` 时，HandBrake 的默认行为是「选第一条音轨」**，所以全部取消后反而
保留了第一条。字幕的默认是「不选」，所以关字幕有效、关音轨无效 —— 症状完全对得上。

## 修法

`--audio` 无条件传，全部取消时传 `none`（`test.c` 里 `atracks[0] == "none"` 会跳过
所有音轨）：

```ts
args.push('--audio', aud.length > 0 ? aud.join(',') : 'none');
```

## 验证（qemu 本地）

带音轨的样本（w3c sintel trailer，AAC 2.0）：

```
# 转码
HandBrakeCLI -i sintel.mp4 -o noaudio.mkv -e x264 -q 28 --audio none -f mkv
rc=0

# 扫描产物
  + audio tracks:      ← 空
  + subtitle tracks:
```

## 顺带改进：日志里现在有完整命令行

`napi_init.cpp` 会打印

```
HandBrakeCLI: 17 args: -i ... -o ... -e x264 -q 24 --encoder-preset fast -E aac -B 128 -f mkv --audio none --subtitle 1 --subtitle-burned 1
```

以后排查「参数到底传没传」不用再猜。

---

# 2.6.0 更新（内置预设）

## 1. 预设从哪来

不硬编码名称，直接读 HandBrake 自己的 `--preset-list`：

```
General/
    Very Fast 1080p30
        Small H.264 video (up to 1080p30) ...
    Fast 1080p30
        ...
```

解析规则：分类行无缩进（以 `/` 结尾），预设名缩进 4 空格，描述缩进 8 空格。
**AV1 预设被过滤掉**（本移植没编 SVT-AV1，选了必然失败）。过滤后共 **100 个可用预设**。

## 2. 交互

- 启动时后台跑一次 `--preset-list`，结果填进下拉框
- 选「自定义」→ 用下面的编码器/质量/速度，行为与之前一致
- 选任一预设 → CLI 用 `-Z "<预设名>"`，预设覆盖编码器/质量/速度；容器仍由
  上面的 MKV/MP4 通过 `-f` 决定
- 音轨、字幕、轨道选择与预设互不影响，照常拼接

## 3. 实测

```
HandBrakeCLI -i sintel.mp4 -o preset.mkv -Z "Fast 1080p30" -f mkv --stop-at duration:3
+ Using preset: Fast 1080p30
+ storage dimensions: 854 x 364
libhb: work result = 0
196K preset.mkv
```

注意预设有 `maxWidth/maxHeight`，HandBrake **不会放大小于目标尺寸的源**，所以
848×360 的源仍然是 854×364，不会被拉成 1080p。

## 4. 待验证

- 下拉框能列出预设（约 100 条）
- 选一个预设后转码，日志里应出现 `+ Using preset: <名称>`
- 确认挑选的预设与 MKV/MP4 选择不冲突（`-f` 会覆盖预设里的容器）

---

# 2.7.0 更新（预设可用性 + 修改预设 + 自定义预设）

## 1. rc=3 的根因：`--audio` 把预设的音频设置顶掉了

设备日志：

```
+ Using preset: Very Fast 720p30
+ encoder: MP3 (libmp3lame)
ERROR: encavcodecaInit: avcodec_find_encoder_by_name(libmp3lame) failed
Encode failed (error 3).
```

预设本身是 `av_aac` + MP4，但 App 一直在传 `--audio 1`。
**HandBrake 的 `--audio` 会整体替换预设配置的音频（包括编码器），而 CLI 对 MKV 的
默认音频编码是 MP3** —— 这份 FFmpeg 没编 libmp3lame，于是初始化失败，rc=3。

本地复现（同一预设，加 `--audio 1` 就复现）：

```
# 不传 --audio
+ encoder: AAC (libavcodec)        work result = 0
# 传 --audio 1
+ encoder: MP3 (libmp3lame)        work result = 3
```

修复后的规则：

| 情况 | 行为 |
|---|---|
| 预设 + 全部音轨选中 | **不传 `--audio`**，让预设的音频设置生效 |
| 全部取消 | `--audio none` |
| 部分选中 | `--audio 1,3`（编码器由界面上的音频选项决定） |

## 2. 修改预设参数

选中内置预设后出现「修改预设参数」开关。打开后会把
`-e <编码器> -q <质量> --encoder-preset <速度> -E <音频> -B <码率>`
接在 `-Z <预设名>` 之后 —— HandBrake 按参数顺序生效，后者覆盖前者。

本地实测：

```
-Z "Very Fast 720p30" -e x265 -q 26 --encoder-preset veryfast
+ encoder: H.265 (libx265)
+ quality: 26.00 (RF)
work result = 0
```

## 3. 自定义预设

- 输入名称 → 「保存」：把当前 编码器 / 质量 / 速度 / 容器 / 音频编码 / 码率 存进
  `filesDir/presets.json`
- 下拉框里以 `★ 名称` 出现，选中后自动填回上述参数
- 列表里可「删除」
- 新建时同名会覆盖

## 4. 失败提示

每次任务保留最后 200 行 CLI 输出；失败时若检测到 `libmp3lame`，状态栏会直接提示
「预设需要 MP3 编码，本版本未编 lame：请用『修改预设参数』把音频设为 AAC」。

## 5. 已知限制

本版本 FFmpeg 未启用 libmp3lame，**显式使用 MP3 音频的预设**仍会失败。
彻底解决需要：编 libmp3lame → 重建 FFmpeg（`--enable-libmp3lame`）→ 重编 libhb，
属于依赖链重建，可以单独安排一轮。

---

# 2.7.1 更新（自定义预设不再需要打字）

## 1. 改动

原来保存自定义预设要先在输入框里打一个名字，现在完全去掉输入：

- 预设名由当前参数**自动生成**，例如
  `H.265 RF26 fast MP4 AAC128`
- 界面实时显示「将保存为：<这个名字>」，点一下「保存为预设」即可
- 同名自动加序号：`... (2)`、`... (3)`
- 已保存的预设行**点一下就应用**（不只是通过下拉框选择），行尾仍可删除

## 2. 现在创建自定义预设的完整路径（全程选择，无输入）

1. 编码器：H.264 / H.265（按钮）
2. 容器：MKV / MP4（按钮）
3. 速度：极速 / 快速 / 中等（按钮）
4. 质量：滑块 16–32
5. 音频：AAC / AC3 / E-AC3 / 复制 + 码率下拉
6. 点「保存为预设」

## 3. 和内置预设的关系

- 先在下拉框选一个内置预设，再打开「修改预设参数」，改完随手保存 → 就得到一个
  以该预设参数为底的自定义预设（保存时记录的是**改完之后**的参数值）
- 自定义预设走「手动参数」通道，不依赖 `-Z`，因此不受预设音频默认值的影响

---

# 2.8.0 更新（分辨率 + 帧率）

## 1. 界面

「编码参数」里新增两行下拉：

| 选项 | 取值 | CLI |
|---|---|---|
| 分辨率 | 原始 / 2160p / 1440p / 1080p / 720p / 480p | `-Y <高度>`（maxHeight） |
| 帧率 | 保持原样 / 60 / 50 / 30 / 25 / 24 | `-r <fps> --pfr` |

## 2. 为什么用 -Y 而不是 -w/-h

`-Y/--maxHeight` 是**上限**语义：按比例缩小、保持宽高比、**不会放大小尺寸源**。
用 `-w/-h` 会把 360p 的片子硬拉成 1080p，画质不会变好、文件却变大。

## 3. 为什么用 --pfr 而不是 --cfr

`--pfr`（peak frame rate）在限制上限的同时保留可变帧率，音画同步更安全；
`--cfr` 强制恒定帧率，遇到 23.976/29.97 这类非整数帧率容易产生重复/丢帧。

## 4. 实测

```
HandBrakeCLI -i sintel.mp4 -o rf.mkv -e x264 -q 28 -f mkv -Y 240 -r 15 --pfr --stop-at duration:3

+ frame rate: 24.000 fps -> peak rate limited to 15.000 fps
+ storage dimensions: 854 x 240
libhb: work result = 0
```

## 5. 与预设的关系

这两项在 `-Z <预设>` **之后**追加，所以总会覆盖预设里的同名设置 —— 即使用内置预设，
也能临时改分辨率/帧率。自定义预设会一并记录这两个值，名字里也会体现，例如
`H.265 RF26 fast MP4 AAC128 720p 30fps`。

---

# 2.9.0 更新（选预设时，参数面板跟着联动）

## 1. 怎么拿到预设的真实参数

坑：`--preset-export <name>` 的帮助写的是「Create a **new** preset from command line
options」，单独用只会导出命令行当前状态（全是默认值），不是那个预设的内容。

正确姿势是**先加载再导出**：

```
HandBrakeCLI -Z "Fast 1080p30" --preset-export __dsh_dump__
```

这样导出的才是该预设的真实配置。

## 2. 映射关系

| 预设字段 | 界面控件 | 说明 |
|---|---|---|
| `VideoEncoder` | 编码器 | `x264`→H.264；`x265`/`x265_10bit`/`x265_12bit`→H.265 |
| `VideoQualitySlider`（仅 `VideoQualityType==2`） | 质量 | RF 值，夹到 16–32 |
| `VideoPreset` | 速度 | `ultrafast/superfast/veryfast`→极速；`faster/fast`→快速；其余→中等 |
| `FileFormat` | 容器 | 含 `mkv`→MKV，否则 MP4 |
| `PictureHeight` | 分辨率 | 就近归到 2160/1440/1080/720/480，太小则「原始」 |
| `VideoFramerate` | 帧率 | `auto`→保持原样；60/50/30/25/24 才认 |
| `AudioList[0]` | 音频 | `copy*`→复制，`ac3`/`eac3`/其余→AAC；码率就近归到 96/128/160/192/256 |

四个速度档位被压成三档是刻意的——界面只提供极速/快速/中等，`slow`、`veryslow`
这类都归到「中等」，实际编码仍由 `-Z` 决定（预设本身没被改）。

## 3. 实测样例

| 预设 | 导出值 | 界面显示 |
|---|---|---|
| Fast 1080p30 | x264 / RF22 / fast / 1080 / 30 / mp4 / aac160 | H.264 / 22 / 快速 / 1080p / 30 / MP4 / AAC160 |
| Fast 2160p60 4K HEVC | x265_10bit / RF24 / faster / 2160 / 60 | H.265 / 24 / 快速 / 2160p / 60 |
| HQ 1080p30 Surround | x264 / RF20 / slow / 1080 / 30 | H.264 / 20 / 中等 / 1080p / 30 |

其中 HEVC 预设实跑通过（`H.265 10-bit (libx265)`，rc=0）。

## 4. 注意

- 勾选「修改预设参数」后再改值，会用界面上的 8-bit `x265` 覆盖预设的 `x265_10bit`；
  不改就仍按预设（10-bit）执行。
- 预设里还有音轨混音、滤镜、tune 等我们没映射的项，它们仍由 `-Z` 生效，
  界面只反映「我们提供控件的那部分」。

---

# 3.0.0 更新（MP3 编码：重建 FFmpeg + lame）

## 1. 为什么必须重建 FFmpeg

HandBrake 1.11 的 MP3 编码走的是 FFmpeg 的 `libmp3lame` 封装（`encavcodec.c` 里
`avcodec_find_encoder_by_name("libmp3lame")`），原来的构建显式
`--disable-libmp3lame`，所以音频线程初始化失败、rc=3。

## 2. 这次做了什么

1. **lame 3.100**：静态交叉编译出 `libmp3lame.a`（只编 `libmp3lame/` 子目录 ——
   `mpglib`（解码端）是 90 年代代码，在 clang 15 下有 `memcpy→bcopy` 等一堆错误，
   而我们只需要编码）
2. **FFmpeg 8.0.2 重建**：沿用原配置，改动三处
   - `--disable-libmp3lame` → `--enable-libmp3lame`
   - 增加 `--enable-encoder=libmp3lame`
   - `--extra-cflags/-ldflags` 指向我们的 prefix
   仍然应用 HandBrake 的 **25 个补丁**（`contrib/ffmpeg/A*.patch`），否则 libhb 编不过
3. **libhb / HAP 重链**：`DEPS_LIBS` 增加 `libmp3lame.a`

## 3. 构建时的两个坑

- lame / libass 这类老式 autotools 项目，`config.status` 会报 "config.h is unchanged"
  但文件其实不存在。用 `touch config.h.in && ./config.status config.h` 才真正生成
  （用 `--file=` 只会做路径替换，不生成 `#define` 宏）
- FFmpeg 的 `libmp3lame.o` 已经在 `libavcodec.a` 里，额外再链 `libmp3lame.a` 是补
  `lame_*` 实现，顺序上要放在 libavcodec 之后

## 4. 实测（qemu）

```
# 显式指定 MP3
-e x264 -E mp3 -B 160      -> + encoder: MP3 (libmp3lame)   work result = 0

# 原来失败的那条路径（预设 + --audio 1）
-Z "Very Fast 720p30" --audio 1 -> + encoder: MP3 (libmp3lame)  work result = 0
```

App 的 `.so` 里能查到 `LAME3.100` 与 `libmp3lame` 字符串，确认编码器真的链进去了。

## 5. 界面

音频下拉新增 **MP3**；预设联动时 `AudioEncoder` 含 `mp3` 的会映射到它。

---

# 3.0.1 更新（音频选项"找不到"）

## 问题

音频设置其实从 2.7.0 起就在，但被塞在「编码参数」卡片中间（容器和分辨率之间），
而且**音轨开关错放在「字幕」卡片里**——两处都很难找。

## 修复

把音频相关的东西集中到一个独立卡片，顺序调整为：

```
输入 → 预设 → 编码参数 → 音频 → 字幕 → 结果 → 诊断
```

新「音频」卡片内容：

- **编码**：AAC / MP3 / AC3 / E-AC3 / 复制
- **码率**：96 / 128 / 160 / 192 / 256 kbps
- 一行说明：`重新编码为 MP3 160 kbps` 或 `直接复制音轨，不重新编码`
- **源音轨列表**：每条一个开关，关掉的不输出（之前藏在字幕卡片里）

## 注意

如果装的是 3.0.0 或更早，界面里没有这个卡片是很正常的——请装 3.0.1。

---

# 3.1.0 更新（沙箱缓存面板）

## 背景

鸿蒙应用无法读取沙箱外的路径，所以"选文件 → 拷进沙箱"这一步无法省掉（之前设想的
`/proc/self/fd` 方案在鸿蒙沙箱里不成立）。既然拷贝不可避免，就把它产生的空间占用
变成可见、可管理的：新增「沙箱缓存」面板。

## 面板内容

「诊断」卡片里点「沙箱缓存」展开：

| 行 | 含义 |
|---|---|
| 占用合计 | 沙箱内四类文件总和 |
| 可用 X / 共 Y | 设备剩余/总空间（`statfs.getFreeSizeSync/getTotalSizeSync`） |
| 缓存 / 临时文件 | `cacheDir`（libhb 的临时目录、缩略图等），可单独清理 |
| 导入的源文件 | `filesDir/input-*`，可单独清理 |
| 转码产物 | `filesDir/out-*`、`diag-*`、`hb-*`，可单独清理 |
| 日志 | `filesDir/logs/`，可单独清理 |
| 全部清理 | 以上全清（保留 `presets.json`） |

每个清理按钮都会弹确认框，避免误删。

## 实现要点

- 统计：`fs.listFileSync` + `fs.statSync` 递归遍历，返回「字节数 + 文件数」
- 清理：`fs.unlinkSync` / `fs.rmdirSync`（后者递归删目录）
- 清理后立即刷新占用，并清空界面里已失效的输入/输出路径
- **转码进行中禁止清理**，避免删掉正在读写的文件
- 清理只动应用沙箱，**导出到系统目录的视频不受影响**

## 注意

「转码产物」清掉后，未导出的视频就没了（导出到系统目录的副本仍在）。
