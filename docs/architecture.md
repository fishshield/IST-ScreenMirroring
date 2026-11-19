# 架构说明：拓扑 A

## 1. 组件与数据流

```text
Flutter (Windows)
  ├─ CastController / CastTransportConfig
  ├─ AdbLauncher ─ push + optional ADB/TCP + app_process ──▶ Android app_process
  │   (wired / wireless only; direct skips this branch entirely)
  ├─ ScrcSocketClient ◀── SCRC over 127.0.0.1:27183 (wired)
  │                       or phone-LAN-IP:27183 (wireless / direct) ◀── ServerSocket
  ├─ NalDecodeQueue
  ├─ FfmpegDecoder (dart:ffi → avcodec-62.dll)
  ├─ NativeVideoSurface ── NV12 mapped upload + bounds ──▶ owned Win32 popup + D3D11
  │     └─ WM_MOUSE*/WM_KEY* → ControlClient ── 27184 ──▶ ControlServer → InputInjector
  └─ ControlClient / ControlMessage（独立于视频链路，可单独断开）

Android 控制 App (optional, direct mode)
  └─ Shizuku newProcess → same app_process server → 0.0.0.0:27183 + 27184
```

| 层 | 责任 | 状态 |
| --- | --- | --- |
| ADB 启动 | 推送 classes.dex jar、设备选择、可选 forward、启动/停止 app_process | 已在 Android 14 真机验证 |
| 传输 | 有线 loopback / 局域网直连 / App 直连、SCRC 帧解析、增量拆包 | 三种模式均已在真机验证 |
| 控制 | 27184 独立通道、动态 letterbox、`injectInputEvent`、滚轮 hover+scroll | 触摸/按键已真机验证；滚轮/旋转重算仅有单元检查 |
| 解码 | FFmpeg H.264 软解、YUV420p 拷贝 | 已在真机码流上验证 |
| 原生窗口 | owned WS_POPUP、坐标同步、D3D11 NV12 呈现、输入捕获 | 已编译并在 Windows 真机画面验证 |
| 捕获/编码 | Java 服务端虚拟显示 + MediaCodec surface 输入 | Android 14 真机验证；10–13 未验证 |
| 渲染真实帧 | YUV420p → NV12 → D3D11 shader | 已实现，1280x720 真机画面已验证 |

## 2. ADB 启动与传输模式

服务端必须由主机 ADB 启动，才能在设备上获得 shell 用户（UID 2000）。

有线模式：

```text
adb push <local-jar> /data/local/tmp/screencast-server.jar
adb forward tcp:27183 tcp:27183     # SCRC video
adb forward tcp:27184 tcp:27184     # input injection
adb shell "CLASSPATH=/data/local/tmp/screencast-server.jar \
  app_process /system/bin ... --port=27183 --bind-address=127.0.0.1"
```

无线/局域网模式：

```text
adb push <local-jar> /data/local/tmp/screencast-server.jar
# 不执行 adb forward
adb shell "CLASSPATH=/data/local/tmp/screencast-server.jar \
  app_process /system/bin ... --port=27183 --bind-address=0.0.0.0"
# Windows 直接连接 <phone-lan-ip>:27183
```

App 直连模式（桌面不执行任何 ADB 命令）：

```text
# 手机端：控制 App 通过 Shizuku 以 shell 身份运行同一个 jar
CLASSPATH=/data/local/tmp/screencast-server.jar app_process ... --bind-address=0.0.0.0
# Windows：只连接 <phone-lan-ip>:27183
# CastSession 在 direct 模式下不创建 AdbLauncher，CastSessionInfo.serial 为 null
```

- `Server.java` 的 `--bind-address` 默认 `127.0.0.1`；传 `0.0.0.0` 时监听所有
  接口。`ServerOptions` 会拒绝空或含空白的地址。
- 有线模式使用 `tcp:27183` forward，而不是 `localabstract:scrcpy`；因为服务端是
  设备本地 TCP socket。控制通道同样使用 `tcp:27184` forward。两条隧道由
  `AdbForwards`（`lib/src/host/adb_forward.dart`）以 `List<(local, remote)>` 统一
  管理：安装逐条尝试、单条失败不跳过后续（视频隧道失败则整个会话失败，控制隧道
  失败只降级为“无输入注入”）；停止时两条都尝试 `--remove`，单条失败仅记录，因此
  27184 的问题不会让 27183 的清理被跳过。无线/直连模式不创建 forward。
- 无线模式先通过 USB 执行 `adb tcpip 5555`，再 `adb connect <phone-ip>:5555`，
  之后的 push/启动/停止都使用 ADB/TCP serial。SCRC 视频仍走独立的 LAN socket。
- 实测发现 USB 拔线会触发 adbd 清理，终止旧的 app_process（即使使用 `setsid`
  脱离 session 也会被杀）。因此控制器在无线模式下把 SCRC 断开当作可恢复事件：
  `AdbLauncher.startExistingWireless()` 跳过 push/tcpip，直接用仍在线的
  ADB/TCP 重启服务端，然后重连局域网 socket。USB 拔线后会短暂中断再自动恢复。
- 停止无线会话时，如果 USB 仍在线，会 `adb usb` 切回 USB 并断开 TCP serial；
  如果 USB 已拔掉，则保留 ADB/TCP，以免在恢复过程中误杀传输。
- `app_process` 启动后把 stdout/stderr 接到 Dart；启动成功以
  `SCRC server listening` 行为准，超时 6 秒。
- 停止时用 `pkill -f com.example.screencast.server.Server`，并清理临时 jar。
  `process.kill()` 只杀本地 adb 客户端，不能替代远端 pkill。
- 无设备/多设备/未授权都返回明确错误；启动失败会清理临时 jar、forward 和进程。

## 3. SCRC 传输

协议未被修改：

- 4 字节魔数 `0x53435243`，大端。
- 4 字节 payload 长度，大端，1..16 MiB。
- payload 是单个 H.264 NAL，不含 Annex-B 起始码。

`CastTransportConfig` 统一决定客户端目标和服务端 bind：

| 模式 | 服务端 bind | 客户端 host | adb forward | 谁启动服务端 |
| --- | --- | --- | --- | --- |
| wired | `127.0.0.1` | `127.0.0.1` | 是 | 桌面 `AdbLauncher` |
| wireless | `0.0.0.0` | 用户填写的手机局域网 IP | 否 | 桌面 `AdbLauncher`（ADB/TCP） |
| direct | `0.0.0.0` | 用户填写的手机局域网 IP | 否 | 手机控制 App（Shizuku） |

`ScrcSocketClient` 接受可配置 `host`/`port`。Socket 读取使用
`ScrcPacketDecoder`，支持任意 TCP 分片与粘包。解析出的 NAL 进入
`NalDecodeQueue`（默认 180 个上限）。满队列时丢最旧项，避免解码慢导致无界内存；
真实产品应优先丢非关键帧并等待 IDR。

TCP_NODELAY 由 `TcpTransport` 统一在包装 socket 后设置（27183 与 27184 都生效），
连接日志打印 `[tcp] <host:port> TCP_NODELAY=true`；`--dart-define=
SCREEN_CAST_TCP_NODELAY=false` 用于对照测量（打印 false 并保留 Nagle）。真机实测
视频路径开关 Nagle 的端到端延迟差 4 ms（82 vs 78 ms，噪声内），详见归档基线。

## 4. Android 捕获与编码

`Server` 接受 viewer 后创建新的 `VirtualDisplayCaptureBackend`：

1. 配置 `MediaCodec` `video/avc`，颜色格式为 `COLOR_FormatSurface`。
2. 调用 `createInputSurface()`，编码器只使用 Surface 输入模式；代码中没有
   `dequeueInputBuffer()` / `queueInputBuffer()`。
3. 创建虚拟显示：
   - 优先反射隐藏静态
     `DisplayManager.createVirtualDisplay(name,w,h,displayIdToMirror,surface)`；
   - 失败后回退 `SurfaceControl.createDisplay()` + 显示事务。
   - Android 10–13 的公开 DisplayManager 实例方法需要 app Context，且
     AUTO_MIRROR 受签名权限限制；shell 进程实际使用 SurfaceControl 回退。
     Android 14+ 的隐藏静态镜像方法可用。
4. 启动编码器并循环读取输出：
   - 把 Annex-B 缓冲拆成单个 NAL；
   - 缓存 SPS/PPS，若 IDR 缓冲缺少参数集则先写缓存；
   - 每秒打印 SCRC payload 码率
     `[encoder] 1s bitrate=.. kbps bytes=.. frames=.. window=..ms`，并在
     `configure()` 后与 `INFO_OUTPUT_FORMAT_CHANGED` 时打印实际生效的
     `KEY_BIT_RATE / KEY_I_FRAME_INTERVAL / KEY_FRAME_RATE`；
   - 逐 NAL 写入现有 `ScrcPacketWriter`。
5. 停止时先释放虚拟显示，再 stop/release MediaCodec 和 input Surface。

### API 版本差异

- API 29–30（Android 10–11）：SurfaceControl 回退路径使用 `secure=true`。
- API 31+（Android 12+，含 14+）：SurfaceControl 使用 `secure=false`。
- API 34+（Android 14+）：
  - DisplayManager 静态镜像 API 是首选；
  - 若走 SurfaceControl，`setDisplayProjection()` 实际按 layer-stack rect
    resize 虚拟显示，`setDisplayLayerStack()` 的参数实际是 `displayIdToMirror`。
    代码对 14+ 传输出尺寸和 display id 0，对旧版本传源显示尺寸 + layerStack。
- API 30+ 才设置 `KEY_LOW_LATENCY`；配置失败会记录并重试一次去除该 key。

### 失败策略

DisplayManager 和 SurfaceControl 都失败时，异常带两个 cause 打印到 stderr 和
logcat，会话结束。**没有 MediaProjection 分支。**

### 真机结果（OPPO OPD2201 / Android 14 / API 34）

- 默认 `auto`：DisplayManager 创建 `VirtualDisplay displayId=3`，
  `c2.mtk.avc.encoder` 启用 `KEY_LOW_LATENCY=1`；抓取 244,407 字节 SCRC，
  FFmpeg 解出 14 帧 1280x720。
- 强制 `surfacecontrol`：API 34 新投影语义生效，SurfaceControl display 创建成功，
  FFmpeg 解出 11 帧 1280x720。
- 完整 Dart `AdbLauncher → ScrcSocketClient → FFmpeg` E2E 通过。
- **有线回退**：服务端 `--bind-address=127.0.0.1`，客户端
  `127.0.0.1:27183`，forward 生效，解出 3 帧 1280x720。
- **局域网直连**：手机 `192.168.1.134` / Windows `192.168.1.203` 同一 /24；
  服务端 `--bind-address=0.0.0.0`，**无 adb forward**，客户端直连
  `192.168.1.134:27183`，解出 3 帧 1280x720。
- **实际拔 USB**：ADB/TCP 仍在线；旧服务端被 adbd 清理后，控制器自动通过
  `startExistingWireless` 重启服务端，27183 恢复，画面从约 720 帧继续到 1328+
  帧，USB 保持拔出。
- 完整 Windows UI 无线模式：输入手机 IP 后自动启动，视频持续显示；无 forward。
- Android 10–13 没有设备可验证；该分支仅编译和代码审查。

![拔掉 USB 后无线自动恢复](assets/windows-wireless-usb-unplugged.png)

![Windows 局域网直连](assets/windows-lan-direct.png)

## 5. FFmpeg 解码

使用 FFmpeg 8.1.2 Windows x64 shared build 的：

- `avcodec-62.dll`
- `avutil-60.dll`
- `swresample-6.dll`（作为 avcodec 依赖预加载）

Dart FFI 只镜像 `AVFrame` 的稳定前缀：`data[8]`、`linesize[8]`、
`extended_data`、`width`、`height`、`nb_samples`、`format`。
`AVCodecContext` / `AVPacket` / `AVCodecParserContext` 保持 opaque——唯一例外是
D3D11VA 硬解需要的三个字段，通过 `ffmpeg_abi.dart` 的固定偏移访问
（`get_format` @192、`hw_device_ctx` @560、`codec_id` @24 用于运行时校验 ABI）。

### D3D11VA 硬解（首选路径）

```text
av_hwdevice_ctx_alloc(D3D11VA)
  → hwctx->device/.device_context = 插件渲染设备的 AddRef 指针
  → av_hwdevice_ctx_init
codec->get_format = 只返回 AV_PIX_FMT_D3D11 的回调
codec->hw_device_ctx = 该 hw device 引用（所有权转移）
avcodec_open2
  → avcodec_receive_frame: frame.format == 171
  → data[0] = ID3D11Texture2D*, data[1] = slice index
  → 同步 C 导出 screencast_hw_copy_texture
      → CopySubresourceRegion(video_texture, src, slice) + InvalidateRect
```

- 复用渲染设备意味着零跨设备拷贝；`AVD3D11VADeviceContext` 会接管引用，因此插件
  导出的 acquire 函数负责 `AddRef`。
- 拷贝在 `av_frame_unref` 之前完成，所以不需要额外的 `AddRef`/`Release` 生命周期管理。
- 共享设备不可用时（例如测试环境没有插件）创建独立设备并打印
  `[hwaccel] using separate device, cross-device copy required`，随后自动回退软解；
  若运行中遇到跨设备纹理，则用 `av_hwframe_transfer_data` 下载成 NV12 走软解上传。
- 回退是双向的：任何一步失败都不会终止会话，`Nv12FrameWriter` + 双缓冲路径保持可用。
- 结构体偏移由 `tool/ffmpeg_abi_dump.c` 生成；运行时校验 `codec_id`，不匹配就只用软解。

### 为什么没有用 av_parser

最小实现直接按 VCL NAL 发送 packet；为了绕开 FFmpeg parser 在分包边界的行为，
每个 packet 前会补最新 SPS/PPS 的 Annex-B 起始码。这个策略对现有 demo 码流有效，
已在单测中解出 320x180 的 15 帧。

限制：

- 假定一帧一个 VCL NAL；多 slice 帧需要做访问单元聚合。
- 未处理 PTS/B 帧重排、分辨率切换、AVCC 格式。
- 硬解路径只接受 `AV_PIX_FMT_D3D11`；软解只支持 `yuv420p` / `yuvj420p`，
  其他像素格式会明确报错。
- 解码是同步的，运行在 Dart UI isolate；硬解已把每帧成本降到一次
  `CopySubresourceRegion`，剩余 UI 线程开销是 `avcodec_receive_frame` 与原生绘制。

测试样例由 FFmpeg 生成，存放在 `test/assets/sample_320x180.h264`。

## 6. 桌面原生渲染

### 为什么不是真正的 PlatformView

Flutter Windows embedder 的 `PlatformViewPlugin` 目前没有实现真实的平台视图创建
（工厂/实例化方法为空实现）。Flutter framework 也没有 Windows 的
`AndroidView`/`UiKitView` 等价注册路径。

第一次真实验证时，`WS_CHILD` 子窗口虽然创建成功并在预览区域内，但被 Flutter 的
合成层遮挡，截图中不可见。随后一版改为宿主窗口拥有的 popup overlay；**当前实现**
是一个**独立顶层窗口**，Flutter 窗口只保留控制/设置/状态：

- 原生插件通过 `PluginRegistrarWindows::GetView()->GetNativeWindow()` 取得
  Flutter 视图 HWND，仅用于选择初始居中的显示器与位置。
- 创建**无 owner** 的 `WS_POPUP | WS_THICKFRAME` 窗口（`WS_EX_APPWINDOW`，出现在
  任务栏）。`WM_NCCALCSIZE` 返回 0，客户区覆盖整个窗口；`WM_NCHITTEST` 手工给出
  顶部 40px `HTCAPTION` 拖拽区与 8px 缩放边，其余 `HTCLIENT`。
- 初始尺寸按视频宽高比：横屏 640×360、竖屏 360×640 逻辑像素（按 DPI 缩放），
  居中于 Flutter 窗口所在显示器；`WM_GETMINMAXINFO` 限制 240×135。
- 双击拖拽区或 F11 切换全屏（去掉 `WS_THICKFRAME`、`SetWindowPos` 覆盖当前显示器），
  Esc 退出并恢复原样式/位置/尺寸；`WM_CLOSE` 只隐藏窗口，不销毁、不断开会话。
- 左键按下 `SetFocus`，键盘事件先经过窗口快捷键（F11/Esc）再走注入路径。
- 托盘（`windows/tray_icon.cpp`）：`Shell_NotifyIcon` 注册在主窗口上，主窗口
  `WM_CLOSE` 改为隐藏 + 安装托盘图标；右键菜单「显示主窗口 / 显示视频窗口 / 退出」
  用 `TrackPopupMenu(TPM_RETURNCMD)` 直接分发；图标绿/灰两态，tooltip 由 Dart
  `updateStatus` 每秒推送。
- Dart 的 `NativeVideoSurface` 不再计算 bounds，只负责创建/显示/隐藏、输入开关与
  托盘状态；原预览位置改成占位卡 + 「显示视频窗口」按钮。
- 原生 `D3D11Renderer` 使用 `D3D11CreateDeviceAndSwapChain` 创建交换链；设备创建失败
  时用 GDI 纯色 fallback。Dart 标题显示实际后端（`Win32 · D3D11` / `Win32 · GDI`）。
- 视频路径不再清屏占位，而是：

  ```text
  DecodedFrame (YUV420p)
    → Dart Nv12FrameWriter 写入 native-mapped NV12 staging texture（两张轮换）
    → Unmap(index) + CopyResource
    → DXGI_FORMAT_NV12 video texture
    → R8 / R8G8 per-plane SRV + fixed BT.601 pixel shader
    → swap-chain render target
  ```

  原生共四个纹理：两张 NV12 staging upload texture、NV12 shader-resource video
  texture、swap-chain back buffer/render target。
- `configureFrame` 一次性映射两张 staging texture，MethodChannel 返回两组
  `{index, pointer, rowPitch}`；Dart 通过 `dart:ffi` 直接写 Y/UV，唯一一次 CPU
  拷贝发生在 Dart→native 映射内存。像素数据不经过 MethodChannel。
- 双缓冲与丢帧（`lib/src/windows/nv12_frame_buffer.dart`）：`Nv12DoubleBuffer`
  在两张 staging texture 间轮换，写入后**立即返回**；`presentFrame` 异步执行。
  写入只落在没有在呈现的那张纹理上，因此写入与呈现不争用同一块内存；只有轮到的
  纹理仍在途（或两张都在途）时当前帧才丢弃（`droppedCount++`），不排队。这样解码
  循环不再等待 GPU 拷贝和 Present，只付出一次 CPU 拷页。
  实测（60Hz 源，60 秒）：解码/上传各 ≈60 帧/秒，累计丢弃 ≈0.7%。
- `presentFrame` 只处理被选中的索引：`Unmap(index) → CopyResource → Map(index)`
  顺序不变；Map 后指针可能变化，新指针回填到该索引对应的 `Nv12UploadTarget`。
  原生记录最近呈现的索引（`displayedIndex`），另一张纹理全程保持映射。
- shader 用 `SV_VertexID` 生成覆盖客户区的 quad，YUV→RGB 使用固定 BT.601
  limited-range 矩阵。
- `CastController` 每秒采样一次（`CastFrameStats`），打印
  `[cast] 1s decoded=.. uploaded=.. dropped=.. | total ...`，并把
  `framesDecoded / framesUploaded / framesDropped / framesPerSecond` 写入
  `CastSessionState`，预览栏显示 `N frames · N fps · N dropped`。
- 第一帧之前清青绿色占位；第一帧之后 `has_frame_` 保持为 true，无新帧时重绘上一张
  video texture，不清屏；WM_PAINT、最小化恢复和重新调整窗口尺寸也保留最后一帧。
- NV12 是单个 resource 的 Y/UV plane，因此不是两个独立 subresource；Y 用
  `R8_UNORM`、UV 用 `R8G8_UNORM` 两个 per-plane SRV 采样。使用
  `Texture2DArray` 选择 NV12 plane 在 NVIDIA/WARP 上不可移植。

### 已验证

- Visual Studio Build Tools 2026（MSVC v143 + Windows SDK
  10.0.26100，无 IDE）编译 `screen_cast_demo.exe` 和
  `screen_cast_windows_plugin.dll` 成功。
- 应用启动后 overlay 可见，标题显示 `Win32 · D3D11`。
- 移动宿主窗口后 overlay 跟随（位置变化与宿主一致）。
- 普通前台窗口可以盖住 overlay，说明没有错误地使用全局 topmost。
- Android 14 真机 1280x720 画面真实显示在 D3D11 NV12 纹理上，UI 连续计数
  1400+ 帧；颜色正常、无平面错位。
- 最小化/恢复和 WM_PAINT 后仍显示最后一帧，没有清屏闪烁。

![Windows D3D11 NV12 live preview](assets/windows-d3d11-video-preview.png)

### 已知合成限制

- overlay 不受 Flutter 的圆角、阴影和模态遮罩约束；Dart 通过裁剪到滚动视口和
  发送可见交集来减少问题，但 UI 不应把关键文字/按钮放在视频区域内。
- 独立顶层窗口的截图/录屏合成结果取决于工具。
- 这不是一个可随 widget 变换（旋转、缩放动画、透明度）的 PlatformView。
- 布局断点切换时 `CastPreview` 使用 `GlobalKey` 保留 State，避免 `NativeVideoSurface`
  被重建；若预览本身被移除或 surface 真正 dispose，原生 renderer 会重新初始化，
  设备端没有立即产生新帧时会暂时显示占位色，直到下一帧到达。
- 若需要这些能力，改用 Flutter Texture + D3D11 shared texture 更合适。

## 7. Android 控制 App / Shizuku 集成

[`android-app/`](android-app/) 是普通 Android 应用，不含 ADB 实现，也不尝试自我提权。

```text
Screen Cast Controller (normal app)
  ├─ MainActivity ── permission UI ──┐
  ├─ ScreenCastTileService ──────────┤
  │                                  └─ CastStateStore (SharedPreferences)
  ├─ ServerLauncher (Kotlin coroutines)
  │    ├─ ensure jar: assets -> /data/local/tmp
  │    ├─ IShizukuService.newProcess("app_process ...")
  │    └─ waitForTimeout / destroy / binder-death handling
  └─ ShizukuProvider (user-authorized shell binder)
```

- 权限来源：Shizuku。用户通过 Android 11+ 无线调试激活 Shizuku；App 只请求授权，
  不自带 root/ADB。MainActivity 处理 `pingBinder`、授权回调、binder death/receive。
- 捕获方式仍是现有 `app_process` + 隐藏虚拟显示 API；不使用 MediaProjection。
- `ServerLauncher` 从 app assets 流式安装 `screencast-server.jar` 到
  `/data/local/tmp`，以 shell 身份执行现有类名/端口和
  `--bind-address=0.0.0.0`，stdout/stderr 写入设备日志。
- Quick Settings：
  - 点击直接调用同一个 `ServerLauncher` 启动/停止；
  - 长按由系统通过 `QS_TILE_PREFERENCES` 打开 `MainActivity`；
  - manifest 声明 `BIND_QUICK_SETTINGS_TILE` 和 `QS_TILE` intent filter。
- 状态同步：`CastStateStore` 是**进程内单例**（`getInstance`）+ SharedPreferences。
  Activity / Tile / 前台服务 / ServerLauncher 共用同一个实例和同一份监听器列表，
  状态变更（`UNAUTHORIZED / STOPPED / STARTING / RUNNING / STOPPING / ERROR`）立即
  推给所有组件。早期每个组件各自 `new CastStateStore(...)`：SharedPreferences 文件
  虽共享，但写操作只通知自己实例的监听器，于是 App 界面要切后台再回来才更新，磁贴也
  一直停在“启动中/停止中”。
- Shizuku 管理器包名是 `moe.shizuku.privileged.api`（`<queries>` 与
  `SHIZUKU_PACKAGE` 都按此声明）；写成 `moe.shizuku.manager` 会让“打开 Shizuku”
  永远报“未找到 App”。
- 异步性：Shizuku 13.1.5 没有 libsu 的 `Shell.Result`；实现使用实际存在的
  `IShizukuService.newProcess`，所有 binder/进程操作运行在 IO 协程，有限命令用
  `IRemoteProcess.waitForTimeout`，并有 `withTimeout` 与 binder-death 处理。
- 前台服务：`ScreenCastForegroundService`（`specialUse`）承载服务端生命周期，主界面和
  磁贴都经它启停；`CastStateStore` 单例是 Activity/Tile/服务共享的状态源。
- 桌面端已有 `direct` 传输模式：不执行任何 ADB 命令，只连接 `<手机 IP>:27183`。
- 一键投送：服务启动后由 `DiscoveryBroadcaster` 向局域网广播发现包，详见第 13 节。

![Android 控制 App / Shizuku 集成](assets/android-shizuku-integration.png)

## 8. 生命周期

启动：

```text
idle → starting
  CastTransportConfig.validate
  wired: push -> adb forward -> app_process -> SCRC
  wireless: push -> adb tcpip 5555 -> adb connect -> ADB/TCP app_process
  FfmpegDecoder.open
  ScrcSocketClient.connectWithRetry (127.0.0.1 or phone LAN IP)
  attach packet listener + decode worker
→ running
```

运行中：

- 每个 NAL → queue → decode → `DecodedFrame` → NV12 上传 → UI 计数/状态。
  解码循环只等 CPU 拷贝；`presentFrame` 异步执行，上一帧未完成时当前帧被丢弃并计数
  （不再覆盖正在 remap 的映射指针）。
- 无线模式下 SCRC socket 关闭时，控制器进入 `starting`：
  - 清理旧 socket/decoder，保留 ADB/TCP；
  - 等 600 ms，`CastSession(existingTcpSerial: ...)` 调
    `AdbLauncher.startExistingWireless()`；
  - 不重新 push/jar，不重新 tcpip，直接通过 ADB/TCP 启动服务端；
  - 重连 27183，成功后回到 `running`，视频继续。
- 有线模式 socket 关闭时仍直接报告错误，不自动恢复。

停止/失败：

- 停止 socket、取消订阅、关闭队列、等待解码 worker、释放 FFmpeg 上下文。
- pkill 远端进程、删除临时 jar；仅对实际安装过 forward 的会话删除 forward。
- 无线停止时如果 USB serial 仍在线，执行 `adb usb` 并断开 TCP serial；否则
  保留 ADB/TCP（例如恢复期间 USB 被拔掉）。
- 启动过程中任一步失败都会回滚 ADB 资源。

## 9. 控制通道（输入注入）

视频（27183，SCRC）与输入（27184）是两条完全独立的 TCP 链路，断开其中一条不会影响
另一条。`ControlServer` 在 `Server` 构造时绑定端口、在 `serve()` 里用守护线程 accept，
每个连接再起独立线程读帧；`InputInjector` 负责坐标映射与 `injectInputEvent`。

帧格式：`1 字节类型 + 4 字节大端长度 + payload`。

| 类型 | 含义 | payload |
| ---: | --- | --- |
| 0x01/0x02/0x03 | 触摸按下/移动/抬起 | 两个大端 float32，归一化 0.0–1.0 |
| 0x04 | 滚轮 | 大端 int32：Windows `GET_WHEEL_DELTA_WPARAM` 原值（120 的倍数，正数=向前/向上滚） |
| 0x05/0x06 | 按键按下/抬起 | 大端 int32，Android keycode |
| 0x10 | 停止服务（App → 服务端） | 空 payload；服务端 `System.exit(0)`，旧服务端忽略该类型 |

`0x10` 解决的是“Shizuku 断开后无法停止服务”：捕获进程是 shell 进程，App 杀不掉它，
但可以请求它自己退出；App 随后探测 27184 是否关闭，只有端口真的关了才报告成功。

滚轮注入：`WheelMapping.axisVScrollForWindowsDelta()` **同号直传**（真机实测：
`+120` 让列表向上滚、`-120` 向下，Windows 与 Android 的符号一致；此前的取反映射会
让滚动方向相反）。Android 按指针位置路由 `ACTION_SCROLL`，因此注入前先发
`ACTION_HOVER_MOVE` 到最近一次 0x02 移动的坐标（无移动样本时回退到显示中心），再在
同一坐标发 `ACTION_SCROLL`；两者都用 `SOURCE_MOUSE` + `TOOL_TYPE_MOUSE` 的
`PointerCoords`（`setAxisValue` 只能这样设置）。日志先打印 `rawDelta`、换算后的
`axisVScroll` 和悬停坐标来源。

坐标映射分三段（服务端逐条打印，便于核对）：

```text
normalized (0..1)
  × video 尺寸（编码器输出）        → video
  去掉动态 letterbox（按 fit 计算的内容区与边距）
  再缩放到源显示真实尺寸            → display  （真正注入的坐标）
```

letterbox 不再是常量：`VirtualDisplayCaptureBackend` 每次创建虚拟显示后，用
`options.width/height` 和 `DisplayMetadata.realSize()`（`Display.getRealSize()`
语义，回退到 natural mode → `mode.getPhysical*` → logical）重算
`LetterboxGeometry`，写入 `Server` 持有、`ControlServer`/`InputInjector` 共享的
`InputMapping`（volatile）。`scale = min(videoW/displayW, videoH/displayH)`，
`content = round(display × scale)`，`offset = (video - content) / 2`，映射时先减边距、
按内容区 clamp 再乘以 `(display - 1)`。

同一次会话内的旋转：`InputInjector` 在每次注入前调用
`DisplayMetadata.currentState()`（`getRealSize` + `getRotation`，静默读取），与上次
记录的 `DisplayState` 不同就重算 `InputMapping` 并打印
`Input letterbox updated (rotation): ...`，同时把滚轮悬停锚点复位到新的显示中心。
真机实测：竖屏 514×720/offset 383 → 旋转 → 横屏 1008×720/offset 136，无需重连。

方向对齐：`Display.getRealSize()` 返回面板自然方向（例如 2000×2800），而镜像内容
跟随逻辑方向（例如 2800×2000）。`LetterboxGeometry.orient()` 在两者方向不一致时
交换宽高，既保持已验证的参考映射，又让旋转后的 `logicalWidth/Height` 变化真正体现
到 letterbox 上（纯函数，`CaptureCoreCheck` 覆盖三种情况）。

Windows 侧：覆盖窗口在 `input_enabled_` 为假时 `WM_NCHITTEST` 返回 `HTTRANSPARENT`
（保持点击穿透，不影响 Flutter 手势）；控制连接建立后返回 `HTCLIENT`，捕获鼠标
移动/按下/抬起/滚轮与 `WM_KEYDOWN/UP`，左键按下时 `SetFocus` 以接收键盘。
滚轮的 `GET_WHEEL_DELTA_WPARAM` 原值直接放进 int32 payload（不取反、不除以 120），
符号翻转只发生在服务端。
归一化后经 `MethodChannel("controlEvent")` 交给 Dart，由 `ControlClient` 发送。
键位映射：方向键 → DPAD，Enter → 66，Esc → 4（BACK），Backspace → 67，Space/Tab。

注入使用隐藏的 `InputManager.injectInputEvent`（需要 shell 的 INJECT_EVENTS）。
Android 14 上 `InputManager.getInstance()` 在 app_process 中抛空指针，实现回退到
`ServiceManager.getService("input")` + `IInputManager$Stub.asInterface`，实测可用。
控制 socket 断开只记日志并回到 accept 循环，视频会话继续。

## 10. 记录层加密

加密是独立的一层，不进入任何协议解析代码：

```text
Socket ── TcpTransport ── SecureChannel(PskCipher) ── ScrcPacketDecoder / ControlMessage
                           │
                           ├─ send: 按 64 KB 切分 → 每条记录独立 nonce → AES-GCM
                           └─ incoming: 按长度前缀切记录 → 解密 → 输出明文块
```

记录格式（Dart 与 Java 完全一致）：

```text
+----------------+----------------+------------------+-----------+
| length: uint32 | nonce: 12 bytes| ciphertext       | tag: 16 B |
+----------------+----------------+------------------+-----------+
        big-endian    每记录随机       明文等长           GCM tag
```

`length` 覆盖 `nonce + ciphertext + tag`；GCM 自身无法在字节流中界定记录边界，
所以长度前缀是必需的。单条记录明文上限 64 KB，更长的 `send` 会被切片。

- 密钥：`PskCipher`（16/24/32 字节 → AES-128/192/256）。服务端 `--psk-hex`，
  桌面 UI 输入，自动启动用 `SCREEN_CAST_PSK_HEX`。
- 空密钥：`SecureChannel` 透传并打印 `WARNING ... PLAINTEXT`；服务端同样打印警告。
- 失败语义：SCRC 方向解密失败会让视频链路报错退出（不产生花屏）；控制方向失败
  只表现为“控制已断开”，视频继续。
- 不提供：前向保密、重放保护、流量填充、PSK 协商。这些留到产品化阶段。

## 11. 安全与边界

- 仍通过 ADB 推送和启动服务端；没有 Android 网络鉴权。
- SCRC 无认证、无加密、无完整性校验。
  - wired：只绑定 loopback，通过 adb forward 使用；
  - wireless：绑定 `0.0.0.0`，同局域网可路由主机都能尝试连接 27183。仅限可信
    局域网，产品化前必须增加鉴权和加密。
- **27184 控制通道同样无认证**：能连上就能注入触摸/按键，风险高于只读视频流；
  产品化前必须鉴权，并在不需要控制时关闭该端口。
- 无线模式临时启用 **ADB/TCP 5555**；ADB 自身需要 RSA 授权，但 TCP 端口暴露在
  局域网，产品化前应关闭或限制来源。停止且 USB 在线时会切回 USB。
- Android 控制 App 只是普通应用，通过 Shizuku 获得用户授权的 shell binder；
  App 本身没有 root、ADB 或自我提权代码。Shizuku 未激活时状态应为“未授权”。
- jar 推送到 `/data/local/tmp`，仅用于开发调试。
- 不使用 MediaProjection，也不需要屏幕捕获授权。
- FFmpeg 为 GPLv3 共享构建；发布应用前须确认许可证兼容性。
- 当前 Windows owned overlay 方案需要自行管理合成、焦点和 DPI，不是稳定的产品级
  渲染层。

## 12. 待办

1. 在 Android 10–13 真机补充分支验证（Android 14 已通过）。
2. ~~NV12 上传性能优化~~ —— 已完成双 staging texture 轮换、写入后立即返回、
   present 未完成时丢帧并计数；每秒统计打印到 debug 日志。剩余：present 失败后的
   整体重建、按队列深度自适应丢帧、以及拔网线的真机复跑。
   无线基线（60 秒滚动动画、120 Hz 面板）：解码中位 ≈120 帧/秒、上传 ≈76、丢弃 ≈45；
   端到端延迟中位 82 ms（`TCP_NODELAY=true`）/78 ms（`false`，差值在噪声内）；
   ping 100 包 0% 丢包、RTT avg 16.3 ms；码率实测 ≈17 Mbps（配置 8 Mbps）。
   诊断实验：真正锁到 60 Hz 后（`low_power=1`，`settings peak_refresh_rate` 在
   ColorOS 上无效）丢弃降到 1.1%；编码器只支持 VBR（四个 AVC 编码器均
   `CBR=false/CQ=false`），CBR 请求被静默忽略，60 fps 输入下同一 VBR 配置自然
   收敛到 ≈8 Mbps，超调来自 120–144 fps 输入；有线同方法延迟 63 ms，
   无线净值 19 ms（Wi-Fi 开销小，主成分是本地处理与显示节奏）。
3. 访问单元聚合、PTS、多 slice、旋转/尺寸变化、重连与密钥帧恢复。
4. 全范围（`yuvj420p`）颜色矩阵或从码流提取 color range/metadata；当前 shader
   固定 BT.601 limited-range。
5. 评估双窗口合成/截图/模态遮挡的产品级风险，必要时改为 Flutter Texture。
6. ~~前台服务 + 通知~~ —— 已实现并在真机确认前台态、`specialUse` 类型与带 action
   的常驻通知；`ServerLauncher` 未改动。
7. ~~控制通道~~ —— 已实现并在真机确认触摸/按键注入（含 BACK 生效）。本轮补齐并
   **真机验证**：滚轮（悬停定位 + 同号 `AXIS_VSCROLL`，方向按实测修正）、有线模式
   第二条 forward、同一次会话内旋转后的动态 letterbox 重算与横竖屏点击命中（直连
   模式）；仍缺多控制端并发与锁屏/系统弹窗注入验证。
8. ~~记录层加密~~ —— 已实现 `Transport` / `SecureChannel` / `PskCipher`，SCRC 与
   控制协议零改动，AES-GCM 已在真机跑通。仍缺：重放保护、密钥轮换、PSK 协商。
9. 补充运行时验证：前台服务通知上的停止、ColorOS 跳转、磁贴点击停止运行中的服务、
   binder death、启动超时。

> 已完成：Android 控制 App（Shizuku 授权、启停、QS 磁贴、前台服务外壳）、桌面
> `direct` 传输模式、27184 控制通道与 PSK + AES-GCM 记录层；主链路已在 OPPO
> Android 14 + Windows 上跑通（1280x720，加密会话 742+ 帧，输入注入生效）。

## 13. 一键投送（发现 + 自动连接）

发现是**会话之外的旁路**：UDP 27185 只负责让 PC 知道“某台手机现在在哪个地址提供服务”，
真正的视频/控制仍然是 27183/27184 上的 TCP + 既有记录层。因此 SCRC、控制协议、
`SecureChannel` 记录格式、D3D11 渲染管线都没有改动。

```text
Phone (Shizuku app, shell UID 2000)              Windows host
──────────────────────────────────               ────────────
Server started / QS tile tapped
  └─ DiscoveryBroadcaster.announce()
       NetworkInterface.getNetworkInterfaces()
         skip loopback / !up / link-local / no broadcast
       socket.broadcast = true
       for each iface: send JSON to iface.broadcast:27185
       5 rounds × 1 s, fire-and-forget
                    │ UDP 27185
                    ▼
                                        CastOfferListener
                                          RawDatagramSocket.bind(anyIPv4, 27185,
                                                                 reuseAddress: true)
                                          ├─ CastOffer.tryParse (type/ports/IPv4)
                                          ├─ LocalSubnetTable.accepts(source)
                                          ├─ offer.ip == source.address
                                          └─ CastOfferEvent
                                                ▼
                                        AutoConnectPolicy
                                          ├─ state.autoConnect && !running && !busy
                                          ├─ 8 s per-address cooldown
                                          ├─ pskRequired && psk empty → 报错，不连接
                                          └─ CastController.connectToOffer()
                                                └─ CastTransportMode.direct
                                                     → 现有 CastSession 链路
```

### 子网判定

`NetworkInterface.list` 只给地址，不给掩码。Windows 上通过 `dart:ffi` 调用
`iphlpapi!GetIpAddrTable`（`MIB_IPADDRROW`：`dwAddr` / `dwMask`，均为网络序 DWORD），
把掩码转成前缀长度；掩码必须是一段连续的前导 1，否则该条目被丢弃。读不到掩码
（非 Windows、FFI 失败）时按 /24 处理——这只会让判定更严格。

判定顺序：来源必须是 IPv4、非 loopback、非 169.254/16，且落在任一本地子网内；
同时 `offer.ip` 必须等于 UDP 来源地址。两条同时满足才会产生 `CastOfferEvent`。

### 状态与可见性

- `CastSessionState` 新增 `autoConnect`（开关）、`controlPort`（来自 offer 的端口）、
  `discoveryStatus` / `discoveryError`（面板最后一行发现状态）。
- `CastController.connectToOffer()` 把 UI 切到 `direct` + offer 的地址/端口，再用
  `pskForOffer()` 解析本次会话的密钥（`pskRequired=false` → 空密钥）。
- 自动连接成功后由页面调用 `showVideoWindow`；失败或已连接会话随后报错时调用
  `showMainWindow`（MethodChannel `showMainWindow`），确保 PSK 之类的问题不会静默
  留在托盘里。

### 磁贴状态自愈

`CastStateStore` 只是缓存：服务进程被外部杀掉（Shizuku 重启、`pkill`、ColorOS 回收）后
它可能继续声称 RUNNING，磁贴显示“运行中”，点一下会走停止分支（什么也没停）。要让磁贴
行为可预测，四个环节都要处理：

1. **冷进程授权等待**：磁贴把被杀掉的进程重新拉起来时 Shizuku binder 尚未 attach，
   `checkAuthorized()` 会立即失败。`awaitAuthorization()` 在 binder 缺席时最多重试
   10×150 ms，只有 binder 存在但权限缺失才判定未授权。
2. **点击前以 OS 为准**：`ServerProbe` 对 `127.0.0.1:27184` 做 400 ms TCP 探测，只有
   确实有监听才走停止分支，否则启动。探测控制端口而不是 27183，是因为连视频端口会让
   服务端创建一次虚拟显示。
3. **进程重启时对齐缓存**：`ServerLauncher` 初始化时用同一个探测把缓存改成
   `RUNNING`/`STOPPED`，并且与 start/stop 共用一把互斥锁，避免和启动过程互相覆盖。
4. **结果以探测为准**：停止后等待控制端口关闭（最多 ~2.4 s）再写最终状态，避免
   `pkill` 偶发报错把“已停止”写成“异常”；`ACTION_STOP` 在启动失败/进程已消失时直接
   `stopForeground + stopSelf`，粘性重启不再静默拉起第二个服务端。
   前台服务 watchdog 每 2 s 检查一次，进程消失且端口关闭就置 `ERROR` 并撤掉通知；
   `MainActivity.onResume` 也做一次同样的探测。

启动路径另外去掉了“先写 STOPPED”的额外刷新，磁贴不会再有“停止 → 启动中 → 运行中”
的跳变。App 进程刚被杀时 SystemUI 可能还显示缓存的旧标签，进程拉起后
`onStartListening` 会按真实状态重绘。

### 验证边界

- 已真机跑通：磁贴点击 → `DiscoveryBroadcaster` 广播 → PC 收到 offer → 自动 direct
  连接 → 视频窗口出现（常规 **1.36 s**、进程被杀后的冷启动 **1.19 s**，持续解码、
  0 丢弃）；`pskRequired` 两种分支、PC 未运行时广播无副作用。
- 已真机验证状态共享（2026-11-17，截图确认）：App 内点“启动服务”→“状态：运行中”
  立即刷新（不需要切后台）；磁贴启动后变紫并显示“投屏 · 运行中”，此时打开 App 直接
  显示运行中；App 在前台时下拉磁贴点“停止”，回到 App 立即变成“状态：已停止”；
  冷启动的磁贴显示“已停止”而不是误报“未授权”。
- 已真机验证启停：连续两轮 启→停→启→停，状态分别为 `RUNNING`/`STOPPED`，服务端
  `app_process` 随之出现/消失，PC 会话随之连接/断开；外部杀掉服务进程后 watchdog 在
  ≤2 s 把状态改为 `ERROR`；`am force-stop` 残留的 `RUNNING` 会被探测对齐为 `STOPPED`。
- Shizuku 管理器包名已按 `pm list packages` 实测修正为 `moe.shizuku.privileged.api`，
  `cmd package resolve-activity` 能解析到 `moe.shizuku.manager.MainActivity`；
  未在“Shizuku 未运行”状态下实点“打开 Shizuku”（会中断当前 Shizuku 会话）。
- offer 无签名：同网段可伪造。产品化需要签名或一次性的用户确认。

## 14. 内容区探测 / 队列恢复 / 帧率可观测性（2026-11 合并）

**内容区探测**：`FfmpegDecoder` 不再按固定周期 readback，改为触发式——
`reason=initial`（首帧）、`reason=size-change`（解码帧宽高变化）、`reason=resize`
（原生窗口 `WM_EXITSIZEMOVE` → `windowResized` → `CastController.requestContentProbe()`），
另有 `reason=timer` 的 60 秒安全兜底。无变化时不做任何 readback；日志
`[content] probe: reason=... rect=...`（rect 为 `none` 表示整帧）。未实现“只采样边缘
8 行/列”的原生导出：384px 量级的黑边宽度无法由 8 列样本测出，且新增 ABI 的收益低于
触发式探测已经消除的停顿。

**NAL 队列**：`NalDecodeQueue` 溢出时清空积压并进入 WAIT_IDR，只保留 SPS/PPS 并丢弃
其余 NAL，直到 IDR 到达后按 `SPS/PPS → IDR` 重新入队；3 秒超时只打印
`[decode] IDR wait timeout (3s), still waiting`，不重连、不退出等待。渲染器保留最后一帧，
所以可见结果是冻结而不是花屏。

**帧率可观测性**：`D3D11Renderer::PresentSwapChain()` 每秒统计 present 次数，
`getStatus` 返回 `presentFps`；托盘 tooltip 为
`已连接 · W×H · 解码 Nfps · 呈现 Mfps`，Flutter 状态栏显示同一行并在
`解码 − 呈现 > 20%` 时提示“限制 60 帧”。解码 fps 仍来自 `CastFrameStats`。

**限制 60 帧**：`ServerOptions --target-fps=<0..240>`（默认 0）。服务端在虚拟显示创建后
反射调用 `Surface.setFrameRate(n, 1, 0)`，5 秒后打印
`[encoder] target-fps=60 actual=... (hint applied|hint ignored by ROM)`；被忽略时不做
应用层丢帧。PC 开关持久化在 `%APPDATA%\ScreenCast\config.json`，只对由桌面启动服务端的
wired/wireless 生效。真机实测：OPPO ROM 忽略提示（98fps @120Hz），系统设置切
“标准刷新率（60 Hz）”有效（60–61fps，`mActiveModeId=4`），UI 文案据此引导用户去设置。

## 15. Shizuku 断开后的会话存活（2026-11-17）

**问题**：Shizuku binder 死亡时，`ServerLauncher` 的监听把状态写成 `ERROR`，前台服务的
看门狗又用 `serverLauncher.isRunning()` 判断存活；binder 没了 → 判定“进程消失” →
前台服务自己 `stopSelf()`，`app_process` 失去前台保护，投屏变卡。

**改法**：

- 服务对象不再常驻持有 Shizuku 引用，`ServerLauncher` 只在 start/stop 时惰性取用；
- 看门狗改为每 2 秒 TCP 探测 `127.0.0.1:27184`：端口在 → 保持；端口关 → `STOPPED`
  并撤通知；
- `ServerLauncher` 的 binder-death 回调只把状态改成 `SHIZUKU_LOST`；`start()` 遇到
  已在监听的服务端会直接“接管”，不要求 Shizuku；
- 停止路径：destroy 句柄 → Shizuku `pkill` → 控制通道 `0x10`（让服务端 `System.exit(0)`）；
  成功判据只看 27184 是否关闭。所以 Shizuku 断开、或服务端由桌面经 ADB 启动时，
  磁贴/通知/App 的停止依然有效；磁贴用 `stopService()` 收尾，避免后台
  `startService` 被 `BackgroundServiceStartNotAllowed` 拒绝；
- 磁贴不再呈现 Shizuku 状态：只镜像服务状态（含 `SHIZUKU_LOST` 显示为“运行中 /
  Shizuku 已断开”）；App 未运行时点磁贴会在后台起前台服务，启动成功才更新磁贴。

真机验证（Shizuku 未运行时）：
- `dumpsys activity services` 中 `ScreenCastForegroundService` 的 `isForeground=true`
  在 10 秒后仍成立（没有因为 Shizuku 断开而退出）；
- `app_process` 的 `oom_score_adj=-1000`；
- PC 端自动连接后 `[cast] 1s decoded=12 uploaded=12 dropped=0`，会话持续；
- App 显示“状态：Shizuku 已断开”+“投屏仍在运行；停止服务依然可用”，磁贴显示
  “投屏 · 运行中 / Shizuku 已断开”；
- 点磁贴停止：服务端仍在监听 → 状态 `SHIZUKU_LOST` + Toast，不会假装已停止；
- 外部 `pkill` 服务端后看门狗把状态改为 `STOPPED` 并撤掉通知。

## 16. 桌面会话与磁贴同步（2026-11-19）

磁贴的标签只来自 App 的 `CastStateStore`；桌面经无线 ADB 启动服务端时 App 完全不知情，
所以磁贴一直显示“已停止”，即使 PC 已经在投屏。另外磁贴的校准逻辑只会把
“运行中→已停止”，不会把“已停止→运行中”。

改法：

- `AdbLauncher` 在服务端就绪后（以及停止后）执行
  `am broadcast -a com.example.screencast.action.SERVER_STARTED|SERVER_STOPPED
  -n com.example.screencast.controller/.CastStateReceiver`；
- `CastStateReceiver`（`android:permission="android.permission.DUMP"`）更新状态存储，
  并调用 `TileService.requestListeningState()` 强制 SystemUI 重新绑定磁贴；
- 磁贴的 `reconcileFromProbe()` 双向校准：监听中且状态是
  `STOPPED/ERROR/UNAUTHORIZED` → `RUNNING`；未监听且状态是
  `RUNNING/SHIZUKU_LOST/STARTING` → `STOPPED`；面板打开期间每 2 秒复核一次。

真机验证：桌面自动连接前 `STOPPED`，连接后（桌面自己起的服务端）变 `SHIZUKU_LOST`，
磁贴渲染为“投屏 · 运行中 / Shizuku 已断开”；`SERVER_STOPPED` 广播后回到 `STOPPED`。
OEM 把后台进程冻结时，磁贴的重绘可能延迟到下次绑定面板，但状态本身已正确。
