/*
 * HandBrake for HarmonyOS -- transcode UI.
 *
 * The engine runs out-of-process: every HandBrakeCLI invocation forks a child
 * (see cpp/napi_init.cpp), so a codec crash can never take the UI down and
 * repeated jobs start from a clean libhb.  Progress is parsed from the CLI's
 * own "Encoding: task 1 of 1, 45.2 %" line and pushed to this page through a
 * threadsafe NAPI callback.
 *
 * Files never leave the sandbox implicitly: input is copied in from the system
 * picker, output is copied back out through the system save dialog.
 */
import { deviceInfo, pasteboard } from '@kit.BasicServicesKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { promptAction } from '@kit.ArkUI';
import { media } from '@kit.MediaKit';
import { image } from '@kit.ImageKit';
import hb from 'libhandbrake.so';

const TAG = 'HBUI';

interface PresetAudioJson {
  AudioEncoder?: string;
  AudioBitrate?: number;
}

interface PresetEntryJson {
  VideoEncoder?: string;
  VideoQualitySlider?: number;
  VideoQualityType?: number;
  VideoPreset?: string;
  VideoFramerate?: string;
  PictureHeight?: number;
  FileFormat?: string;
  AudioList?: PresetAudioJson[];
}

interface PresetDumpJson {
  PresetList?: PresetEntryJson[];
}

class CustomPreset {
  name: string = '';
  encoder: string = 'x264';
  quality: number = 24;
  speed: string = 'fast';
  container: string = 'mkv';
  audio: string = 'aac';
  abitrate: number = 128;
  maxHeight: number = 0;
  fps: number = 0;
}
const QUALITY_MIN = 16;
const QUALITY_MAX = 32;

function stamp(): string {
  const d = new Date();
  const p = (n: number): string => n < 10 ? `0${n}` : `${n}`;
  return `${d.getFullYear()}${p(d.getMonth() + 1)}${p(d.getDate())}-` +
         `${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

function describeRc(rc: number): string {
  if (rc >= 0) {
    return `rc=${rc}`;
  }
  const sig = -(rc + 1000);
  let name = 'SIGNAL';
  if (sig === 11) {
    name = 'SIGSEGV';
  } else if (sig === 6) {
    name = 'SIGABRT';
  } else if (sig === 7) {
    name = 'SIGBUS';
  } else if (sig === 4) {
    name = 'SIGILL';
  } else if (sig === 9) {
    name = 'SIGKILL(已取消)';
  }
  return `${rc} (${name})`;
}

function humanSize(n: number): string {
  if (n < 0) {
    return '?';
  }
  if (n < 1024) {
    return `${n} B`;
  }
  if (n < 1024 * 1024) {
    return `${(n / 1024).toFixed(1)} KB`;
  }
  if (n < 1024 * 1024 * 1024) {
    return `${(n / 1024 / 1024).toFixed(1)} MB`;
  }
  return `${(n / 1024 / 1024 / 1024).toFixed(2)} GB`;
}

@Entry
@Component
struct Index {
  @State details: string = '';
  @State inName: string = '';
  @State inSize: number = -1;
  @State inPath: string = '';
  @State encoder: string = 'x264';
  @State quality: number = 24;
  @State preset: string = 'fast';
  @State running: boolean = false;
  @State progress: number = 0;
  @State status: string = '待命';
  @State outPath: string = '';
  @State outSize: number = -1;
  @State elapsedMs: number = 0;
  @State diag: string = '';
  @State logPath: string = '';
  @State thumb: image.PixelMap | undefined = undefined;
  @State meta: string = '';
  @State container: string = 'mkv';
  @State exportedUri: string = '';
  @State srtPath: string = '';
  @State srtName: string = '';
  @State burnSubs: boolean = true;
  @State fontInfo: string = '';
  @State audioItems: string[] = [];
  @State audioSel: boolean[] = [];
  @State subItems: string[] = [];
  @State subSel: boolean[] = [];
  @State scanState: string = '';
  @State presetNames: string[] = [];
  @State presetName: string = '';
  @State presetLabel: string = '自定义';
  @State presetState: string = '加载预设…';
  @State customPresets: CustomPreset[] = [];
  @State overridePreset: boolean = false;
  @State audioCodec: string = 'aac';
  @State audioBitrate: number = 128;
  @State maxHeight: number = 0;
  @State fps: number = 0;
  private scanBuf: string[] = [];
  private collecting: boolean = false;
  private collectMode: number = 0; // 1 = scan, 2 = preset list
  private tail: string[] = [];     // last CLI lines, for failure hints

  private ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;

  aboutToAppear(): void {
    this.details = `${deviceInfo.productModel} · API ${deviceInfo.sdkApiVersion} · ${deviceInfo.abiList}`;
    hb.hbSetPaths(this.ctx.cacheDir, this.ctx.filesDir);
    this.setupFont();

    try {
      const dir = `${this.ctx.filesDir}/logs`;
      try {
        fs.mkdirSync(dir, true);
      } catch (e) {
        // already exists
      }
      this.logPath = `${dir}/handbrake-${stamp()}.log`;
      hb.hbSetLogFile(this.logPath);
    } catch (e) {
      hilog.error(0xFF01, TAG, 'log setup failed');
    }

    // progress callback: invoked on the JS thread with 0..100
    hb.hbSetProgressCallback((pct: number) => {
      this.progress = pct;
      this.status = `转码中 ${pct.toFixed(1)}%`;
    });
    hb.hbSetLogCallback((line: string) => {
      this.tail.push(line);
      if (this.tail.length > 200) {
        this.tail.shift();
      }
      if (this.collectMode !== 0) {
        this.scanBuf.push(line);
      }
    });

    this.loadCustomPresets();
    this.loadPresets();
  }

  /**
   * Write a sandbox file to a URI returned by the system save dialog.
   *
   * fs.writeSync()'s WriteOptions.offset is a *file position* offset, not a
   * buffer offset (unlike Node's fs.writeSync(fd, buf, offset, length, pos)),
   * so passing { offset: 0 } rewinds to the start on every chunk and the result
   * is a truncated file.  Omitting offset lets the file pointer advance, which
   * is what a sequential copy needs.
   */
  private writeToUri(srcPath: string, destUri: string): number {
    const expected = this.fileSizeOf(srcPath);
    if (expected <= 0) {
      throw new Error('源文件为空，转码可能失败');
    }

    // Attempt 1: system-level copy through file descriptors.
    try {
      const src = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
      const dst = fs.openSync(destUri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      try {
        fs.copyFileSync(src.fd, dst.fd);
        const got = fs.statSync(dst.fd).size;
        if (got === expected) {
          return got;
        }
      } finally {
        fs.closeSync(src);
        fs.closeSync(dst);
      }
    } catch (e) {
      hilog.warn(0xFF01, TAG, 'copyFileSync export failed, falling back');
    }

    // Attempt 2: sequential copy.  No offset: WriteOptions.offset is a file
    // position, so passing 0 would rewind to the start of every chunk.
    const src = fs.openSync(srcPath, fs.OpenMode.READ_ONLY);
    const dst = fs.openSync(destUri, fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
    try {
      const buf = new ArrayBuffer(1 << 20);
      let n = 0;
      while ((n = fs.readSync(src.fd, buf)) > 0) {
        fs.writeSync(dst.fd, buf, { length: n });
      }
      const got = fs.statSync(dst.fd).size;
      if (got !== expected) {
        throw new Error(`写入不完整: ${got}/${expected} 字节`);
      }
      return got;
    } finally {
      fs.closeSync(src);
      fs.closeSync(dst);
    }
  }

  /**
   * Copy a picked file into the sandbox.
   *
   * Uses fs.copyFileSync() on the source *fd* (the documented way to copy a
   * picker URI); the hand-rolled read/write loop used before silently produced a
   * truncated file, which surfaced much later as FFmpeg's
   * "moov atom not found".  The byte count is verified afterwards so a partial
   * copy can never reach the encoder again.
   */
  private copyTo(srcUri: string, destPath: string): number {
    let expected = -1;
    try {
      expected = fs.statSync(srcUri).size;
    } catch (e) {
      expected = -1;
    }
    const src = fs.openSync(srcUri, fs.OpenMode.READ_ONLY);
    try {
      fs.copyFileSync(src.fd, destPath);
    } finally {
      fs.closeSync(src);
    }
    const got = this.fileSizeOf(destPath);
    if (got <= 0 || (expected > 0 && got !== expected)) {
      throw new Error(`拷贝不完整: ${got}/${expected} 字节`);
    }
    return got;
  }

  private fileSizeOf(path: string): number {
    try {
      return fs.statSync(path).size;
    } catch (e) {
      return -1;
    }
  }

  /** libass 没有 fontconfig，需要一个真实字体文件；优先系统字体 */
  private setupFont(): void {
    try {
      const dir = '/system/fonts';
      const names: string[] = fs.listFileSync(dir);
      let pick = '';
      for (const n of names) {
        const lower = n.toLowerCase();
        if (lower.indexOf('.ttf') < 0 && lower.indexOf('.ttc') < 0) {
          continue;
        }
        if (pick === '') {
          pick = n;
        }
        if (lower.indexOf('sans') >= 0 && (lower.indexOf('sc') >= 0 || lower.indexOf('cjk') >= 0)) {
          pick = n;
          break;
        }
        if (lower.indexOf('sans') >= 0) {
          pick = n;
        }
      }
      if (pick !== '') {
        this.fontInfo = pick;
        hb.hbSetEnv('HB_SUB_FONT', `${dir}/${pick}`);
      } else {
        this.fontInfo = '(未找到系统字体)';
      }
    } catch (e) {
      this.fontInfo = `字体探测失败: ${JSON.stringify(e)}`;
    }
  }

  /** 选择外部 SRT 字幕 */
  async pickSrt(): Promise<void> {
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.srt', '.ass', '.ssa'];
      const doc = new picker.DocumentViewPicker(this.ctx);
      const uris = await doc.select(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      let name = uris[0].substring(uris[0].lastIndexOf('/') + 1);
      try {
        name = decodeURIComponent(name);
      } catch (e) {
        // keep raw
      }
      const dot = name.lastIndexOf('.');
      const ext = dot > 0 ? name.substring(dot) : '.srt';
      const dest = `${this.ctx.filesDir}/sub-${stamp()}${ext}`;
      this.copyTo(uris[0], dest);
      this.srtPath = dest;
      this.srtName = name;
      this.status = '字幕已导入';
    } catch (e) {
      this.status = `字幕选择失败: ${JSON.stringify(e)}`;
    }
  }

  private presetFilePath(): string {
    return `${this.ctx.filesDir}/presets.json`;
  }

  private loadCustomPresets(): void {
    try {
      const text: string = fs.readTextSync(this.presetFilePath());
      const arr: CustomPreset[] = JSON.parse(text) as CustomPreset[];
      this.customPresets = arr;
    } catch (e) {
      this.customPresets = [];
    }
  }

  private persistCustomPresets(): void {
    try {
      const f = fs.openSync(this.presetFilePath(),
        fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
      fs.writeSync(f.fd, JSON.stringify(this.customPresets));
      fs.closeSync(f);
    } catch (e) {
      this.status = `保存预设失败: ${JSON.stringify(e)}`;
    }
  }

  /**
   * Load a built-in preset's actual parameter values into the UI.
   *
   * `--preset-export <name>` alone only dumps the *command line* state; the
   * trick is to load the preset first (`-Z name`) and then export it, which
   * yields the preset's real values.
   */
  private async applyBuiltinPreset(name: string): Promise<void> {
    this.scanBuf = [];
    this.collectMode = 3;
    this.presetState = `读取「${name}」参数…`;
    try {
      await hb.runCli(['-Z', name, '--preset-export', '__dsh_dump__']);
    } catch (e) {
      hilog.error(0xFF01, TAG, 'preset export failed');
    }
    this.collectMode = 0;

    const text = this.scanBuf.join('\n');
    const start = text.indexOf('{');
    const end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      this.presetState = `「${name}」参数解析失败`;
      return;
    }
    let dump: PresetDumpJson;
    try {
      dump = JSON.parse(text.substring(start, end + 1)) as PresetDumpJson;
    } catch (e) {
      this.presetState = `「${name}」参数解析失败`;
      return;
    }
    const list = dump.PresetList;
    if (list === undefined || list.length === 0) {
      this.presetState = `「${name}」没有参数`;
      return;
    }
    const e = list[0];

    // encoder
    const ve = (e.VideoEncoder !== undefined ? e.VideoEncoder : '').toLowerCase();
    if (ve === 'x265' || ve === 'x265_10bit' || ve === 'x265_12bit') {
      this.encoder = 'x265';
    } else if (ve === 'x264') {
      this.encoder = 'x264';
    }

    // quality (only when the preset is RF-based)
    if (e.VideoQualityType === 2 && e.VideoQualitySlider !== undefined) {
      const q = Math.round(e.VideoQualitySlider);
      this.quality = Math.min(QUALITY_MAX, Math.max(QUALITY_MIN, q));
    }

    // speed: our UI only offers three steps
    const vp = (e.VideoPreset !== undefined ? e.VideoPreset : '').toLowerCase();
    if (vp === 'ultrafast' || vp === 'superfast' || vp === 'veryfast') {
      this.preset = 'ultrafast';
    } else if (vp === 'faster' || vp === 'fast') {
      this.preset = 'fast';
    } else {
      this.preset = 'medium';
    }

    // container
    const fmt = (e.FileFormat !== undefined ? e.FileFormat : '').toLowerCase();
    this.container = fmt.indexOf('mkv') >= 0 ? 'mkv' : 'mp4';

    // resolution: map to the closest selectable cap
    const h = e.PictureHeight !== undefined ? e.PictureHeight : 0;
    if (h >= 2160) {
      this.maxHeight = 2160;
    } else if (h >= 1440) {
      this.maxHeight = 1440;
    } else if (h >= 1080) {
      this.maxHeight = 1080;
    } else if (h >= 720) {
      this.maxHeight = 720;
    } else if (h >= 480) {
      this.maxHeight = 480;
    } else {
      this.maxHeight = 0;
    }

    // frame rate
    const fr = (e.VideoFramerate !== undefined ? e.VideoFramerate : 'auto').toLowerCase();
    const frv = fr === 'auto' ? 0 : Number(fr);
    this.fps = (frv === 60 || frv === 50 || frv === 30 || frv === 25 || frv === 24) ? frv : 0;

    // audio
    const al = e.AudioList;
    if (al !== undefined && al.length > 0) {
      const ae = (al[0].AudioEncoder !== undefined ? al[0].AudioEncoder : '').toLowerCase();
      if (ae.indexOf('copy') >= 0) {
        this.audioCodec = 'copy';
      } else if (ae.indexOf('eac3') >= 0) {
        this.audioCodec = 'eac3';
      } else if (ae.indexOf('mp3') >= 0) {
        this.audioCodec = 'mp3';
      } else if (ae.indexOf('ac3') >= 0) {
        this.audioCodec = 'ac3';
      } else {
        this.audioCodec = 'aac';
      }
      const ab = al[0].AudioBitrate !== undefined ? al[0].AudioBitrate : 0;
      const rates: number[] = [96, 128, 160, 192, 256];
      let best = 128;
      for (const r of rates) {
        if (Math.abs(r - ab) < Math.abs(best - ab)) {
          best = r;
        }
      }
      if (ab > 0) {
        this.audioBitrate = best;
      }
    }
    this.presetState = `已载入「${name}」参数`;
  }

  /** 预设名由参数自动生成，用户不需要输入任何文字 */
  private autoPresetName(): string {
    const enc = this.encoder === 'x265' ? 'H.265' : 'H.264';
    const aud = this.audioCodec === 'copy' ? 'COPY' : this.audioCodec.toUpperCase();
    const res = this.maxHeight > 0 ? ` ${this.maxHeight}p` : '';
    const rate = this.fps > 0 ? ` ${this.fps}fps` : '';
    return `${enc} RF${this.quality} ${this.preset} ${this.container.toUpperCase()} ${aud}${this.audioBitrate}${res}${rate}`;
  }

  private saveCustomPreset(): void {
    let name = this.autoPresetName();
    if (this.customPresets.some((x: CustomPreset) => x.name === name)) {
      let n = 2;
      while (this.customPresets.some((x: CustomPreset) => x.name === `${name} (${n})`)) {
        n++;
      }
      name = `${name} (${n})`;
    }
    const p = new CustomPreset();
    p.name = name;
    p.encoder = this.encoder;
    p.quality = this.quality;
    p.speed = this.preset;
    p.container = this.container;
    p.audio = this.audioCodec;
    p.abitrate = this.audioBitrate;
    p.maxHeight = this.maxHeight;
    p.fps = this.fps;
    const list = this.customPresets.filter((x: CustomPreset) => x.name !== name);
    list.push(p);
    this.customPresets = list;
    this.persistCustomPresets();
    this.status = `预设「${name}」已保存`;
  }

  private applyCustomPreset(name: string): void {
    for (const p of this.customPresets) {
      if (p.name === name) {
        this.encoder = p.encoder;
        this.quality = p.quality;
        this.preset = p.speed;
        this.container = p.container;
        this.audioCodec = p.audio;
        this.audioBitrate = p.abitrate;
        this.maxHeight = p.maxHeight !== undefined ? p.maxHeight : 0;
        this.fps = p.fps !== undefined ? p.fps : 0;
        this.presetName = '';
        this.status = `已应用自定义预设「${name}」`;
        return;
      }
    }
  }

  private deleteCustomPreset(name: string): void {
    this.customPresets = this.customPresets.filter((x: CustomPreset) => x.name !== name);
    this.persistCustomPresets();
    this.status = `预设「${name}」已删除`;
  }

  /** 读取 HandBrake 内置预设（--preset-list） */
  private async loadPresets(): Promise<void> {
    this.scanBuf = [];
    this.collectMode = 2;
    try {
      await hb.runCli(['--preset-list']);
    } catch (e) {
      hilog.error(0xFF01, TAG, 'preset list failed');
    }
    this.collectMode = 0;
    const names: string[] = [];
    for (const raw of this.scanBuf) {
      if (!raw.startsWith('    ') || raw.startsWith('        ')) {
        continue;
      }
      const name = raw.trim();
      if (name === '' || name.endsWith('/')) {
        continue;
      }
      // SVT-AV1 is not built in this port
      if (name.toLowerCase().indexOf('av1') >= 0) {
        continue;
      }
      if (names.indexOf(name) < 0) {
        names.push(name);
      }
    }
    this.presetNames = names;
    this.presetState = names.length > 0 ? `${names.length} 个可用预设` : '没有可用预设';
  }

  private presetOptions(): SelectOption[] {
    const opts: SelectOption[] = [{ value: '自定义' }];
    for (const n of this.presetNames) {
      opts.push({ value: n });
    }
    for (const p of this.customPresets) {
      opts.push({ value: `★ ${p.name}` });
    }
    return opts;
  }

  private presetIndex(): number {
    const opts = this.presetOptions();
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].value === this.presetLabel) {
        return i;
      }
    }
    return 0;
  }

  private audioOptions(): SelectOption[] {
    return [{ value: 'AAC' }, { value: 'MP3' }, { value: 'AC3' }, { value: 'E-AC3' }, { value: '复制' }];
  }

  private audioIndex(): number {
    const m: string[] = ['aac', 'mp3', 'ac3', 'eac3', 'copy'];
    const i = m.indexOf(this.audioCodec);
    return i < 0 ? 0 : i;
  }

  /** 扫描源文件的音轨/字幕轨 */
  private async scanTracks(path: string): Promise<void> {
    this.scanBuf = [];
    this.collectMode = 1;
    this.scanState = '扫描轨道…';
    try {
      await hb.runCli(['--scan', '-i', path]);
    } catch (e) {
      hilog.error(0xFF01, TAG, 'scan failed');
    }
    this.collectMode = 0;
    this.parseScan(this.scanBuf);
    this.scanState = `音轨 ${this.audioItems.length} · 字幕轨 ${this.subItems.length}`;
  }

  private parseScan(lines: string[]): void {
    const audio: string[] = [];
    const subs: string[] = [];
    let mode = 0; // 1 = audio, 2 = subtitle
    for (const raw of lines) {
      const t = raw.trim();
      if (t.indexOf('+ audio tracks:') === 0) {
        mode = 1;
        continue;
      }
      if (t.indexOf('+ subtitle tracks:') === 0) {
        mode = 2;
        continue;
      }
      if (t.indexOf('+ ') === 0 && t.indexOf(',') > 0 && (mode === 1 || mode === 2)) {
        const body = t.substring(2).trim();
        const cut = body.indexOf(',');
        const num = body.substring(0, cut).trim();
        const label = body.substring(cut + 1).trim();
        if (/^[0-9]+$/.test(num)) {
          const entry = `${num}|${label}`;
          if (mode === 1) {
            audio.push(entry);
          } else {
            subs.push(entry);
          }
          continue;
        }
      }
      if (t.indexOf('+ ') === 0 && mode !== 0 && t.indexOf('tracks:') > 0) {
        mode = 0;
      }
    }
    this.audioItems = audio;
    this.subItems = subs;
    const a: boolean[] = [];
    for (let i = 0; i < audio.length; i++) {
      a.push(true);
    }
    const b: boolean[] = [];
    for (let i = 0; i < subs.length; i++) {
      b.push(false);
    }
    this.audioSel = a;
    this.subSel = b;
  }

  /** 生成缩略图和元数据（失败不影响转换） */
  private async loadPreview(path: string): Promise<void> {
    this.thumb = undefined;
    this.meta = '';
    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const gen = await media.createAVImageGenerator();
        try {
          gen.fdSrc = { fd: f.fd };
          const params: media.PixelMapParams = { width: 480, height: 270 };
          try {
            this.thumb = await gen.fetchFrameByTime(1000000,
              media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, params);
          } catch (e1) {
            // very short clips may have no key frame at 1 s
            this.thumb = await gen.fetchFrameByTime(0,
              media.AVImageQueryOptions.AV_IMAGE_QUERY_CLOSEST_SYNC, params);
          }
        } finally {
          await gen.release();
        }
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0xFF01, TAG, 'thumbnail failed: %{public}s', JSON.stringify(e));
    }

    try {
      const f = fs.openSync(path, fs.OpenMode.READ_ONLY);
      try {
        const ext = await media.createAVMetadataExtractor();
        try {
          ext.fdSrc = { fd: f.fd };
          const md = await ext.fetchMetadata();
          const w = md.videoWidth !== undefined ? md.videoWidth : '?';
          const h = md.videoHeight !== undefined ? md.videoHeight : '?';
          const dur = md.duration !== undefined ? (Number(md.duration) / 1000).toFixed(1) : '?';
          this.meta = `${w}×${h} · ${dur}s`;
        } finally {
          await ext.release();
        }
      } finally {
        fs.closeSync(f);
      }
    } catch (e) {
      hilog.error(0xFF01, TAG, 'metadata failed');
    }
  }

  /** 选择输入视频，拷贝进沙箱 */
  async pickInput(): Promise<void> {
    try {
      const opt = new picker.DocumentSelectOptions();
      opt.maxSelectNumber = 1;
      opt.fileSuffixFilters = ['.mp4', '.mkv', '.mov', '.m4v', '.avi', '.ts', '.webm'];
      const doc = new picker.DocumentViewPicker(this.ctx);
      const uris = await doc.select(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      const uri = uris[0];
      let name = uri.substring(uri.lastIndexOf('/') + 1);
      try {
        name = decodeURIComponent(name);
      } catch (e) {
        // keep raw name
      }
      const dot = name.lastIndexOf('.');
      const ext = dot > 0 ? name.substring(dot) : '.mp4';
      const dest = `${this.ctx.filesDir}/input-${stamp()}${ext}`;
      this.status = '正在导入…';
      const n = this.copyTo(uri, dest);
      this.inPath = dest;
      this.inName = name;
      this.inSize = n;
      await this.loadPreview(dest);
      await this.scanTracks(dest);
      this.outPath = '';
      this.outSize = -1;
      this.progress = 0;
      this.status = '就绪';
    } catch (e) {
      this.status = `选择失败: ${JSON.stringify(e)}`;
    }
  }

  async start(): Promise<void> {
    if (this.running || this.inPath === '') {
      return;
    }
    this.running = true;
    this.progress = 0;
    this.outSize = -1;
    this.diag = '';
    this.tail = [];
    const out = `${this.ctx.filesDir}/out-${stamp()}.${this.container}`;
    this.outPath = out;
    const args: string[] = [];
    args.push('-i', this.inPath, '-o', out);
    const usePreset = this.presetName !== '';
    if (usePreset) {
      // Built-in preset drives encoder/quality/speed.
      args.push('-Z', this.presetName);
      if (this.overridePreset) {
        args.push('-e', this.encoder, '-q', `${this.quality}`,
                  '--encoder-preset', this.preset,
                  '-E', this.audioCodec, '-B', `${this.audioBitrate}`);
      }
    } else {
      args.push('-e', this.encoder, '-q', `${this.quality}`,
                '--encoder-preset', this.preset,
                '-E', this.audioCodec, '-B', `${this.audioBitrate}`);
    }
    args.push('-f', this.container);
    if (this.maxHeight > 0) {
      // -Y caps the height and keeps the aspect ratio; it never upscales.
      args.push('-Y', `${this.maxHeight}`);
    }
    if (this.fps > 0) {
      // --pfr keeps audio/video sync while capping the frame rate.
      args.push('-r', `${this.fps}`, '--pfr');
    }
    const aud: string[] = [];
    for (let i = 0; i < this.audioItems.length; i++) {
      if (this.audioSel[i]) {
        aud.push(this.audioItems[i].split('|')[0]);
      }
    }
    // Audio track selection.
    //
    // HandBrake's --audio *replaces* the audio settings a preset configured
    // (encoder included), and the CLI default for MKV is MP3 -- which this
    // FFmpeg build has no encoder for (libmp3lame missing), so a preset job
    // would fail with rc=3.  Therefore:
    //   * everything selected + preset  -> omit --audio, keep the preset's audio
    //   * nothing selected              -> --audio none
    //   * partial selection            -> explicit list (encoder set above)
    let allOn = true;
    let noneOn = true;
    for (let i = 0; i < this.audioItems.length; i++) {
      if (this.audioSel[i]) {
        noneOn = false;
      } else {
        allOn = false;
      }
    }
    if (this.audioItems.length > 0) {
      if (noneOn) {
        args.push('--audio', 'none');
      } else if (!(usePreset && allOn)) {
        args.push('--audio', aud.join(','));
      }
    }
    const emb: string[] = [];
    for (let i = 0; i < this.subItems.length; i++) {
      if (this.subSel[i]) {
        emb.push(this.subItems[i].split('|')[0]);
      }
    }
    if (emb.length > 0) {
      args.push('--subtitle', emb.join(','));
      if (this.burnSubs) {
        args.push('--subtitle-burned', emb[0]);
      }
    }
    if (this.srtPath !== '') {
      // MP4 cannot carry soft subtitles, so MP4 always burns them in.
      const burn = this.burnSubs || this.container === 'mp4';
      const lower = this.srtPath.toLowerCase();
      const isAss = lower.endsWith('.ass') || lower.endsWith('.ssa');
      if (isAss) {
        // ASS/SSA carry their own encoding and styling; libass renders them.
        args.push('--ssa-file', this.srtPath, '--ssa-lang', 'chi');
        if (burn) {
          args.push('--ssa-burn');
        }
      } else {
        // SRT is plain text: force UTF-8, otherwise CLI assumes ISO-8859-1
        // and non-ASCII cues come out as mojibake.
        args.push('--srt-file', this.srtPath, '--srt-lang', 'chi', '--srt-codeset', 'UTF-8');
        if (burn) {
          args.push('--srt-burn');
        }
      }
    }
    const t0 = Date.now();
    this.status = '启动编码器…';
    try {
      const rc: number = await hb.runCli(args);
      this.elapsedMs = Date.now() - t0;
      this.outSize = this.fileSizeOf(out);
      if (rc === 0 && this.outSize > 0) {
        this.status = `完成 · ${humanSize(this.outSize)} · ${(this.elapsedMs / 1000).toFixed(1)}s`;
        this.progress = 100;
        promptAction.showToast({ message: '转码完成', duration: 2000 });
      } else {
        let hint = '';
        for (const l of this.tail) {
          if (l.indexOf('libmp3lame') >= 0) {
            hint = '（预设需要 MP3 编码，本版本未编 lame：请用「修改预设参数」把音频设为 AAC）';
            break;
          }
        }
        this.status = `失败 ${describeRc(rc)} ${hint}`;
      }
    } catch (e) {
      this.status = `异常: ${JSON.stringify(e)}`;
    } finally {
      this.running = false;
    }
  }

  cancel(): void {
    const r: number = hb.hbCancel();
    this.status = r === 0 ? '已请求取消…' : '没有正在运行的任务';
  }

  /** 把转码结果导出到用户选择的位置 */
  async exportResult(): Promise<void> {
    if (this.outPath === '' || this.outSize <= 0) {
      return;
    }
    try {
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [`handbrake-${this.encoder}-${stamp()}.${this.container}`];
      opt.fileSuffixChoices = [`.${this.container}`];
      const doc = new picker.DocumentViewPicker(this.ctx);
      const uris = await doc.save(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      this.status = '正在写入…';
      const n = this.writeToUri(this.outPath, uris[0]);
      this.exportedUri = uris[0];
      this.status = `已导出 ${humanSize(n)} → ${uris[0]}`;
      promptAction.showToast({ message: '已保存', duration: 2000 });
    } catch (e) {
      this.status = `导出失败: ${JSON.stringify(e)}`;
    }
  }

  /** 一段式诊断：x264 / x265 / 回读，结果写日志 */
  async runDiagnostics(): Promise<void> {
    if (this.running) {
      return;
    }
    this.running = true;
    this.diag = '诊断中…';
    const dir = this.ctx.filesDir;
    let src = this.inPath;
    try {
      if (src === '') {
        src = `${dir}/sample.mp4`;
        if (this.fileSizeOf(src) <= 0) {
          const bytes: Uint8Array = this.ctx.resourceManager.getRawFileContentSync('sample.mp4');
          const f = fs.openSync(src, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE);
          fs.writeSync(f.fd, bytes.buffer as ArrayBuffer);
          fs.closeSync(f);
        }
      }
      const a: number = await hb.runCli(['-i', src, '-o', `${dir}/diag-x264.mkv`, '-e', 'x264',
        '-q', '28', '--encoder-preset', 'ultrafast', '-f', 'mkv']);
      const b: number = await hb.runCli(['-i', src, '-o', `${dir}/diag-x265.mkv`, '-e', 'x265',
        '-q', '28', '--encoder-preset', 'ultrafast', '-f', 'mkv']);
      const c: number = await hb.runCli(['-i', `${dir}/diag-x265.mkv`, '-o', `${dir}/diag-rt.mp4`,
        '-e', 'x264', '-q', '30', '--encoder-preset', 'ultrafast', '-f', 'mp4']);
      this.diag = `x264: ${describeRc(a)}\nx265: ${describeRc(b)}\n回读: ${describeRc(c)}`;
    } catch (e) {
      this.diag = `诊断异常: ${JSON.stringify(e)}`;
    } finally {
      this.running = false;
      this.status = '诊断结束';
    }
  }

  async copyLogPath(): Promise<void> {
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.logPath);
      await pasteboard.getSystemPasteboard().setData(data);
      promptAction.showToast({ message: '日志路径已复制', duration: 2000 });
    } catch (e) {
      this.status = `${e}`;
    }
  }

  async exportLog(): Promise<void> {
    try {
      const opt = new picker.DocumentSaveOptions();
      opt.newFileNames = [`handbrake-${stamp()}.log`];
      opt.fileSuffixChoices = ['.log', '.txt'];
      const doc = new picker.DocumentViewPicker(this.ctx);
      const uris = await doc.save(opt);
      if (!uris || uris.length === 0) {
        return;
      }
      this.writeToUri(this.logPath, uris[0]);
      promptAction.showToast({ message: '日志已导出', duration: 2000 });
    } catch (e) {
      this.status = `日志导出失败: ${JSON.stringify(e)}`;
    }
  }

  build() {
    Column() {
      Scroll() {
        Column({ space: 14 }) {
          Column({ space: 4 }) {
            Text('HandBrake').fontSize(26).fontWeight(FontWeight.Bold)
            Text(this.details).fontSize(11).fontColor('#888888')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text('输入').fontSize(13).fontColor('#888888').width('100%')
            Row({ space: 10 }) {
              Text(this.inName === '' ? '未选择视频' : this.inName)
                .fontSize(14).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Text(this.inSize > 0 ? humanSize(this.inSize) : '')
                .fontSize(12).fontColor('#888888')
            }
            .width('100%')
            Button('选择视频').width('100%').onClick(() => { this.pickInput(); })
            if (this.thumb !== undefined) {
              Image(this.thumb)
                .width('100%').height(180).objectFit(ImageFit.Cover).borderRadius(8)
            }
            if (this.meta !== '') {
              Text(this.meta).fontSize(11).fontColor('#888888')
            }
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text('预设').fontSize(13).fontColor('#888888').width('100%')
            Select(this.presetOptions())
              .selected(this.presetIndex())
              .value(this.presetLabel)
              .width('100%')
              .onSelect((index: number, value: string) => {
                this.presetLabel = value;
                if (index === 0) {
                  this.presetName = '';
                } else if (value.startsWith('★ ')) {
                  this.applyCustomPreset(value.substring(2));
                } else {
                  this.presetName = value;
                  this.applyBuiltinPreset(value);
                }
              })
            Text(this.presetName === ''
              ? (this.presetLabel.startsWith('★ ') ? '自定义预设：参数已填入下方' : '自定义：使用下方编码参数')
              : '预设会覆盖编码器 / 质量 / 速度设置')
              .fontSize(10).fontColor('#999999').width('100%')
            Text(this.presetState).fontSize(10).fontColor('#BBBBBB').width('100%')
            if (this.presetName !== '') {
              Row({ space: 10 }) {
                Text('修改预设参数').fontSize(12)
                Blank()
                Toggle({ type: ToggleType.Switch, isOn: this.overridePreset })
                  .onChange((v: boolean) => { this.overridePreset = v; })
              }
              .width('100%')
              Text(this.overridePreset
                ? '下方编码器 / 质量 / 速度会覆盖预设同名设置'
                : '完全按预设执行')
                .fontSize(10).fontColor('#999999').width('100%')
            }
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text('将保存为').fontSize(10).fontColor('#999999')
                Text(this.autoPresetName()).fontSize(11).fontColor('#333333')
                  .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
              Button('保存为预设').height(36).fontSize(12)
                .onClick(() => { this.saveCustomPreset(); })
            }
            .width('100%')
            ForEach(this.customPresets, (p: CustomPreset) => {
              Row({ space: 8 }) {
                Text(`★ ${p.name}`).fontSize(11).layoutWeight(1)
                Text(`${p.encoder} · RF${p.quality} · ${p.container}`).fontSize(10).fontColor('#999999')
                Button('删除').height(28).fontSize(10)
                  .backgroundColor('#F1F3F5').fontColor('#CC3333')
                  .onClick(() => { this.deleteCustomPreset(p.name); })
              }
              .width('100%')
              .onClick(() => { this.applyCustomPreset(p.name); this.presetLabel = `★ ${p.name}`; })
            }, (p: CustomPreset) => p.name)
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 12 }) {
            Text('编码参数').fontSize(13).fontColor('#888888').width('100%')
            Row({ space: 8 }) {
              Button('H.264 (x264)')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.encoder === 'x264' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.encoder === 'x264' ? Color.White : '#333333')
                .onClick(() => { this.encoder = 'x264'; })
              Button('H.265 (x265)')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.encoder === 'x265' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.encoder === 'x265' ? Color.White : '#333333')
                .onClick(() => { this.encoder = 'x265'; })
            }
            .width('100%')

            Row({ space: 8 }) {
              Button('MKV')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.container === 'mkv' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.container === 'mkv' ? Color.White : '#333333')
                .onClick(() => { this.container = 'mkv'; })
              Button('MP4')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.container === 'mp4' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.container === 'mp4' ? Color.White : '#333333')
                .onClick(() => { this.container = 'mp4'; })
            }
            .width('100%')

            Row({ space: 8 }) {
              Button('极速')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.preset === 'ultrafast' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.preset === 'ultrafast' ? Color.White : '#333333')
                .onClick(() => { this.preset = 'ultrafast'; })
              Button('快速')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.preset === 'fast' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.preset === 'fast' ? Color.White : '#333333')
                .onClick(() => { this.preset = 'fast'; })
              Button('中等')
                .fontSize(13).height(34).padding({ left: 14, right: 14 })
                .backgroundColor(this.preset === 'medium' ? '#0A59F7' : '#F1F3F5')
                .fontColor(this.preset === 'medium' ? Color.White : '#333333')
                .onClick(() => { this.preset = 'medium'; })
            }
            .width('100%')

            Row({ space: 8 }) {
              Text('分辨率').fontSize(13)
              Blank()
              Select([{ value: '原始' }, { value: '2160p' }, { value: '1440p' },
                      { value: '1080p' }, { value: '720p' }, { value: '480p' }])
                .selected(this.maxHeight === 0 ? 0 : this.maxHeight === 2160 ? 1 :
                          this.maxHeight === 1440 ? 2 : this.maxHeight === 1080 ? 3 :
                          this.maxHeight === 720 ? 4 : 5)
                .value(this.maxHeight === 0 ? '原始' : `${this.maxHeight}p`)
                .onSelect((index: number) => {
                  const h: number[] = [0, 2160, 1440, 1080, 720, 480];
                  this.maxHeight = h[index];
                })
            }
            .width('100%')

            Row({ space: 8 }) {
              Text('帧率').fontSize(13)
              Blank()
              Select([{ value: '保持原样' }, { value: '60' }, { value: '50' },
                      { value: '30' }, { value: '25' }, { value: '24' }])
                .selected(this.fps === 0 ? 0 : this.fps === 60 ? 1 : this.fps === 50 ? 2 :
                          this.fps === 30 ? 3 : this.fps === 25 ? 4 : 5)
                .value(this.fps === 0 ? '保持原样' : `${this.fps}`)
                .onSelect((index: number) => {
                  const f: number[] = [0, 60, 50, 30, 25, 24];
                  this.fps = f[index];
                })
            }
            .width('100%')

            Row() {
              Text('质量 (RF)').fontSize(13)
              Blank()
              Text(`${this.quality}`).fontSize(13).fontWeight(FontWeight.Medium)
            }
            .width('100%')

            Slider({ value: this.quality, min: QUALITY_MIN, max: QUALITY_MAX, step: 1 })
              .width('100%')
              .onChange((v: number) => { this.quality = Math.round(v); })

            Text('数值越小画质越好、文件越大（推荐 22–26）')
              .fontSize(10).fontColor('#999999').width('100%')
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 10 }) {
            Text('音频').fontSize(13).fontColor('#888888').width('100%')
            Row({ space: 8 }) {
              Text('编码').fontSize(12)
              Blank()
              Select(this.audioOptions())
                .selected(this.audioIndex())
                .value(this.audioOptions()[this.audioIndex()].value)
                .onSelect((index: number, value: string) => {
                  const m: string[] = ['aac', 'mp3', 'ac3', 'eac3', 'copy'];
                  this.audioCodec = m[index];
                })
              Select([{ value: '96 kbps' }, { value: '128 kbps' }, { value: '160 kbps' },
                      { value: '192 kbps' }, { value: '256 kbps' }])
                .selected(this.audioBitrate === 96 ? 0 : this.audioBitrate === 128 ? 1 :
                          this.audioBitrate === 160 ? 2 : this.audioBitrate === 192 ? 3 : 4)
                .value(`${this.audioBitrate} kbps`)
                .onSelect((index: number) => {
                  this.audioBitrate = [96, 128, 160, 192, 256][index];
                })
            }
            .width('100%')
            Text(this.audioCodec === 'copy' ? '直接复制音轨，不重新编码'
                 : `重新编码为 ${this.audioCodec.toUpperCase()} ${this.audioBitrate} kbps`)
              .fontSize(10).fontColor('#999999').width('100%')
            if (this.audioItems.length > 0) {
              Divider().color('#EEEEEE')
              Text('源音轨（关掉的不输出）').fontSize(11).fontColor('#888888').width('100%')
              ForEach(this.audioItems, (item: string, idx: number) => {
                Row({ space: 8 }) {
                  Text(item.split('|').length > 1 ? item.split('|')[1] : item)
                    .fontSize(11).layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Toggle({ type: ToggleType.Switch, isOn: this.audioSel[idx] })
                    .onChange((v: boolean) => {
                      const a = this.audioSel.slice();
                      a[idx] = v;
                      this.audioSel = a;
                    })
                }
                .width('100%')
              }, (item: string, idx: number) => `${idx}-${item}`)
            }
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 8 }) {
            Text('字幕').fontSize(13).fontColor('#888888').width('100%')
            Row({ space: 10 }) {
              Text(this.srtName === '' ? '未选择字幕（SRT / ASS）' : this.srtName)
                .fontSize(13).layoutWeight(1).maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
              Button('选择字幕').onClick(() => { this.pickSrt(); })
            }
            .width('100%')
            Row({ space: 10 }) {
              Text('烧录到画面').fontSize(13)
              Blank()
              Toggle({ type: ToggleType.Switch, isOn: this.burnSubs })
                .onChange((v: boolean) => { this.burnSubs = v; })
            }
            .width('100%')
            Text(this.fontInfo === '' ? '' : `字体: ${this.fontInfo}`)
              .fontSize(10).fontColor('#999999').width('100%')
            if (this.scanState !== '') {
              Text(this.scanState).fontSize(10).fontColor('#999999').width('100%')
            }
            if (this.subItems.length > 0) {
              Text('内嵌字幕轨').fontSize(11).fontColor('#888888').width('100%')
              ForEach(this.subItems, (item: string, idx: number) => {
                Row({ space: 8 }) {
                  Text(item.split('|').length > 1 ? item.split('|')[1] : item)
                    .fontSize(11).layoutWeight(1).maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                  Toggle({ type: ToggleType.Switch, isOn: this.subSel[idx] })
                    .onChange((v: boolean) => {
                      const b = this.subSel.slice();
                      b[idx] = v;
                      this.subSel = b;
                    })
                }
                .width('100%')
              }, (item: string, idx: number) => `s${idx}-${item}`)
            }
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)
          .alignItems(HorizontalAlign.Start)

          Column({ space: 10 }) {
            if (this.running) {
              Progress({ value: this.progress, total: 100, type: ProgressType.Linear })
                .width('100%').height(6)
            }
            Row({ space: 10 }) {
              Button(this.running ? '转码中…' : '开始转码')
                .layoutWeight(1)
                .enabled(!this.running && this.inPath !== '')
                .onClick(() => { this.start(); })
              Button('取消')
                .enabled(this.running)
                .backgroundColor('#E5E5E5').fontColor('#333333')
                .onClick(() => { this.cancel(); })
            }
            .width('100%')
            Text(this.status).fontSize(12).width('100%').fontColor('#555555')
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)

          if (this.outSize > 0) {
            Column({ space: 8 }) {
              Text('结果').fontSize(13).fontColor('#888888').width('100%')
              Row() {
                Text(humanSize(this.outSize)).fontSize(18).fontWeight(FontWeight.Medium)
                Blank()
                Text(`${(this.elapsedMs / 1000).toFixed(1)} s`).fontSize(12).fontColor('#888888')
              }
              .width('100%')
              Button('导出视频').width('100%').onClick(() => { this.exportResult(); })
            }
            .padding(14).width('100%').backgroundColor('#E8F1FF').borderRadius(12)
            .alignItems(HorizontalAlign.Start)
          }

          Column({ space: 8 }) {
            Text('诊断').fontSize(13).fontColor('#888888').width('100%')
            Row({ space: 10 }) {
              Button('自检').layoutWeight(1).backgroundColor('#F1F3F5').fontColor('#333333')
                .enabled(!this.running)
                .onClick(() => { this.runDiagnostics(); })
              Button('导出日志').layoutWeight(1).backgroundColor('#F1F3F5').fontColor('#333333')
                .onClick(() => { this.exportLog(); })
            }
            .width('100%')
            Text(this.diag).fontSize(11).width('100%').fontColor('#555555')
            Text('日志路径（点击复制）').fontSize(10).fontColor('#999999')
              .onClick(() => { this.copyLogPath(); })
          }
          .padding(14).width('100%').backgroundColor('#F7F8FA').borderRadius(12)
          .alignItems(HorizontalAlign.Start)
        }
        .padding(16)
        .width('100%')
      }
      .layoutWeight(1)
      .align(Alignment.Top)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.White)
  }
}
