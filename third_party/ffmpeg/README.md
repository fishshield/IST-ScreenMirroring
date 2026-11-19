# FFmpeg runtime (Windows x64)

本目录为 **本地运行库缓存**，DLL 不提交到版本控制（见根 `.gitignore`）。
运行时只需要以下三个 DLL：

- `avcodec-62.dll`
- `avutil-60.dll`
- `swresample-6.dll`

来源与分发：

- Gyan Doshi FFmpeg builds，`ffmpeg-8.1.2-full_build-shared.7z`
  <https://www.gyan.dev/ffmpeg/builds/>
- 该共享构建按 **GPLv3** 分发；许可证随包保存在 `LICENSE.txt`。
- **推荐获取方式**：从本仓库的 GitHub Release（tag `ffmpeg-8.1.2`）下载
  `ffmpeg-8.1.2-shared-win64.zip`；`tool/fetch_ffmpeg.ps1` 会优先使用它，
  用 `SHA256SUMS` 校验 DLL，失败时回退到上游 7z。
- 发布用的 zip 由 `tool/pack_ffmpeg_release.ps1` 生成（含 DLL、许可证、
  构建说明与 `SHA256SUMS`）。

## 为什么是 shared 构建

Dart FFI 需要 `DynamicLibrary.open` 加载 `avcodec-*.dll`，静态 `ffmpeg.exe`
不能用于 FFI。完整构建包含 H.264 解码器与 YUV420p 输出。

## 路径解析

`FfmpegRuntime.findLibraryDirectory()` 依次检查：

1. `--dart-define=SCREENCAST_FFMPEG_DIR=...`
2. `SCREENCAST_FFMPEG_DIR` 环境变量
3. `FFMPEG_DIR` 环境变量
4. 当前目录 `third_party/ffmpeg/bin`
5. 可执行文件旁 `ffmpeg/`
6. 可执行文件旁 `data/flutter_assets/ffmpeg/`

Windows runner 的 CMake install 规则会把这三个 DLL 复制到构建输出目录，
`flutter run`/安装后的应用可从第 5 项找到。开发时从项目根执行测试时走第 4 项。

## 最小解码器的限制

`lib/src/ffmpeg/ffmpeg_decoder.dart` 只处理：

- H.264 Annex-B 输入（SCRC 的 NAL 会补起始码与最新 SPS/PPS）
- 每个 VCL NAL 一帧的常见码流
- `yuv420p` / `yuvj420p` 输出

没有处理多 slice 帧聚合、B 帧重排、PTS、分辨率切换、硬件帧或音视频同步。
这些属于接入真实编码器后的下一阶段工作。
