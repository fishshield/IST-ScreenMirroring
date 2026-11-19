# Screen Cast Demo

拓扑 A 的 Windows 桌面投屏骨架：**Flutter / Dart 运行在 Windows 主机**，Android
设备只作为 `app_process` 捕获服务端。

```text
Windows host                                      Android device (UID 2000)
────────────                                      ─────────────────────────
AdbLauncher
  ├─ adb push screencast-server.jar ─────────────▶ /data/local/tmp/
  ├─ wired: adb forward tcp:27183 + tcp:27184
  ├─ wireless: adb tcpip 5555 + adb connect
  └─ app_process (USB shell or ADB/TCP shell) ──▶ ServerSocket
       --bind-address=127.0.0.1 (wired)              127.0.0.1:27183 (video)
       --bind-address=0.0.0.0   (wireless)           0.0.0.0:27183  (video)
                                                      0.0.0.0:27184  (control)
                                                        │
ScrcSocketClient ◀──── SCRC / H.264 (USB/LAN) ──────────┘
  ├─ TcpTransport → SecureChannel(AES-GCM, 可选) → ScrcPacketDecoder
  │
NalDecodeQueue → FfmpegDecoder (dart:ffi) → DecodedFrame (YUV420p)
  │
  └─ NativeVideoSurface → native-mapped NV12 double-buffered staging textures
        → DXGI_FORMAT_NV12 → pixel shader YUV→RGB → 独立视频窗口（D3D11）
              │
              └─ WM_MOUSE*/WM_KEY* → ControlClient ──▶ 27184 → InputInjector
```

SCRC 协议没有改动。Android 捕获服务端已从占位改为真实实现：

- 优先通过反射调用隐藏的 `DisplayManager.createVirtualDisplay(String,int,int,int,Surface)`
  镜像默认显示；失败时用 `SurfaceControl.createDisplay()` + 显示事务回退。
- 输出 Surface 是 `MediaCodec.createInputSurface()` 的编码输入 Surface，全程
  surface-input，不使用 inputBuffer 模式。
- `video/avc`，API 30+ 设置 `KEY_LOW_LATENCY`；编码 NAL 逐一封装为 SCRC 包。
- Android 14+ 的 SurfaceControl 兼容路径按新版投影语义处理；任何显示后端失败都会
  打印明确日志并终止，不会回退到 `MediaProjection`。

桌面侧已实现 ADB 启动、socket、队列、FFmpeg 解码和 D3D11 NV12 呈现。视频传输支持
**有线 ADB forward** 和 **局域网直连** 两种模式；无线模式先用 USB 推送 jar、开启
ADB/TCP 并在 TCP 上启动服务端，视频流直接连接手机 IP，不创建 forward。拔掉 USB
后应用会通过仍连接的 ADB/TCP 自动重启服务端并恢复画面。Android 14 平板真机两种模式
均已验证：1280×720 H.264 由 D3D11VA 硬解后，显示在**独立视频窗口**中（按设备画面
比例缩放、支持旋转跟随），Flutter 主窗口只保留控制/状态，关闭后驻留托盘。

> 明确：整个项目不使用 `MediaProjection`。

## 项目现状（交接速览 · 2026-11-17）

> 这一节是给接手者的入口：先读这里，再按需跳到后面的实现/验证章节。

### 一句话状态

**端到端可用**：Windows Flutter 控制端 + Android `app_process` 捕获端，有线/无线两种
传输都已真机跑通；H.264 走 SCRC（协议未改），Windows 侧用 **D3D11VA 硬解**（失败自动
回退软解），画面显示在一个**独立顶层视频窗口**里（带最小化/全屏/关闭按钮、按设备画面
比例缩放、支持旋转跟随），主窗口关闭后驻留托盘、投屏不中断；控制通道的点击/滚轮/按键
注入已按“整帧归一化坐标”修正，真机命中误差 ≤3 设备像素。

### 功能状态

| 模块 | 状态 | 说明 / 验证 |
| --- | --- | --- |
| ADB 启动服务端（USB / 无线 TCP） | ✅ 已验证 | `adb push` + `app_process`，无线模式先 USB 推 jar 再 ADB/TCP 启动；拔 USB 后自动恢复 |
| SCRC 视频传输（27183） | ✅ 已验证 | 协议零改动；支持 TCP_NODELAY（默认开） |
| H.264 解码 | ✅ 已验证 | **D3D11VA 硬解 + 软解回退**；FFmpeg 8.1.2 shared，dart:ffi |
| Windows 呈现 | ✅ 已验证 | 独立顶层窗口 + D3D11 NV12；内容区裁切、按比例缩放、全屏 |
| 视频窗口交互 | ✅ 已验证 | 无标题文字（只保留最小化/全屏/关闭三个图标）、显示/隐藏淡入淡出、全屏 180ms 补间、关闭后主界面会自动回到前台并出现“显示视频窗口”按钮；拖动/缩放（锁比例）、双击或 F11 全屏、Esc 退出全屏 |
| 托盘驻留 | ✅ 已验证（菜单项未逐一点击） | 主窗口关闭 → 托盘；图标两态 + tooltip；右键菜单三项 |
| 控制通道（27184） | ✅ 已验证 | 触摸/按键/滚轮；letterbox 与旋转实时重算 |
| 一键投送（UDP 27185 发现 + 自动连接） | ✅ 已验证（PC + 手机磁贴） | 磁贴点击后 PC 自动直连（常规 1.36 s、冷启动 1.19 s）并弹出视频窗口；启停状态经控制端口探测自愈，不再出现“运行中连不上/点不动” |
| 帧率可观测（解码/呈现 fps） | ✅ 已验证 | tooltip 与状态栏显示 `解码 Nfps · 呈现 Mfps`，差值 >20% 时给出提示；原生按 swap-chain Present 计数 |
| 限制 60 帧（`--target-fps`） | ⚠️ 服务端已实现，ROM 忽略提示 | 提示调用成功但实测仍 98fps @120Hz（`hint ignored by ROM`）；系统设置里切“标准刷新率”实测有效（60fps），UI 文案已引导用户去设置 |
| 设备扫描与连接 | ✅ 已实现 | 主界面合并为一个设备列表：`adb devices` 的 USB 设备 + 本地 /24 的 **27184 控制端口**扫描；点击即连，自动连接开关支持“发现即连”（扫描不会探测 27183 视频端口） |
| 记录层加密（PSK/AES-GCM） | ✅ 已验证（UI 已移除入口） | 三层封装，协议零改动；桌面 UI 不再提供 PSK 输入框，需要时仍可用 `--dart-define=SCREEN_CAST_PSK_HEX` 或服务端 `--psk-hex` |
| Shizuku 控制 App | ✅ 已验证（部分边界） | 授权弹窗、jar 写入、`app_process`（UID 2000）、磁贴启停、前台服务均已真机跑通；Shizuku 断开后投屏继续、状态显示 `SHIZUKU_LOST`；仍缺 binder death 后的重新授权流程单测 |
| Android 10–13 | ❌ 未验证 | 只有 Android 14 / API 34 真机 |
| 音频 | ❌ 未实现 | 仅视频 |

### 最近完成（2026-11，按时间倒序）

0. **后台运行卡片去 OPPO 化（2026-11-19）**：原来的“ColorOS / OPPO 用户请设置保活”
   卡片改为通用的“后台运行（可选）”：按厂商/品牌显示不同文案，ColorOS 家族保留
   “自启动管理”深链，其它机型改为“应用设置”；两个按钮都走系统通用入口，不再假设
   设备是 OPPO。
1. **视频窗口体验与发布图标（2026-11-19）**：
   - 关闭视频窗口不再“再也打不开”：关闭只隐藏，主窗口自动回到前台并显示
     **“显示视频窗口”** 按钮（托盘菜单同样可用）；
   - 去掉视频窗口标题栏的文字，只保留最小化/全屏/关闭三个图标；
   - 显示/隐藏淡入淡出，全屏切换 180ms 矩形补间，最小化走系统动画；
   - 新增应用图标（深色圆角 + 青绿色屏幕与投流符号）：Windows `app_icon.ico`、
     Android 自适应图标 + 各密度 mipmap，生成脚本 `tool/generate_icons.py`。
1. **修复“投屏变卡”的周期性卡顿源（2026-11-19）**：设备扫描原来探测 **27183 视频
   端口**，服务端会把扫描连接当成新观众，重建虚拟显示/编码器（日志：`viewer
   connected` → `Broken pipe`、重复 `Sent IDR #2/#3`、编码窗口 6 秒仅 2 帧）。现在
   扫描只探 **27184 控制端口**，自动扫描在会话运行期间跳过，间隔改为 10 秒、并发 32、
   超时 200 ms。实测：无扫描时 58–61 fps；带桌面端会话时 57–64 fps、`dropped=0`；
   扫描期间服务端 `viewer connected` 计数为 0。另核查：捕获进程 `nice=0`、
   `oom_score_adj=-1000`，优先级没有变化；唤醒状态下显示为 120Hz。
1. **磁贴跟随桌面连接的会话（2026-11-19）**：桌面经无线 ADB 启动/停止服务端后，通过
   `am broadcast` 通知手机 App（`SERVER_STARTED` / `SERVER_STOPPED`，接收器受
   `android.permission.DUMP` 保护，只有 adb shell 能发），App 更新 `CastStateStore`
   并调用 `TileService.requestListeningState` 让 SystemUI 重新绑定磁贴。磁贴自身也改为
   **双向**按 27184 端口校准（之前只会把“运行中”修成“已停止”），面板打开期间每 2 秒
   复核一次。真机验证：桌面自动连接前状态 `STOPPED` → 连接后变 `SHIZUKU_LOST`，磁贴
   显示“投屏 · 运行中 / Shizuku 已断开”；停止广播后状态回 `STOPPED`。
1. **停止服务在 Shizuku 断开后仍可用（2026-11-17 晚）**：新增控制通道 `0x10`
   “停止服务”请求，服务端收到后自行退出；App/磁贴先按 Shizuku 路径停，失败则发
   0x10，并以 **27184 端口是否关闭**作为唯一成功判据。停止前会等待 Shizuku binder
   （冷启动磁贴进程约 2 秒），不再误报“Shizuku 已断开”；磁贴停止改为
   `stopService()`，避免后台 `startService` 被 `BackgroundServiceStartNotAllowed`
   拒绝。真机（Shizuku 未运行）验证：磁贴停止与 App“停止服务”都让服务端进程消失、
   端口关闭、状态 `STOPPED`。
1. **Shizuku 断开后投屏不再中断（2026-11-17 晚）**：前台服务不再监听 Shizuku binder
   death，也不再依赖 Shizuku 判断存活；看门狗改为每 2 秒探一次控制端口 27184。binder
   死亡只把状态改成 `SHIZUKU_LOST`（UI/磁贴显示“Shizuku 已断开”，投屏仍在运行）。
   磁贴同时改成只镜像服务状态（不再有“未授权”态、不再跳 App）；服务未启动时点磁贴
   会在后台起前台服务（带可隐藏通知），启动成功才变“运行中”。Debug 构建导出了该
   前台服务（`fgsExported` 占位符），便于用 adb 验证；release 仍然是私有的。
2. **主界面重构（2026-11-17 晚）**：把“有线/无线/直连”三个入口合并成**设备扫描列表**
   （USB / 局域网图标、扫描按钮、点击连接、自动连接），移除“局域网 IP”“预共享密钥”
   输入框，首页的介绍/实时预览/渲染边界三块内容单开到**关于 / 架构**页；修复磁贴在
   App 进程被杀后仍显示“运行中”（先探测再渲染“检查中…”），以及 Shizuku 未授权时点
   磁贴直接打开 App（不再先显示未授权、再报启动异常）。
3. **A/B/C/D 四项（独立提交）**：
   - A：内容区探测改为**变化触发**（首帧 / 帧尺寸变化 / 视频窗口 resize）+ 60 秒兜底，
     无变化时不 readback；日志 `[content] probe: reason=...`。
   - B：NAL 队列溢出改为**清空并等待 IDR**，不再丢最旧 NAL；画面冻结不花屏。
   - C：原生统计 swap-chain present 次数，tooltip/状态栏显示 `解码 Nfps · 呈现 Mfps`，
     差值 >20% 时提示可开启“限制 60 帧”。
   - D：服务端新增 `--target-fps`（`Surface.setFrameRate` 提示 + 5 秒实测日志），
     PC 端“限制 60 帧”开关（默认关，持久化到 `%APPDATA%\ScreenCast\config.json`），
     Android 控制台增加“编码帧率”状态行。实测 OPPO ROM 忽略帧率提示（98fps @120Hz），
     系统设置里切“标准刷新率（60 Hz）”有效。

0. **一键投送 / 自动连接**：新增 UDP 27185 发现协议（`lib/src/discovery/`）、PC 端
   子网+地址双重校验、自动连接策略与 UI 开关；Android 控制 App 在服务启动/磁贴点击
   时向所有非 loopback 网卡广播 5 次。PSK 语义按 offer 区分，失败会弹回主窗口。
1. **点击坐标修正**：发现服务端契约是“整帧归一化”，客户端改为把窗口内坐标经内容区
   比例还原到整帧；竖屏/横屏/缩放窗口三种情况下，`uiautomator` 图标中心点击的注入
   误差 ≤3 设备像素，实际打开的 Activity 正确。
2. **比例与旋转**：内容区检测（左右/上下黑边）、窗口按内容比例重排、旋转后自动跟随、
   拖动边缘锁比例；修复 `ResizeBuffers` 失败导致 DWM 拉伸旧帧的根因。
3. **独立视频窗口 + 托盘**：窗口从 Flutter 宿主 popup 改为独立顶层窗口，自绘标题栏
   （最小化/全屏/关闭）、F11/Esc、关闭即隐藏；`Shell_NotifyIcon` 托盘、主窗口关闭
   不中断投屏。
4. **D3D11VA 硬解**：复用渲染器设备、`CopySubresourceRegion` 零拷贝呈现，帧率源
   120 fps 时上传吞吐 ≈120/s、丢弃 0（之前软解 ≈76/s、丢弃 37%）。

### 已知问题与限制（按重要性）

1. **托盘菜单只验证了回调路径**：`显示主窗口 / 显示视频窗口 / 退出` 三项通过模拟
   托盘回调消息打开过菜单并截图确认；`退出`（会结束进程）没有手工点击验证。
   托盘图标在 Windows 默认进入通知区“溢出面板”，需要点开 `^` 才看得到。
2. **内容区靠启发式检测**：编码器把设备画面 letterbox 进 1280×720，客户端从解码帧
   Y 平面扫描对称黑边（`frame_content_rect.dart`）。深色 UI 边缘、非对称黑边会被判为
   “无黑边”，退化为整帧显示；探测改为**变化触发**（首帧、帧尺寸变化、窗口 resize），
   另有 60 秒兜底，所以旋转后最多可能滞后约 60 秒（或在下一次窗口 resize 时立刻跟上）。
3. ~~**硬解路径每 4 秒下载一帧**（≈1.4 MB）用于内容区检测~~ —— 已优化：内容区探测改为
   变化触发，无变化时不做 readback；60 秒安全兜底一次；详见 §5。未实现“只采样边缘
   8 行/列”的原生导出（代价高于收益），因此条形宽度仍靠整帧 Y 平面测量。
4. **呈现节奏仍受 DWM 限制**：解码/上传已做到 0 丢帧，但屏幕刷新仍由窗口 Present
   驱动（UI 线程）。源 144 Hz 时不会真的显示 144 帧。
5. **GDI fallback**（D3D 初始化失败）只画纯色占位，不显示视频；没有自动化测试覆盖。
6. **present/交换链失败恢复**：已实现 `ResizeBuffers` 失败时重建交换链；但没有做
   设备丢失（device removed）后的整体重建。
7. **未做**：多控制端并发、重放保护/密钥轮换、音频、Android 10–13 捕获、Shizuku
   运行时（binder death、超时、磁贴停止）验证。

### 关键设计约定（改动前必读）

- **坐标契约（最容易踩坑）**：客户端发送的归一化坐标是**整帧**的（0..1 对应
  1280×720），服务端 `InputInjector` 先 `videoX = nx * videoWidth`，再减掉 letterbox
  偏移换算成设备像素。窗口只显示内容区时，必须先把点击点换算回整帧坐标：
  `nx = contentRect.left + fx * contentRect.width`（`fx` 是点在窗口内容区内的比例）。
- **letterbox 现状**：视频帧恒为 1280×720；设备画面按比例居中。平板 2800×2000 竖屏时
  内容为 514×720 @ offset (383,0)，横屏时 1008×720 @ (136,0)。
- **视频窗口**：独立 `WS_POPUP | WS_THICKFRAME`（无 owner，任务栏可见），40 px 非客户区
  标题栏由 `WM_NCPAINT` 自绘；客户区只画内容区（视口错位裁切），窗口按内容比例重排。
- **硬解**：`av_hwdevice_ctx_alloc(D3D11VA)` + 复用渲染器的 `ID3D11Device`；帧在
  `avcodec_receive_frame` 内同步拷进 video texture。ABI 偏移由
  `tool/ffmpeg_abi_dump.c` 生成，运行时校验 `codec_id`，不符只做软解。
- **同步 FFI 桥**：`hardware_frame_bridge.cpp` 导出 3 个 C 函数，Dart 用
  `DynamicLibrary.open` 直接调用（不能走 MethodChannel，否则 AVFrame 已释放）。
- **托盘**：`Shell_NotifyIcon` 注册在 Flutter 根窗口上；主窗口 `WM_CLOSE` 改为隐藏；
  `退出` 才 `DestroyWindow` 结束进程。

### 快速上手

```powershell
# 依赖：Flutter（Windows desktop）、MSVC Build Tools、Android SDK/platform-tools
flutter analyze          # 0 issues
flutter test             # 100 个单测
tool\build_server.ps1    # 可选：改过 Android 服务端时重编 jar
flutter build windows --debug

# 有线 + 自动启动（手机解锁、USB 调试已授权）
flutter run -d windows --debug --dart-define=SCREEN_CAST_AUTOSTART=true

# 无线直连（手机与 PC 同一局域网）
flutter run -d windows --debug `
  --dart-define=SCREEN_CAST_AUTOSTART=true `
  --dart-define=SCREEN_CAST_WIRELESS=true `
  --dart-define=SCREEN_CAST_HOST=192.168.1.134

# 一键投送：监听 UDP 27185，手机点磁贴即自动直连
flutter run -d windows --debug --dart-define=SCREEN_CAST_AUTOCONNECT=true
```

启动后应看到：

- 主窗口只有一个**设备与连接**面板：点“扫描设备”后列出 USB（`usb` 图标）与局域网
  （`wifi` 图标）可连接设备，点一行即连接；“自动连接（发现即连）”打开后无需点击；
- 连接成功后独立视频窗口按设备画面比例出现，标题栏右侧三个按钮；
- 架构/渲染边界说明移到了右上角“关于 / 架构”页；
- 日志里依次出现 `[hwaccel] D3D11VA decode enabled (shared device)`、
  `[content] probe: reason=... rect=...`、`[cast] 1s decoded=.. uploaded=..`。

联调工具：`tool/adb_launch.ps1`（手工起服务端）、`tool/control_probe.ps1`
（窗口坐标/点击/滚轮/截图）、`tool/window_check.ps1`（窗口与托盘回归）、
`tool/clock_server.py`（延迟测量时钟页）、`tool/check_server.ps1`（JVM 断言）。

### 调试经验（都是踩过的坑）

1. **Windows 插件可能构建了旧 DLL**：Flutter 的增量构建有时不会重编插件。改完
   C++ 后如果行为没变，删掉 `build\windows\x64\plugins\screen_cast_windows` 再构建，
   并确认 `build\windows\x64\runner\Debug\screen_cast_windows_plugin.dll` 的时间戳变了。
2. **不要用屏幕截图判断窗口内容**：视频窗口被其他窗口遮挡时，截图拿到的是上层窗口，
   会得出“裁切没生效”的错误结论。用窗口几何、服务端日志、`uiautomator dump` 验证。
3. **交换链尺寸不同步**：`ResizeBuffers` 失败后若继续用旧缓冲，DWM 会把旧画面拉伸到
   新客户区，看起来像“裁切/缩放失效”，点击也会随之偏移。现在失败即重建交换链。
4. **横竖屏差异**：设备竖屏时 `wm size` 报 2000×2800，横屏是 2800×2000；letterbox
   方向也随之变化，内容区检测要同时支持左右和上下黑边。
5. **ColorOS 刷新率**：`settings put system peak_refresh_rate 60` 不生效（SurfaceFlinger
   仍 144 Hz），真正的 60 Hz 只有 `settings put global low_power 1`。
6. **adb 多设备**：USB 与 TCP 同时存在时 `adb devices` 会有两条，所有命令加 `-s <serial>`。
7. **Flutter Windows 没有 PlatformView**：`WS_CHILD` 会被 Flutter 合成层遮挡，所以视频
   只能是独立顶层窗口。

### 建议的下一步（优先级从高到低）

1. 把“窗口坐标 → 整帧归一化”的换算抽成纯函数并加单测（竖屏/横屏/缩放/letterbox 四种
   组合），避免以后改窗口几何时再次偏移。
2. 一键投送收尾：给 offer 增加签名/信任确认，替代当前“同网段即可信”的假设；
   多网卡真机（当前 PC 只有一张网卡，相关逻辑仅单测覆盖）。
3. ~~降低内容区探测成本~~ —— 已完成变化触发（首帧/尺寸变化/窗口 resize + 60 秒兜底），
   无变化时不做 readback；详见 §5。
4. 呈现放到独立线程（或至少避免 UI 线程 Present 阻塞），让高刷源真正跑满。
5. 托盘菜单逐项人工验证（尤其是 `退出`），并把托盘图标固定到通知区可见位置。
6. 设备丢失（D3D device removed）后的渲染器整体重建。
7. Android 10–13 捕获路径、以及带 Shizuku 的真机验证。


## 已实现的链路

### 1. ADB 启动

[`lib/src/host/adb_launcher.dart`](lib/src/host/adb_launcher.dart)

- 自动寻找 `adb`：`ADB` 环境变量 → `ANDROID_HOME` / `ANDROID_SDK_ROOT` →
  `%LOCALAPPDATA%\Android\Sdk` → `PATH`。
- `Process.run` 执行 `adb push`，把 asset 中的 `classes.dex` jar 推到
  `/data/local/tmp/screencast-server.jar`。
- 选择设备（无 serial 时要求恰好一个已授权设备）。
- **有线模式**：执行 `adb forward tcp:27183 tcp:27183`，服务端
  `--bind-address=127.0.0.1`。选用 `tcp:` 而不是 `localabstract:scrcpy`，因为
  现有 `Server.java` 使用设备本地 TCP socket。
- **无线模式**：跳过 `adb forward`，服务端以 `--bind-address=0.0.0.0` 启动；
  主机直接连接手机局域网 IP。启动时临时启用 ADB/TCP 5555 并在 TCP 上启动
  app_process；USB 拔线导致当前服务端被 adbd 清理后，应用会自动通过 ADB/TCP
  重启服务端并恢复视频。
- `Process.start` 执行 `adb shell CLASSPATH=... app_process ... Server`，并等待
  stdout 中的 `SCRC server listening`。
- 停止时 `pkill` 远端 app_process；仅在当前会话实际安装过 forward 时才移除它，
  并清理临时 jar。

> 本机已有 ADB：`%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`，
> 因此没有执行下载安装。

### 2. 传输模式、SCRC Socket 与解码队列

[`lib/src/transport/cast_transport.dart`](lib/src/transport/cast_transport.dart)
[`lib/src/transport/scrc_socket_client.dart`](lib/src/transport/scrc_socket_client.dart)
[`lib/src/pipeline/nal_decode_queue.dart`](lib/src/pipeline/nal_decode_queue.dart)

- 传输配置统一为 `CastTransportConfig`，三种模式：
  - `wired`：客户端连接 `127.0.0.1:27183`，服务端绑定 loopback，必须
    `adb forward`；
  - `wireless`：客户端连接 `<手机局域网 IP>:27183`，服务端绑定 `0.0.0.0`，
    **不创建** `adb forward`；
  - `direct`：桌面**完全不执行 ADB**（不 push、不 tcpip、不 forward、不启动
    app_process），只连接 `<手机局域网 IP>:27183`；服务端由手机上的控制 App
    通过 Shizuku 启动。`CastSession` 在这种模式下不创建 `AdbLauncher`，
    `CastSessionInfo.serial` 为 `null`。
- `ScrcSocketClient` 接受可配置的 `host` 和 `port`，启动时按 250 ms 间隔重试最多
  8 秒；连接错误会显示实际 host:port。
- **TCP_NODELAY** 统一由 [`TcpTransport`](lib/src/transport/transport.dart) 在包装
  socket 后设置，27183（视频）和 27184（控制）两条连接都生效，并在连接日志打印状态：
  `[tcp] 192.168.1.134:27183 TCP_NODELAY=true`、
  `[tcp] 192.168.1.134:27184 TCP_NODELAY=true`。
  关闭开关用于对照测量：`--dart-define=SCREEN_CAST_TCP_NODELAY=false` 会打印
  `TCP_NODELAY=false (disabled by ...)` 并保留 Nagle。
- 用现有 [`ScrcPacketDecoder`](lib/src/protocol/scrc_packet_decoder.dart) 增量解析：
  4 字节魔数 `0x53435243` + 4 字节大端长度 + NAL。
- NAL 进入有界队列（默认 180 个）。队列溢出时**清空整个队列并等待 IDR**，而不是丢最旧
  NAL：丢 P 帧会让后续帧参考缺失、花屏，清空后画面冻结在最后一帧直到关键帧到达。
  日志 `[decode] queue overflow, dropped N NALs, waiting for IDR` /
  `[decode] IDR received, resumed decoding`；超过 3 秒仍未等到 IDR 只打印
  `[decode] IDR wait timeout (3s), still waiting`，不重置连接（服务端关键帧间隔 1 秒，
  正常情况下不会触发）。
- 单消费者顺序送入 FFmpeg。

### 3. FFmpeg Dart FFI：D3D11VA 硬解 + 软解回退

[`lib/src/ffmpeg/ffmpeg_decoder.dart`](lib/src/ffmpeg/ffmpeg_decoder.dart)
[`lib/src/ffmpeg/ffmpeg_abi.dart`](lib/src/ffmpeg/ffmpeg_abi.dart)
[`lib/src/ffmpeg/hardware_frame_bridge.dart`](lib/src/ffmpeg/hardware_frame_bridge.dart)
[`lib/src/ffmpeg/ffmpeg_runtime.dart`](lib/src/ffmpeg/ffmpeg_runtime.dart)
[`packages/screen_cast_windows/windows/hardware_frame_bridge.cpp`](packages/screen_cast_windows/windows/hardware_frame_bridge.cpp)

**硬解路径（首选）**

- 打开解码器前，先用插件的同步 C 导出 `screencast_hw_acquire_device` 取得渲染用
  `ID3D11Device*` / 立即上下文（各 +1 引用），然后
  `av_hwdevice_ctx_alloc(AV_HWDEVICE_TYPE_D3D11VA)` → 把这两个指针写进
  `AVHWDeviceContext.hwctx`（即 `AVD3D11VADeviceContext.device/.device_context`）→
  `av_hwdevice_ctx_init()`。这样 FFmpeg **复用渲染设备**，不存在跨设备拷贝；
  只有拿不到渲染设备时才退回 `av_hwdevice_ctx_create`（自建设备），并打印
  `[hwaccel] using separate device, cross-device copy required`。
- 通过 ABI 偏移把 `AVCodecContext.get_format` 设为只返回 `AV_PIX_FMT_D3D11` 的回调，
  并把 hw device 引用写到 `AVCodecContext.hw_device_ctx`（所有权交给 codec context），
  再 `avcodec_open2`。
- `avcodec_receive_frame` 得到 `format == AV_PIX_FMT_D3D11` 的帧：
  `data[0]` 是 `ID3D11Texture2D*`，`data[1]` 是数组 slice 索引（`intptr_t`）。
  解码循环在 **AVFrame 仍然有效时** 直接调用同步 C 导出
  `screencast_hw_copy_texture`，由原生侧
  `CopySubresourceRegion` 拷进 overlay 的 video texture 并 `InvalidateRect`，
  完全跳过 `Nv12FrameWriter` 的 CPU 映射写入。
- 帧生命周期：拷贝发生在 `avcodec_receive_frame` 与 `av_frame_unref` 之间，所以不需要
  AddRef/Release；Dart 侧只返回一个 `DecodedFrame.hardware`（无平面数据）用于计数，
  呈现由原生完成。

**软解回退（任一环节失败都走这里，两条路径并存）**

- 没有插件（非 Windows / 测试环境）、拿不到 overlay 设备、`avcodec_open2` 失败、
  `get_format` 被拒 → 打印原因并改用普通软解上下文，YUV420p → `Nv12FrameWriter`
  → 双缓冲 staging texture 的原有管线不变。
- 若硬解中途返回非 D3D11 帧且是 YUV420p：该帧走软解拷贝路径并打印一次日志。
- 若纹理属于另一个设备（跨设备）或原生拷贝失败：用 `av_hwframe_transfer_data`
  把帧下载成 NV12，再按软解路径上传，并打印一次
  `[hwaccel] using separate device, cross-device copy required; downloading ...`。

**ABI 安全性**：`ffmpeg_abi.dart` 里的结构体偏移由
[`tool/ffmpeg_abi_dump.c`](tool/ffmpeg_abi_dump.c) 针对该 8.1.2 构建生成；解码器打开
硬解前会核对 `AVCodecContext.codec_id == 27`，偏移不符就只做软解，不会写坏内存。

- 绑定 `avcodec_find_decoder` / `avcodec_open2` / `avcodec_send_packet` /
  `avcodec_receive_frame` / `av_frame_alloc` 等最小函数集。
- 输入是 SCRC 的裸 NAL：解码器补 `00 00 00 01`，缓存最新 SPS/PPS 并随每个 VCL
  packet 重新插入，然后交给 H.264 解码器。
- 运行库为 FFmpeg 8.1.2 Windows x64 shared build，位于
  `third_party/ffmpeg/bin`，由 runner CMake 复制到构建输出目录。
- 重新获取运行库：`tool/fetch_ffmpeg.ps1`。该构建为 **GPLv3**，许可证在
  [`third_party/ffmpeg/LICENSE.txt`](third_party/ffmpeg/LICENSE.txt)。

真实解码已在单测中验证：`test/assets/sample_320x180.h264` 成功解出 15 帧
320x180 YUV420p（测试环境没有插件 DLL，因此日志里会看到
`[hwaccel] native bridge unavailable ... falling back to software decode`，
正是软解回退路径的实测）。

### 4. Android 虚拟显示与 H.264 编码

[`VirtualDisplayFactory.java`](android-server/src/main/java/com/example/screencast/server/VirtualDisplayFactory.java)
[`VirtualDisplayCaptureBackend.java`](android-server/src/main/java/com/example/screencast/server/VirtualDisplayCaptureBackend.java)

- 优先反射隐藏的 `DisplayManager.createVirtualDisplay(String,int,int,int,Surface)`，
  把默认显示镜像到编码器输入 Surface。该静态方法在 Android 14+ 可用；Android
  10–13 上通常不存在，会打印明确日志后进入回退。
- 失败后回退 `SurfaceControl.createDisplay()`，在事务中设置显示 Surface、
  projection 和 layer stack。Android 14+ 的 `setDisplayProjection` /
  `setDisplayLayerStack` 语义变化已单独处理（14+ 用输出尺寸并传 displayId，
  旧版本用源显示尺寸 + layerStack）。
- `MediaCodec` 使用 `video/avc`、`COLOR_FormatSurface`；API 30+ 设置
  `KEY_LOW_LATENCY=1`，API 26+ 设置 `KEY_LATENCY=1`。`configure()` 后
  `createInputSurface()`，虚拟显示直接写入，**没有**
  `dequeueInputBuffer()` / `queueInputBuffer()` 路径。
- 编码输出按 Annex-B 拆成单个 NAL，缓存并在 IDR 前补 SPS/PPS，再逐包交给现有
  `ScrcPacketWriter`。支持少数厂商的长度前缀输出。
- 两种显示后端都失败时打印完整堆栈并结束会话；没有任何 MediaProjection 分支。
- **码率与编码格式日志**（[`VirtualDisplayCaptureBackend.java`](android-server/src/main/java/com/example/screencast/server/VirtualDisplayCaptureBackend.java)）：
  `MediaCodec.configure()` 之后打印实际生效的三项参数，编码循环里每秒打印一次
  SCRC payload 码率：
  `[encoder] configured(input) KEY_BIT_RATE=-1 KEY_I_FRAME_INTERVAL=-1 KEY_FRAME_RATE=60`、
  `[encoder] effective(output) KEY_BIT_RATE=8000000 KEY_I_FRAME_INTERVAL=-1 KEY_FRAME_RATE=60`、
  `[encoder] 1s bitrate=17000 kbps bytes=2130629 frames=124 window=1002ms`。
  `bitrate` 按 `NAL 字节数 × 8 / 窗口毫秒` 计算，只统计 SCRC payload，不含 8 字节包头。

### 5. 原生 D3D11 NV12 视频呈现

[`lib/src/windows/native_video_surface.dart`](lib/src/windows/native_video_surface.dart)
[`lib/src/windows/nv12_frame_writer.dart`](lib/src/windows/nv12_frame_writer.dart)
[`packages/screen_cast_windows/windows/d3d11_renderer.cpp`](packages/screen_cast_windows/windows/d3d11_renderer.cpp)

- Flutter Windows **没有可用的 Android 式 PlatformView**。当前 Flutter Windows
  embedder 的 `PlatformViewPlugin` 实现是空壳，无法注册带 HWND 的真实平台视图。
- 实测发现 `WS_CHILD` 原生窗口会被 Flutter 的合成层遮挡；随后一版是**由 Flutter
  顶层窗口拥有的 `WS_POPUP` 覆盖窗口**。本版再进一步：视频改由**独立顶层窗口**
  （`WS_POPUP | WS_THICKFRAME`，无 owner）承载，Flutter 主窗口只保留连接/设置/状态。
- 独立窗口行为（[`native_video_view.cpp`](packages/screen_cast_windows/windows/native_video_view.cpp)）：
  - 自定义标题栏：窗口保留 40px 非客户区，由 `WM_NCPAINT` 用 GDI 只绘制
    **最小化 / 全屏 / 关闭** 三个图标（不画任何标题文字，窗口看起来就是手机屏幕）；
  - 显示/隐藏用 `AnimateWindow(AW_BLEND)` 做 160/130ms 淡入淡出；全屏切换先把
    样式/标题栏高度切好，再用 15ms 定时器对窗口矩形做 180ms ease-out 补间
    （实测点击后 60ms 处于中间尺寸、560ms 到达全屏，Esc 恢复原尺寸）；
  - 关闭按钮只隐藏窗口（不销毁、不断开会话），并通知 Dart 把主窗口带到前台、
    显示“显示视频窗口”按钮；托盘右键菜单也可重新打开；
  - 初始尺寸按视频宽高比：横屏 640×360、竖屏 360×640 逻辑像素（按 DPI 缩放，
    125% 下横屏即 800×450），居中于主窗口所在显示器；`WM_GETMINMAXINFO`
    限制最小 240×135；
  - 双击标题栏（拖拽区）或 **F11** 切换全屏：去掉 `WS_THICKFRAME`、`SetWindowPos`
    覆盖当前显示器；**Esc** 退出全屏（不关窗），恢复之前的窗口位置/尺寸与样式；
  - `WM_CLOSE`（Alt+F4 / 任务栏关闭）只 `SW_HIDE`，不销毁窗口、不断开会话；
  - 左键按下 `SetFocus`，键盘焦点进入视频窗口后 `WM_KEYDOWN/UP` 才能注入；
    `WM_MOUSEMOVE` / `WM_LBUTTONDOWN/UP` / `WM_MOUSEWHEEL` 的捕获与归一化坐标
    计算与之前完全一致，只是宿主换成了独立窗口（不再有“输入未连接即点穿”的
    `HTTRANSPARENT` 分支）。
- **等比例缩放与点击映射（本轮修复，真机已验证）**：
  - 编码器把设备画面 letterbox 进 16:9 帧（例：平板 2800×2000，竖屏内容在 1280×720
    帧里是 514×720、偏移 383）。客户端从解码帧 Y 平面探测内容区（`frame_content_rect.dart`，
    支持左右黑边与上下黑边两种方向），得到 `FrameContentRect(0.299,0,0.402,1)` 这类
    归一化矩形。探测是**变化触发**的：首帧、帧尺寸变化、视频窗口 resize，另有 60 秒
    兜底；日志 `[content] probe: reason=<initial|resize|size-change|timer> rect=...`。
  - 呈现：`D3D11Renderer::Render()` 用视口错位（把整帧放大到黑边移出 render target）
    只显示内容区，并按内容宽高比在窗口内居中；窗口本身也按内容比例重排（旋转后
    竖屏 500×710 → 横屏 994×710 自动切换）。
  - 点击：服务端（`InputInjector`）把归一化坐标乘以**整帧**尺寸得到 video 像素，再
    减去黑边偏移换算成设备像素（`videoX = nx*videoWidth` → `displayXForVideo`）。所以
    客户端必须发送**整帧归一化**坐标：先算点在窗口内容区里的比例，再用内容矩形还原到
    整帧坐标（`nx = rect.left + fx*rect.width`）。窗口缩放、旋转、裁切共用这套几何。
  - 缩放：拖动窗口边缘时 `WM_SIZING` 按内容比例同步另一条边，保证放大/缩小不变形；
    全屏时按内容比例居中（正常留边）。
  - 真机点击命中实测（`uiautomator` 取图标中心 → 按上述几何换算成窗口坐标 →
    `PostMessage` 点击 → 比对服务端注入坐标与实际前台 Activity）：
    竖屏窗口 321×450 点「设置」图标中心 (1175,2615) → 注入 (1177,2618)；
    横屏窗口 630×450 点「设置」图标中心 (1614,1835) → 注入 (1613,1835)；
    两种情况都打开 `com.oplus.wirelesssettings/SettingsActivity`（即设置），
    两轴误差 ≤3 设备像素。
  - 关键修复：窗口 `ResizeBuffers` 失败时交换链会保持旧尺寸，导致 DWM 把旧帧拉伸
    到新客户区（画面看起来"裁切没生效"、点击也随之偏移）。现在失败时重建交换链，
    客户区与后台缓冲始终一致。
- 托盘驻留（[`tray_icon.cpp`](packages/screen_cast_windows/windows/tray_icon.cpp)）：
  `Shell_NotifyIcon` 在**主窗口关闭时**安装/刷新，主窗口只是 `SW_HIDE`，采集会话与
  视频窗口继续运行；右键菜单为 **显示主窗口 / 显示视频窗口 / 退出**，双击托盘图标
  也可恢复主窗口。图标是运行时用 GDI 画的圆点（绿色=已连接、灰色=未连接），
  tooltip 为 `已连接 · 1280×720 · 解码 120fps · 呈现 60fps` / `未连接`，由 Dart 通过
  `updateStatus`（连接态、帧尺寸、解码 fps）按秒推送，**呈现 fps** 由 D3D11 渲染器
  每秒统计 swap-chain `Present` 次数后填入。解码与呈现差值 >20% 时，主窗口状态栏
  额外显示“源帧率高于呈现能力，可开启‘限制 60 帧’减少带宽和编码器负载”。`退出` 是
  唯一真正退出应用的入口。
- 原生 D3D11 创建四个纹理：**两个 NV12 staging upload texture（双缓冲）**、
  **NV12 video texture** 和 **swap-chain back buffer/render target**。
- `configureFrame` 一次性 `Map` **两张** staging texture，把两组
  CPU 指针/`RowPitch` 返回给 Dart。`Nv12FrameWriter` 用 `dart:ffi` 直接把 Y 和交错的
  UV 写进映射内存；每帧只有一次 Dart→native CPU 拷贝，MethodChannel 只传指针/宽高，
  **不序列化像素**。
- 写入与呈现解耦（[`nv12_frame_buffer.dart`](lib/src/windows/nv12_frame_buffer.dart)）：
  `Nv12DoubleBuffer` 在两张 staging texture 之间轮换，**写入完成立即返回**，
  `presentFrame` 异步执行。写入永远落在**没有在呈现**的那张纹理上（所以写入和呈现
  绝不争用同一块内存）；只有轮到的纹理仍在呈现、或两张都在途时，当前帧才**丢弃**
  （不排队）。`CastController` 统计丢弃帧数，预览栏显示 `N dropped`。
- `presentFrame` 只处理被选中的那张纹理：`Unmap(index) → CopyResource → Map(index)`
  顺序不变，原生侧记录最近呈现的 texture 索引（`getStatus` 的 `displayedIndex`）；
  另一张纹理全程保持映射，因此下一次写入永远不会撞上正在呈现的资源。
- 由 SV_VertexID 生成全屏 quad，pixel shader 以固定 BT.601 limited-range 矩阵完成
  YUV→RGB。
- 每秒统计打印到 debug 日志：
  `[cast] 1s decoded=.. uploaded=.. dropped=.. | total decoded=.. uploaded=.. dropped=.. unavailable=.. failed=..`
- NV12 使用单个 resource 的 Y/UV plane，分别通过 `R8_UNORM` 和 `R8G8_UNORM`
  两个 per-plane SRV 采样；没有采用跨厂商不一致的 `Texture2DArray` plane 选择。
- 第一帧之前是青绿色占位；第一帧之后如果暂时没有新帧，持续重绘上一张 video
  texture，不清屏、不闪烁。窗口最小化/恢复和 WM_PAINT 也会保留最后一帧。
- Flutter 界面里原来的预览位置改为占位卡：文案「视频在独立窗口中播放」+ 一个
  「显示视频窗口」按钮（走 `showVideoWindow`），标题栏仍显示 `Win32 · D3D11`
  或 `Win32 · GDI`。GDI fallback 不承载视频帧。

> 如果你严格要求“PlatformView”这个 Flutter API 语义，Windows 目标目前无法满足；
> 可选替代是 Flutter 外部纹理（Texture + D3D11 shared texture）。当前方案是原生
> 独立顶层窗口，不是 PlatformView。

## 6. Android 控制 App / Shizuku 集成

[`android-app/`](android-app/) 是普通 Android 应用，不包含 ADB 协议栈或自我提权代码：

- 通过 **Shizuku** 获取用户授权的 shell 能力；Shizuku 由用户通过 Android 11+
  无线调试激活。App 自身不需要 root。
- 已声明 `ShizukuProvider`（受 `INTERACT_ACROSS_USERS_FULL` 保护）和
  `TileService`（受 `BIND_QUICK_SETTINGS_TILE` 保护）。
- `MainActivity` 启动时检查 `Shizuku.pingBinder()`：
  - 不可用时显示激活引导，并提供“打开 Shizuku”；
  - 可用但未授权时请求授权，处理异步授权回调；
  - 监听 binder death / re-receive，并更新 UI。
- [`ServerLauncher.kt`](android-app/app/src/main/java/com/example/screencast/controller/ServerLauncher.kt)：
  - 通过 Shizuku shell 身份检查 app assets 中的 `screencast-server.jar`，
    缺失时流式写入 `/data/local/tmp/`；
  - 使用现有类名、端口和 `--bind-address=0.0.0.0` 启动 `app_process`；
  - `destroy()` + 尽力 `pkill` 停止；
  - 所有 binder/进程操作在 IO 协程中执行，使用 `waitForTimeout`、`withTimeout`
    和 binder-death 监听。
  - 启动/停止语义：`start()` 在端口已在监听时直接接管（不要求 Shizuku）；`stop()`
    在 Shizuku 不可用时返回 `false` 并尝试本地 `pkill`，由调用方负责提示。
- 前台服务 [`ScreenCastForegroundService.kt`](android-app/app/src/main/java/com/example/screencast/controller/ScreenCastForegroundService.kt)：
  - 生命周期**只由** `ACTION_START` / `ACTION_STOP` 和“捕获进程是否还在监听 27184”
    决定；服务对象不长期持有 Shizuku 引用，只在真正 start/stop 时惰性创建
    `ServerLauncher`；
  - 看门狗每 2 秒 TCP 探测一次控制端口：监听中 → 保持前台；端口关闭 → 状态改
    `STOPPED`、撤通知并 `stopSelf`。**不再用 Shizuku 判断进程存活**，所以 Shizuku
    重启/退出不会把前台服务带走；
  - 启动时如果端口已经在监听（服务端由 ADB 或上一个进程启动），直接**接管**它并
    补上前台保护；这条路径完全不碰 Shizuku，Shizuku 已断开时状态为 `SHIZUKU_LOST`；
  - 停止路径：先 destroy 进程句柄，再用 Shizuku `pkill`，最后**通过控制通道 0x10
    请求服务端自己退出**；成功与否只看 27184 是否关闭。因此 Shizuku 断开时、或服务端
    由桌面经无线 ADB 启动时，磁贴/通知/App 的“停止服务”都能真正停掉服务端（旧版
    服务端会忽略 0x10，此时才会 Toast 提示失败）；
  - 服务类型 `specialUse`，Manifest 里声明 `foregroundServiceType="specialUse"` +
    `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` 理由，Android 14+ 另需
    `FOREGROUND_SERVICE_SPECIAL_USE` 权限；
  - 低优先级常驻通知“投屏服务运行中”，带“停止” action；文案跟随
    `CastStateStore`（启动中/运行中/停止中/异常/未授权/Shizuku 已断开）；
  - Debug 构建通过 `manifestPlaceholders` 的 `fgsExported` 把服务导出，便于用
    `adb shell am start-foreground-service` 验证前台保护行为；release 保持私有。
- Quick Settings 磁贴 [`ScreenCastTileService.kt`](android-app/app/src/main/java/com/example/screencast/controller/ScreenCastTileService.kt)：
  - 只镜像**捕获服务**的状态，和 App 完全一致：已停止 / 启动中 / 运行中 / 停止中 /
    异常 / Shizuku 已断开（运行中 + 副标题“Shizuku 已断开”）；磁贴不再显示“未授权”，
    也不再因为 Shizuku 状态跳转 App；
  - `onStartListening()` 先显示“检查中”，再用控制端口探测核对缓存状态，避免在 App
    进程被杀后继续显示“运行中”；
  - 点击时只问端口：没在监听 → 后台启动前台服务（带可隐藏通知），服务真正起来后
    磁贴才变“运行中”；已在监听 → 走停止；启动失败（例如 Shizuku 不可用）时磁贴保持
    原样，由服务/App 负责报错；
  - `STARTING`/`STOPPING` 期间的点击直接忽略，避免和启动器互斥锁抢；
  - 长按由系统处理：`TileService` 没有长按回调，主界面声明 `QS_TILE_PREFERENCES`，
    系统带磁贴组件启动它；
  - Android 13+ 用 `StatusBarManager.requestAddTileService` 弹系统“添加功能块”
    对话框，低于 13 返回 `false` 并由主界面提示手动添加。
- Activity 和磁贴通过 `CastStateStore`（SharedPreferences + listener）共享
  `UNAUTHORIZED / STOPPED / STARTING / RUNNING / STOPPING / ERROR / SHIZUKU_LOST`；
  前台服务也在这条状态链上，通知文案随状态变化。
- Shizuku binder death 只更新状态（`SHIZUKU_LOST`），**不调用**停止、不终止前台
  服务：投屏继续，只是失去“停止/重启”的控制能力，重新激活 Shizuku 后恢复。
- **桌面启动的会话**：桌面通过无线 ADB 启动服务端时，会执行
  `am broadcast -a com.example.screencast.action.SERVER_STARTED -n
  com.example.screencast.controller/.CastStateReceiver`（停止时发 `SERVER_STOPPED`），
  App 收到后把状态置为 `RUNNING` / `SHIZUKU_LOST` 并请求 SystemUI 重绑磁贴；接收器
  声明 `android:permission="android.permission.DUMP"`，普通 App 无法伪造状态。
- 主界面底部有一张**后台运行**卡片（不绑定 OPPO）：文案按 `Build.MANUFACTURER/BRAND`
  区分，ColorOS 家族（OPPO/OnePlus/realme）显示“自启动管理 + 电池优化”，其它机型显示
  “应用设置 + 电池优化”；自启动管理页面逐个 `resolveActivity` 探测，失败回退到应用
  详情页。
- 服务端 stdout/stderr 重定向到 `/data/local/tmp/screencast-server.log`。

> 前台服务在 Android 13+ 需要 `POST_NOTIFICATIONS` 才能显示常驻通知：主界面点
> “启动服务”时请求，拒绝后服务仍会运行，只是通知不可见。

注意：Shizuku 13.1.5 没有 libsu 的 `Shell.Result`。本实现使用实际存在的
`IShizukuService.newProcess` AIDL（shell 进程）并在 IO 协程/`waitForTimeout`
中异步等待，不在主线程同步等待。

构建：

```powershell
cd android-app
.\gradlew.bat :app:assembleDebug
```

生成 `app/build/outputs/apk/debug/app-debug.apk`。已在本机完成构建、安装、启动；
磁贴的添加、渲染、点击、长按均已在 Android 14 真机验证；Shizuku 授权、
`app_process` 启动、桌面直连回显也都跑通过（见“验证状态”）。

已落地：前台服务 + 常驻通知（`ScreenCastForegroundService`，`specialUse` 类型，
带“停止” action 与 ColorOS 保活引导），以及 Windows 端的“App 直连”模式。

前台服务已在真机验证：`dumpsys activity services` 显示 `isForeground=true`、
`types=40000000`（即 `FOREGROUND_SERVICE_TYPE_SPECIAL_USE`）、带 1 个 action 的
常驻通知；ColorOS 保活卡片在真机上正常渲染。

## 7. 控制通道（输入注入，27184）

视频走 SCRC（27183），输入注入走独立的 TCP 通道（27184）。两条链路互不依赖：
控制断开只停止注入，视频会话继续。

```text
Windows                                Android
overlay WM_MOUSE*/WM_KEY*
  └─ NativeVideoView（C++，归一化 0..1）
       └─ MethodChannel controlEvent
            └─ ControlClient（Dart）── 27184 ──▶ ControlServer（独立线程/连接）
                                                     └─ InputInjector
                                                          └─ InputManager.injectInputEvent
```

- **协议**（`lib/src/control/control_message.dart` + `ControlProtocol.java`）：
  `1 字节类型 + 4 字节大端长度 + payload`；触摸为两个大端 float32（0.0–1.0），
  按键/滚轮为 int32。类型：0x01 按下、0x02 移动、0x03 抬起、0x04 滚轮、
  0x05 按键按下、0x06 按键抬起；**0x10 停止服务**（仅控制 App → 服务端，空 payload）。
  0x10 是 Shizuku 断开后仍能停止服务的路径：捕获进程是 shell 进程，App 不能
  `pkill`，但可以让服务端自己退出；旧服务端会忽略该类型，App 发完后探测 27184 确认。
- **动态 letterbox**（`LetterboxGeometry.java` + `InputMapping.java`）：服务端不再
  硬编码 1008×720 / 136 边距。每次创建虚拟显示后，用编码器尺寸
  （`videoWidth × videoHeight`）和源显示真实尺寸（`Display.getRealSize()`，回退顺序
  `DisplayInfo.getRealSize` → natural mode → `mode.getPhysical*` → logical）按
  `scale = min(video/display)` 做 fit 计算内容区和边距：
  `content = round(display × scale)`、`offset = (video - content) / 2`。
  `getRealSize()` 给的是面板自然方向，而镜像内容跟随逻辑方向，因此先按 logical
  方向对齐（方向不同就交换宽高），保证 1280×720/2800×2000 → 1008×720/136 的映射。
  几何由 `VirtualDisplayCaptureBackend` 在创建显示后写入共享的 `InputMapping`（volatile）。
- **同一次会话内旋转**：`InputInjector` 在**每次注入前**轮询
  `Display.getRealSize()` 与 `Display.getRotation()`（`DisplayMetadata.currentState()`），
  与上次记录不一致时立即重算 `LetterboxGeometry`，打印
  `Input letterbox updated (rotation): ...` 并复位滚轮的悬停锚点。因此横竖屏切换后
  **不需要重连**（真机实测：竖屏 514×720/383 → 旋转 → 横屏 1008×720/136）。
- **坐标映射**：归一化 → ×video 尺寸（视频像素）→ 去掉动态 letterbox 内边距 →
  缩放到显示尺寸后注入。服务端打印完整映射，例如
  `norm=(0.5007,0.4988) video=(640.8,359.2) display=(1402,997) content=1008x720 offset=(136,0)`。
- **滚轮（0x04）**：Windows 覆盖窗口把 `GET_WHEEL_DELTA_WPARAM` **原样**作为 int32
  payload 发送（正数=向远离用户的方向滚动）；服务端同样**原样**写入 `AXIS_VSCROLL`
  —— 真机实测 Android 的符号与 Windows 一致（`+120` 向上、`-120` 向下），此前的取反
  映射会让滚动方向相反。注入前先发一条 `ACTION_HOVER_MOVE` 把鼠标指针定位到最近一次
  0x02 移动的坐标（尚无移动时回退到显示中心），再在同一坐标发 `ACTION_SCROLL`，
  否则 Android 会因为没有指针位置而丢弃滚动。日志：
  `[control] wheel rawDelta=120 axisVScroll=120 hover=(1003,1396) hoverSource=last-move`。
- **Windows 捕获**：`NativeVideoView` 在输入未启用时 `WM_NCHITTEST` 返回
  `HTTRANSPARENT`（保持点击穿透，Flutter 手势不受影响）；控制连接建立后切到
  `HTCLIENT`，捕获 `WM_MOUSEMOVE` / `WM_LBUTTONDOWN/UP` / `WM_MOUSEWHEEL`
  （屏幕坐标转客户端）/ `WM_KEYDOWN/UP`，左键按下时 `SetFocus` 让键盘事件进入覆盖窗口。
  键位映射：方向键 → DPAD_*，Enter → 66，Esc → 4（BACK），Backspace → 67，Space/Tab 同步支持。
- **断线行为**：服务端只打印 `control disconnected: ...` 并回到 accept 循环；桌面端
  显示“控制已断开”，视频继续播放（`ControlLinkState` 与 `CastStatus` 完全分离）。
- **有线模式**为 27183（视频）和 27184（控制）各建立一条 `adb forward`。两条隧道统一
  由 `AdbForwards`（`lib/src/host/adb_forward.dart`）的 `List<(local, remote)>` 管理：
  安装时逐条尝试、单条失败不跳过后续；停止时**两条都尝试移除**并忽略单条失败，因此
  27184 建不出来也不会让 27183 的清理被跳过。无线/直连模式不创建任何 forward。

真机验证现场：Windows 捕获到一次 ESC，服务端把它注入为 Android BACK，
手机随即退回桌面（`mCurrentFocus=com.android.launcher`），预览同步跟随。

## 8. 记录层加密（PSK + AES-GCM）

加密是**独立的记录层**，位于 socket 与协议之间：`ScrcSocketClient` / `ControlClient`
只把字节交给 `SecureChannel`，SCRC 的魔数/长度字段和控制帧的类型字节完全没变。

```text
Socket → TcpTransport → SecureChannel(PskCipher) → SCRC / 控制协议解析
                         └─ 加解密、分片、重组；不解析任何协议字段
```

- **Transport**（[transport.dart](lib/src/transport/transport.dart)）：
  `Stream<Uint8List> get incoming` / `void send(Uint8List)` / `Future<void> close()`；
  `TcpTransport` 只包装现有 socket，连接/重试逻辑仍留在原客户端里。
- **SecureChannel**（[secure_channel.dart](lib/src/transport/secure_channel.dart)）：
  每次 `send` 按 64 KB 上限切分，每条记录 `[4 字节大端长度][12 字节随机 nonce]`
  `[密文][16 字节 GCM tag]`；`incoming` 按记录边界解密后还原字节流。
  > 记录前多了 4 字节长度：GCM tag 无法在字节流里界定记录边界，必须显式分帧。
- **PskCipher**（[psk_cipher.dart](lib/src/crypto/psk_cipher.dart)）：唯一的密钥
  与算法入口，16/24/32 字节对应 AES-128/192/256；空密钥时 `SecureChannel` 退化为
  透传并打印警告。
- **密钥来源**：服务端 `--psk-hex=<hex>`；桌面侧可用
  `--dart-define=SCREEN_CAST_PSK_HEX=...` 注入（UI 输入框已移除）；
  自动启动用 `--dart-define=SCREEN_CAST_PSK_HEX=...`。两端必须一致，否则解密失败。
- Android 侧对应 [PskCipher.java](android-server/src/main/java/com/example/screencast/server/PskCipher.java)、
  `SecureRecordOutputStream` / `SecureRecordInputStream`，记录格式与 Dart 完全一致。
- 解密失败时视频链路直接报错退出（不会静默出花屏），控制通道则退化为“控制已断开”，
  视频不受影响。

真机验证：服务端以 `--psk-hex=0011...eeff`（AES-128）启动，Windows 端填入同一
密钥后解码 742+ 帧、控制通道注入 ESC 成功让手机回到桌面；把客户端密钥改成错误值后
链路变为错误状态而不是花屏。

## 9. 一键投送（局域网发现 + PC 自动连接）

手机端在服务端启动后（或用户点快捷设置磁贴时）向局域网广播一条发现包；PC 端监听
UDP 27185，收到后如果“自动连接”开关打开且当前没有会话，就用现有的 **direct 模式**
直接发起连接。这条链路只负责“发现”，SCRC、控制协议、`SecureChannel` 记录格式和
D3D11 管线都**没有改动**。

```text
Android 控制 App                                   Windows 主机
─────────────                                      ────────────
服务启动成功 / 磁贴点击
  └─ DiscoveryBroadcaster.announce()
       遍历非 loopback IPv4 网卡
       每个网卡广播到自己的 broadcast:27185
       每秒 1 次 × 5 次
              │  {"type":"screencast-offer","ip":"192.168.1.134",
              │   "videoPort":27183,"controlPort":27184,"pskRequired":false}
              ▼
                                        CastOfferListener（bind 0.0.0.0:27185）
                                          ├─ JSON/端口校验
                                          ├─ 来源 IP 必须在本地某个 IPv4 子网内
                                          ├─ payload.ip 必须等于来源 IP
                                          └─ CastOfferEvent
                                                ▼
                                        AutoConnectPolicy
                                          ├─ 开关打开？当前空闲？
                                          ├─ 同地址 8 秒冷却（一次广播只连一次）
                                          ├─ pskRequired 校验
                                          └─ CastController.connectToOffer()
                                                └─ direct 模式 TCP 连接 → 现有链路
```

### 发现包字段

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `type` | string | 固定 `screencast-offer`，其它值一律忽略 |
| `ip` | string | 手机在该网卡上的 IPv4 地址；必须等于 UDP 来源地址 |
| `videoPort` | int | SCRC/H.264 端口，默认 27183 |
| `controlPort` | int | 输入注入端口，默认 27184 |
| `pskRequired` | bool | 运行中的服务端是否带 `--psk-hex` |

端口必须落在 1024–65535 且两者不同；`pskRequired` 缺省按 `false` 处理。

### PC 端规则（多网卡安全）

- 套接字 `bind 0.0.0.0:27185`，多网卡时所有网卡都能收到；`reuseAddress=true` 允许
  桌面端重启后立即重新绑定。
- **子网校验**：来源 IP 必须落在本机某个非 loopback IPv4 子网内。前缀长度在 Windows
  上通过 `GetIpAddrTable`（iphlpapi，`dart:ffi`）读取真实掩码；读不到时退化为 /24
  （只会更严格，不会放宽）。
- **地址一致性**：`payload.ip` 必须等于 UDP 来源地址，否则丢弃。这可以挡住“同一网段
  转发/伪造的包把桌面指向另一台设备”。
- 丢弃 loopback、169.254/16 与 IPv6 来源；非 JSON、错 `type`、错端口都会带原因写日志。
- 同一手机地址 8 秒内只尝试一次连接；广播连发 5 次只会在 PC 上触发 1 次连接。
- 会话运行中收到广播直接忽略，不会打断正在投屏的画面。

### PSK 语义

- **发现包不携带任何密钥**，只带“这台服务端要不要密钥”的布尔值。
- `pskRequired=true`：PC 用 UI 里配置的 PSK 连接；**没配置就直接报错**（状态栏红字
  + 自动弹出主窗口），不会发一次注定失败的握手。
- `pskRequired=false`：即使 UI 里填了 PSK，PC 这次也**不带密钥**连接（手机端是明文
  服务端）。手动启动会话时仍按 UI 配置走，两者互不影响。
- 密钥不一致时链路会在 GCM 校验处断开；错误信息里会追加
  “若手机端 --psk-hex 与桌面 PSK 不一致，会在此处断开”的提示，并且自动连接过的会话
  一旦进入异常状态会把主窗口带到前台，不会静默停在托盘。

### 安全边界

- UDP 广播是**无认证的发现协议**：同网段任何人都能伪造一条 offer。它的能力上限是
  “让桌面主动去连一个同网段地址”，既不能注入输入、也不能解密视频；真正的会话仍然
  要过 SCRC + `SecureChannel`，PSK 不同就握不上。
- 只连接**同子网**且 payload 与来源一致的主机；跨网段、跨网卡的包直接丢弃。
- 广播只在服务启动后 5 秒内发送，不做周期性心跳，减少被扫描面。
- 产品化前建议给 offer 加签名或让 PC 弹一次“是否信任该设备”的确认。

### 使用方式

桌面端：

```powershell
# 启动时直接打开自动连接（等价于在 UI 里打开“自动连接（局域网发现）”开关）
flutter run -d windows --dart-define=SCREEN_CAST_AUTOCONNECT=true
```

手机端：Shizuku 授权后点快捷设置磁贴（或主界面“启动服务”）。服务端起来的同时就会
广播；PC 端在 1 秒内开始连接。

> **Windows 防火墙**：首次运行需要允许 `screen_cast_demo.exe` 的入站 UDP（专用网络）。
> 被防火墙静默拦截时 PC 侧只会停在“已监听 UDP 27185，等待手机广播…”，不会报错。
> 排查命令：`netsh advfirewall firewall show rule name=all dir=in | findstr /i screen_cast`。

### 本轮验证（真机 + 真 UDP 包）

- **完整链路（手机 App 自己广播）**：OPPO Android 14 + Shizuku 生效后，手机上点
  “启动服务”，App 以 shell 身份拉起服务端并广播；桌面端在点击后 **1.21 s** 打印
  `[discovery] offer from 192.168.1.134 ...` → `正在自动连接` →
  `[hwaccel] D3D11VA decode enabled` → `[tcp] …:27183 TCP_NODELAY=true` →
  `已自动连接`，独立视频窗口自动出现并显示手机画面（连续 371 帧硬解、0 丢弃），
  控制通道 27184 同时连上。
- **PSK 分支**：`pskRequired=true` 且桌面未配密钥时给出明确错误、不发起连接；
  `pskRequired=false` 时即使 UI 里填了密钥也按明文连接。
- **PC 未运行**：向本机 27185 连发 5 个包，手机服务端继续监听 27183（TCP 探测通过），
  广播对服务端没有任何影响。
- **磁贴点击（已复测）**：磁贴显示“投屏 · 已停止/异常”时点一下 → 服务端启动、广播
  offer → PC 自动连接（常规 **1.36 s**、进程被杀后冷启动 **1.19 s**）；显示“运行中”
  时点一下 → 停止并断开。连续两轮 启→停→启→停 状态都稳定（`RUNNING`/`STOPPED`），
  没有出现“点不动/关不掉”。
- **App 与磁贴联动（本轮修复）**：磁贴启动后变紫、显示“投屏 · 运行中”，此时打开 App
  直接显示“状态：运行中”；App 在前台时下拉磁贴点“停止”，回到 App 不需要切换界面就变成
  “状态：已停止”。冷启动的磁贴不再误显示“未授权”，而是直接显示“已停止”。
- **打开 Shizuku**：管理器包名按真机 `pm list packages` 修正为
  `moe.shizuku.privileged.api`（原代码写的是 `moe.shizuku.manager`，所以永远提示
  “未找到 App”）；`<queries>` 同步修正，`resolve-activity` 可解析到其主界面。
  未在“Shizuku 未运行”状态下实点该按钮（会中断当前 Shizuku 会话）。
- **状态自愈（本轮修复，详见下一节）**：磁贴点击前用 TCP 探测 127.0.0.1:27184 判断
  “到底有没有在监听”；进程重启时用同一探测对齐缓存状态；前台服务 watchdog 在进程
  消失后 ≤2 s 把状态改为“异常”并撤掉通知。
- 单测覆盖跨子网、loopback、169.254、坏 JSON、错端口、payload 与来源不一致，以及
  “5 次广播只连 1 次”和 PSK 的两种分支。

### 磁贴“做反了”的根因与修复

用户看到的现象是“磁贴显示运行中却连不上、点一下先跳停止再跳运行、之后点不动”，
以及“App 界面要切后台再回来才更新、磁贴和 App 像两个应用”。复现后根因有五个，
都是**状态共享与进程生命周期**的问题，不是方向写反：

1. **状态存储被实例化了多份**（最关键）：Activity、前台服务、`ServerLauncher`、磁贴
   各自 `new CastStateStore(...)`，而监听器列表是实例内的。SharedPreferences 文件共享，
   但写操作只通知**自己实例**的监听器 → App 收不到 Service 的状态变化（要切后台再回来
   才会重新读取），磁贴也收不到（一直停在“启动中/停止中”，也不会变紫/变白）。
   修复：`CastStateStore` 改为**进程内单例** `getInstance()`，四处调用点全部改用它。
2. **冷进程误判未授权**：ColorOS 杀掉 App 后点磁贴会把进程重新拉起来，此时 Shizuku
   binder 还没 attach，`checkAuthorized()` 立即返回 false → 磁贴显示“未授权”并跳转 App。
   修复：`awaitAuthorization()` 在 binder 缺席时最多重试 10×150 ms，点击和刷新路径都
   用它；只有 binder 存在但权限缺失才判定未授权。
3. **“打开 Shizuku”找不到 App**：代码与 `queries` 里写的是 `moe.shizuku.manager`，
   而 Shizuku 管理器的实际包名是 `moe.shizuku.privileged.api`（`pm list packages`
   实测），所以 `getLaunchIntentForPackage` 永远返回 null。两处都已改正。
4. **缓存状态过期**：进程被杀后 `CastStateStore` 仍停在 `RUNNING`，磁贴显示“运行中”。
   修复：`ServerLauncher` 初始化时用控制端口探测对齐状态（`RUNNING`/`STOPPED`），并与
   start/stop 共用同一把互斥锁，避免与启动过程互相覆盖。
5. **停止结果不可靠 + 启动闪烁**：`pkill` 偶发报错时状态被写成“异常”（服务端其实已停）；
   前台服务在 `startFailed` 状态下收到停止请求会提前返回，通知残留；启动前多写一次
   `STOPPED` 还会让磁贴“停止 → 启动中 → 运行中”跳变。修复：停止后以**控制端口是否
   关闭**为准写最终状态（等待最多 ~2.4 s）；`ACTION_STOP` 在失败/进程已消失时直接
   `stopForeground + stopSelf`；粘性重启不再静默启动第二个服务端；启动前不再写 `STOPPED`。



## 10. 帧率限制（`--target-fps`）与帧率可观测性

### 服务端

`ServerOptions` 新增 `--target-fps=<n>`（默认 `0` = 不限制，范围 0–240）。服务端在创建
虚拟显示后、`codec.start()` 之前，通过反射调用
`Surface.setFrameRate(n, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE,
CHANGE_FRAME_RATE_ONLY_IF_SEAMLESS)`（Android 11 / API 30+；更低版本打印一次“不支持”）。
调用失败只打印原因，不崩溃、不改任何编码参数。

5 秒后服务端把该窗口的实际帧数与目标比较一次：

```text
[encoder] target-fps=60 hint applied via Surface.setFrameRate
[encoder] target-fps=60 actual=98 (hint ignored by ROM)     # 或 (hint applied)
```

**被忽略时不做应用层丢帧**：H.264 的 P 帧有参考依赖，丢 P 帧会花屏，所以这里只如实上报。

### PC 端开关

设置面板新增 **“限制 60 帧（降低带宽和编码器负载）”**，默认关闭，状态持久化到
`%APPDATA%\ScreenCast\config.json`（`{"limit60Fps": false}`）。开启后，由桌面启动服务端
的 `wired` / `wireless` 模式会在命令行追加 `--target-fps=60`；`direct` 模式由手机侧启动
服务端，桌面无法传参，开关不生效。开关下方提示：

> 仅当手机端支持帧率提示时生效；无效时请到 设置 → 显示与亮度 → 屏幕刷新率 选
> “标准刷新率（60 Hz）”（实测有效）

### Android 控制台

主界面状态卡片下方增加一行“编码帧率：…”，数据由 App 通过 Shizuku 读取
`/data/local/tmp/screencast-server.log` 并解析 `[encoder] target-fps` 或
`[encoder] 1s ... frames=N` 得到（每 4 秒刷新一次），不新增任何控制协议字段：

```text
编码帧率：60fps（已限制，实际 59fps）
编码帧率：60fps（提示被忽略，实际 98fps）
编码帧率：97fps（未限制）
```

### 真机结论（OPPO OPD2201 / Android 14 / 120Hz 面板）

| 配置 | `[encoder] 1s` 实测 | 结论 |
| --- | --- | --- |
| `--target-fps=60`，系统高刷新率（120Hz） | frames 96–98/s，`actual=98 (hint ignored by ROM)` | **ROM 忽略该提示** |
| 系统设置 → 显示与亮度 → 屏幕刷新率 → **标准刷新率（60 Hz）** | `mActiveModeId=4`、`mActiveRenderFrameRate=60`，frames 60–61/s | **UI 开关有效** |
| `settings put system peak_refresh_rate 60`（实验 A 结论） | SurfaceFlinger 仍 120/144Hz | 无效 |

因此“限制 60 帧”的如实定位是：**服务端尝试提示；本机 ROM 忽略提示时，UI 引导用户去
系统设置里切 60 Hz**，而不是假装生效或改用应用层丢帧。

## 目录

```text
.
├── pubspec.yaml
├── lib/
│   ├── src/
│   │   ├── cast/          # CastController / 会话状态
│   │   ├── ffmpeg/        # dart:ffi FFmpeg 绑定与解码器
│   │   ├── host/          # AdbLauncher / AdbForwards（27183+27184 隧道列表）
│   │   ├── pipeline/      # NAL 队列、ADB→Socket→解码编排
│   │   ├── protocol/      # 既有 SCRC 协议（未修改）
│   │   ├── control/       # 控制通道：ControlMessage / ControlClient
│   │   ├── crypto/        # PskCipher（AES-GCM 密钥管理）
│   │   ├── discovery/     # UDP 27185 发现：offer 解析 / 子网校验 / 自动连接策略
│   │   ├── transport/     # Transport / TcpTransport / SecureChannel / ScrcSocketClient
│   │   ├── ui/            # 设备扫描列表、关于页、控制面板
│   │   └── windows/       # 独立视频窗口桥 / NV12 上传 / 托盘状态推送
│   └── ...
├── packages/
│   ├── screen_cast_windows/       # Windows HWND + D3D11 插件
│   └── screen_cast_android/       # 上一版遗留，不再被依赖
├── android-app/                   # Shizuku 控制 App（权限、ServerLauncher、磁贴）
├── android-server/                # Java 捕获服务端（letterbox / 输入注入 / 加密）
├── assets/server/                 # 编译好的 classes.dex jar
├── third_party/ffmpeg/            # 本地 DLL 缓存（DLL 被 gitignore）
├── tool/
│   ├── build_server.ps1
│   ├── check_server.ps1           # 纯 JVM 检查（含 letterbox/滚轮）
│   ├── fetch_ffmpeg.ps1
│   ├── adb_launch.ps1 / .sh
│   └── device_e2e_test.dart       # 支持 SCREEN_CAST_WIRELESS/HOST
├── windows/                       # 按用户要求保留的 Flutter Windows runner
├── test/
└── docs/architecture.md
```

## 首次运行

### 1. FFmpeg 运行库

本工作区已经安装并验证。若换机器：

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\fetch_ffmpeg.ps1
```

### 2. 编译服务端 jar

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\build_server.ps1
```

产物：[`assets/server/screencast-server.jar`](assets/server/screencast-server.jar)
（内含 `classes.dex`）。服务端新增 `--bind-address`，默认 `127.0.0.1`。

纯 JVM 检查（不需要设备，覆盖 letterbox 几何与滚轮符号换算）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\check_server.ps1
```

### 3. Flutter

```powershell
flutter pub get
flutter test
flutter run -d windows
```

`windows/` runner 已保留。本机的 Visual Studio Build Tools 2026 位于
`D:\VSBuildTools`（MSVC v143 + Windows SDK 10.0.26100），Flutter 通过 vswhere
识别它。无需安装 VS IDE；`flutter build windows` / `flutter run -d windows`
已经可用。

### 4. 设备

打开 USB 调试并授权 RSA。运行应用后，在**设备与连接**面板里：

- 点 **扫描设备**：
  - USB：执行 `adb devices`，已授权设备显示 `usb` 图标与序列号；
  - 局域网：对每个本地 /24 的 **27184 控制端口**做一次并发 TCP 探测（200 ms 超时、
    32 并发），能找到手机控制 App 已启动的服务端（显示 `wifi` 图标与 IP）。
    **不探测 27183**：视频监听会把任何连接当成“新观众”并重建捕获（重复 `Sent IDR`、
    编码窗口拉长到数秒），投屏时会造成周期性卡顿；自动扫描在会话运行期间跳过。
- 点某个设备即可连接：
  - **USB** 走 wired 模式：`adb push` + `adb forward` + `app_process`，再连
    `127.0.0.1:27183`；
  - **局域网** 走 direct 模式：桌面不执行任何 ADB 命令，只连 `<手机IP>:27183`
    （手机控制 App 需先处于运行中）。
- **自动连接（发现即连）** 打开后：UDP 27185 的 offer 会直接触发连接，同时每 5 秒
  自动扫描一次，USB 插入或手机开始广播都会在后台自动连上并弹出视频窗口。

> 原来的“有线 / 无线 / 直连”三选一和 “局域网 IP” 输入框已合并到设备列表；预共享密钥
> 输入框已移除（服务端仍支持 `--psk-hex`，但本界面不再提供设置入口）。

调试时可自动启动指定模式（默认关闭）：

```powershell
flutter run -d windows `
  --dart-define=SCREEN_CAST_AUTOSTART=true `
  --dart-define=SCREEN_CAST_WIRELESS=true `
  --dart-define=SCREEN_CAST_HOST=192.168.1.23
```

App 直连模式（桌面不碰 ADB）：

```powershell
flutter run -d windows `
  --dart-define=SCREEN_CAST_AUTOSTART=true `
  --dart-define=SCREEN_CAST_DIRECT=true `
  --dart-define=SCREEN_CAST_HOST=192.168.1.134
```

无线真机 E2E：

```powershell
$env:SCREEN_CAST_WIRELESS='1'
$env:SCREEN_CAST_HOST='192.168.1.23'
flutter test tool\device_e2e_test.dart
```

> 安全提示：SCRC 没有认证/加密。`0.0.0.0` 会把无认证的 H.264 流暴露给同网络
> 可路由主机；**27184 控制通道同样没有认证，能连上就能注入触摸/按键**；无线模式
> 还会临时开放 **ADB/TCP 5555**。仅在可信局域网使用，产品化前必须增加鉴权/加密并
> 限制端口来源。

服务端会用反射创建虚拟显示并启动 MediaCodec surface 输入编码。若设备拒绝隐藏
显示 API 或编码器配置，adbd shell 日志会打印 DisplayManager / SurfaceControl /
MediaCodec 的完整失败原因，UI 会显示链路错误；不会假装在播放视频。捕获成功后，
FFmpeg 解出的 YUV420p 帧会写入 D3D11 NV12 纹理并显示在原生预览区域。

## SCRC 协议（未修改）

| 偏移 | 长度 | 字段 |
| ---: | ---: | --- |
| 0 | 4 | `0x53435243`（`SCRC`），大端 |
| 4 | 4 | NAL payload 长度，大端，1..16 MiB |
| 8 | N | 单个 H.264 NAL，不含 Annex-B 起始码 |

SCRC 协议文件（`lib/src/protocol/scrc_packet*.dart` 及
`ScrcPacketWriter.java`）保持不变。Java 服务端从占位替换为虚拟显示 + MediaCodec；
Windows 预览从 D3D11 纯色占位替换为 NV12 纹理和像素着色器呈现。ADB 启动和 socket
只消费既有格式。

控制通道是**另一条独立协议**（见“7. 控制通道”），不影响 SCRC 的任何字段或时序。

## 验证状态

已通过：

- `flutter analyze`：0 issues
- `flutter test`：100 个测试通过，覆盖 SCRC、socket 分片解析、有界队列、ADB
  设备解析、jar asset、UI 骨架、FFmpeg 真实解码、YUV420p→NV12 写入布局、
  传输模式配置（含 `direct` 不启动 ADB）、无线模式 UI、可配置 socket host、
  无线恢复入口、控制帧编解码与真实 socket 收发/断线、记录层加密
  （往返一致、篡改报错、SCRC/控制字节穿透、透传、非法记录长度）、
  forward 列表（wired 两条隧道、单条失败不跳过、清理幂等、滚轮 delta 原样透传）、
  发现协议（offer 解析/端口冲突/坏 JSON、掩码→前缀、跨子网与 loopback/169.254 过滤、
  payload 与来源不一致丢弃、5 次广播只连 1 次、PSK 两种分支、`pskForOffer` 语义）
- FFmpeg 解码：15 帧 320x180 YUV420p
- Java 服务端：`javac` + d8 构建成功，jar 内含 `classes.dex`
- Java 辅助检查（`tool/check_server.ps1`）：Annex-B / 长度前缀 NAL 拆包、
  `ServerOptions` 解析（含默认/`0.0.0.0` bind address、`--control-port`、
  `--psk-hex`）、letterbox 几何（4:3 / 竖屏 / 相同比例 / pillarbox / 方形源）、
  归一化→显示坐标映射与边距 clamp、`InputMapping` 旋转重算（含 `DisplayState`
  方向/尺寸变化与横竖屏中心点）、滚轮符号（同号直传：`120 → 120`、`-120 → -120`、
  `0 → 0`、保留亚刻度精度）
- PowerShell 启动/构建脚本可解析；`build_server.ps1` 会把 jar 同步进
  `android-app/app/src/main/assets/`
- **记录层加密（真机验证，OPPO Android 14）**：
  - 服务端以 `--psk-hex=0011…eeff`（AES-128）启动，日志输出
    `Payload encryption enabled: AES-GCM record layer over SCRC and control channels`；
  - Windows 端填入同一密钥后 SCRC 解密成功，连续解码 742+ 帧；控制通道同样解密，
    ESC 注入后手机退回桌面；
  - 客户端改用错误密钥后链路进入错误状态（没有花屏帧），说明 GCM 校验生效。
- **控制通道（真机验证，OPPO Android 14）**：
  - 服务端同时监听 27183 与 27184，日志输出
    `Control server listening on 0.0.0.0:27184 (video 1280x720)`；
  - 注入初始化在 Android 14 上走 binder 回退（`InputManager.getInstance()` 抛
    空指针），最终 `injection=ready`；
  - 映射链实测：`norm=(0.5007,0.4988)` → `video=(640.8,359.2)` →
    `display=(1402,997)`，与 2800×2000 显示中心一致（当时的 1008×720/136 内边距是
    硬编码值；现在由 `LetterboxGeometry` 按同一组尺寸算出相同结果，
    `CaptureCoreCheck` 把它固化成回归检查）；
  - 通过覆盖窗口投递 `WM_MOUSEMOVE` / `WM_LBUTTONDOWN/UP` / `WM_KEYDOWN/UP`，
    服务端依次记录 `touch move/down/up` 与 `key down/up`；
  - ESC → keycode 4 注入后手机从控制 App 退回桌面
    （`mCurrentFocus=com.android.launcher`），证明事件真正进入输入系统；
  - 控制 socket 断开不影响视频（日志仅 `control disconnected`）。
- **控制通道本轮真机验证（OPPO Android 14 / API 34，有线 + 直连两种模式）**：
  - **有线第二条 forward**：会话启动后 `adb forward --list` 同时出现
    `tcp:27183 tcp:27183` 与 `tcp:27184 tcp:27184`；随后通过覆盖窗口点击桌面
    “Screen Cast Controller” 图标，服务端记录
    `[control] touch down/up ... display=(847,1164)`（目标图标中心 850,1166），
    手机 `topResumedActivity=com.example.screencast.controller/.MainActivity`，
    说明 27184 控制通道已建立且注入生效。
  - **滚轮符号（本轮修复）**：覆盖窗口投递 `WM_MOUSEWHEEL`，服务端日志为
    `[control] wheel rawDelta=120 axisVScroll=120 hover=(1003,1396) hoverSource=last-move`
    （`hoverSource` 是 `last-move` 而不是 `display-center`，悬停定位生效）。
    实测 `+120` 让“设置 → WLAN”列表向上滚回顶部、`-120` 向下；浏览器（Chrome，
    Baidu 搜索结果页）同样 `-120` 向下滚到底部、`+120` 回到顶部（截图字节
    1,042,405 → 601,234 → 1,042,411，UI dump 文本同步变化）。**此前的取反映射
    会让两个方向都相反，本轮把 `WheelMapping` 改为同号直传并同步了 JVM 检查。**
  - **同一次会话内旋转（本轮新增）**：直连模式下（桌面不执行任何 adb 命令，
    服务端由手机侧 `app_process` 以 0.0.0.0 启动，PC 直连
    `192.168.1.134:27183/27184`）竖屏点击上述图标 → `display=(847,1164)` 命中；
    随后 `settings put system user_rotation 1` 旋转，**不重连**，服务端立即打印
    `Input letterbox updated (rotation): video=1280x720 content=1008x720 offset=(136,0)
    display=2800x2000 rotation=1 (content box recomputed)`（旋转前是 514×720/offset 383），
    横屏重新 dump 图标位置后再次点击 → `display=(1217,877)`（目标 1215,876），
    同一个 App 再次打开。两次命中的注入坐标与 `uiautomator` 给出的图标中心相差 ≤3 px。
- **Android 控制 App / Shizuku 集成**：
  - `android-app` Gradle 构建成功，生成约 1.4 MB debug APK；
  - `:app:lintDebug`：0 errors（3 个既有 warning：`OldTargetApi`、
    `DataExtractionRules`、1 个未使用字符串）；
  - **前台服务（本轮改动）**：`assembleDebug` + `lintDebug` 通过；合并后的
    manifest 含 `ScreenCastForegroundService`（`foregroundServiceType="specialUse"`
    + `PROPERTY_SPECIAL_USE_FGS_SUBTYPE`）。运行时行为（通知、停止 action、
    通知权限、ColorOS 跳转）尚未在真机验证；
  - 声明的 `ShizukuProvider`、`BIND_QUICK_SETTINGS_TILE`、`QS_TILE` 和
    `QS_TILE_PREFERENCES` 已进入合并后的 manifest；
  - 在 OPPO Android 14 真机上安装、启动主界面成功；
  - **快捷设置磁贴（OPPO Android 14 / API 34）**：
    - 主界面“添加到快捷设置”触发 `StatusBarManager.requestAddTileService`
      系统对话框；确认后 `com.android.systemui` 绑定了
      `ScreenCastTileService`，`sysui_qs_tiles` 追加
      `custom(com.example.screencast.controller/.ScreenCastTileService)`；
    - 磁贴实际渲染出运行时标签“投屏 · 未授权”、斜杠投屏图标和副标题
      “点按打开授权”，说明 `onStartListening()` 的后台核对和图标/标签刷新生效；
    - 服务端运行后磁贴切换为“投屏 · 运行中”、实心投屏图标和激活底色，
      `Tile.STATE_ACTIVE` 生效；
    - `adb shell cmd statusbar click-tile`（走真实 `onClick()`）弹出
      “请先打开 App 完成 Shizuku 授权”并拉起主界面，API 34 的
      `PendingIntent` 重载路径没有抛异常；
    - 长按磁贴时 SystemUI 以
      `act=android.service.quicksettings.action.QS_TILE_PREFERENCES`
      启动 `MainActivity`（`launchedFromPackage=com.android.systemui`），
      manifest 长按路由生效；
    - 上述交互全程无 `AndroidRuntime` 崩溃、logcat 无异常；验证后已移除磁贴；
  - **Shizuku 运行时链路（OPPO Android 14，Shizuku 已激活）**：
    - App 启动即弹出 Shizuku 授权对话框，点“始终允许”后界面变为
      “Shizuku 已连接并已授权”，启动/停止按钮按状态启用；
    - 点“启动服务”通过 `IShizukuService.newProcess` 以 shell UID 2000 启动
      `app_process`，界面变为“运行中”，`/data/local/tmp/screencast-server.log`
      打印 `Server UID=2000 SDK=34` 与
      `SCRC server listening on 0.0.0.0:27183`，`netstat` 确认端口监听；
    - **桌面直连回显**：Windows 端用 `direct` transport 连接
      `192.168.1.134:27183`，不执行任何 ADB 命令，FFmpeg 解出 1280x720 并连续
      上传 D3D11 NV12 纹理，帧计数从 1 增长到 2205+；切换手机屏幕（通知栏、
      主界面、控制 App）后 Windows 预览实时跟随，证明是实时镜像而非静止帧；
    - 服务端对每个新 viewer 重新创建虚拟显示（`displayId` 26 → 27），断开后继续
      监听，因此桌面反复重连不需要重启手机侧进程。
- **Android 真机验证（OPPO OPD2201，Android 14 / API 34）**（可重跑：
  `flutter test tool\device_e2e_test.dart`）：
  - ADB 推包/启动成功，服务端以 shell UID 2000 运行。
  - `DisplayManager` 路径成功：`VirtualDisplay displayId=3`，
    `c2.mtk.avc.encoder`，`KEY_LOW_LATENCY=1`。
  - 手动抓取 244,407 字节 SCRC，18 个完整 NAL，FFmpeg 解出 14 帧 1280x720。
  - 强制 `--display-backend=surfacecontrol` 也成功，FFmpeg 解出 11 帧
    1280x720。
  - 完整 Dart 链路 `AdbLauncher → socket → FFmpeg` 的真机 E2E 测试通过。
  - **有线模式**：`127.0.0.1:27183` + `--bind-address=127.0.0.1` + forward，
    解出 3 帧 1280x720；结束后 forward 被移除。
  - **无线模式**：手机 `192.168.1.134`、Windows `192.168.1.203` 同一局域网；
    `--bind-address=0.0.0.0`、**无 `adb forward`**，客户端直连
    `192.168.1.134:27183`，解出 3 帧 1280x720。
  - **实际拔 USB 验证**：旧 app_process 被 adbd 清理后，控制器通过仍连接的
    ADB/TCP `192.168.1.134:5555` 自动重启服务端并重连 socket；端口 27183
    恢复，帧计数从约 720 继续增长到 1328+，USB 保持拔出。
  - 完整 Windows UI 在无线模式自动启动成功，视频持续显示。

- **Windows 原生渲染验证**：
  - `flutter build windows --debug` 成功，插件
    `screen_cast_windows_plugin.dll` 编译并加载。
  - 应用启动后，独立视频窗口（`ScreenCastVideoWindow`，`WS_POPUP | WS_THICKFRAME`、
    无 owner）出现在屏幕上并居中于主窗口所在显示器；UI 显示 `Win32 · D3D11`。
  - **真机画面已实际呈现在 D3D11 NV12 纹理上**：1280x720，UI 连续计数超过
    1400 帧，颜色正常。
  - Dart 通过 `configureFrame` 返回的两组原生 CPU 指针轮换写入 NV12 staging
    texture；MethodChannel 不传输像素。
  - `presentFrame` 的 `Unmap → CopyResource → Map` 路径连续运行无崩溃，最后一帧
    在 WM_PAINT/最小化恢复后保持。
  - **双缓冲上传（本轮改动，真机验收已跑）**：`flutter analyze` 0 issues、
    `flutter test` 100 个测试通过、`flutter build windows --debug` 成功。
    OPPO Android 14 真机 + 有线 ADB，把手机刷新率锁到 60Hz 后连续动画 60 秒：
    解码 ≈60/s、上传 ≈60/s、**累计丢弃 26 帧（≈0.7%）**，全程无崩溃；期间故意
    `SIGSTOP` 服务端 6 秒再 `SIGCONT` 恢复，画面自动恢复、进程存活；随后
    `pkill` 服务端（等价于拔线不恢复），Windows 进程仍 `Responding=True` 且
    Windows 事件日志无崩溃记录，会话进入“异常”状态。
  - 移动主窗口后视频窗口不再跟随（两者已经是独立窗口）；其他前台窗口能正常盖住视频窗口。
  - 首版 `WS_CHILD` 方案被 Flutter 合成层遮挡，已改为 owned popup，本版再改为独立顶层窗口。
  - **D3D11VA 硬解（本轮改动，真机验收已跑）**：`[hwaccel] D3D11VA decode enabled
    (shared device)`，全部帧为 `D3D11VA`，`CopySubresourceRegion` 直接拷入 video
    texture（无 CPU 映射）。无线模式 60 秒连续滚动动画（手机 144 Hz 面板、服务端
    `[encoder] 1s` 117–127 帧/秒、16.1–17.7 Mbps）：
    `decoded ≈104–131/s`、`uploaded` 与 `decoded` **完全相等**、**dropped = 0**
    （改动前同一场景：decoded ≈120/s、uploaded ≈76/s、dropped ≈45/s ≈37%）。
    截图确认画面颜色/几何正确（竖屏内容居中，左右黑边）。
    测试环境无插件 DLL 时走软解回退，100 个单测全部通过。
  - **独立视频窗口 + 托盘驻留（本轮改动，真机验收已跑）**：
    `flutter analyze` 0 issues、`flutter test` 100 通过、`flutter build windows --debug`
    成功。应用启动后窗口探针读到
    `class=ScreenCastVideoWindow rect=(412,251)-(1212,701) 800x450 thickframe=yes
    owner=0`（=640×360 逻辑像素 × 125% DPI，居中于主窗口）；
    `taskbar` 出现 `screen_cast_demo - 2 个运行窗口`（主窗口 + 独立视频窗口）。
    - F11：`rect=(0,0)-(1920,1200) 1920x1200 thickframe=no`，画面铺满当前显示器；
      Esc：恢复到 `(412,251) 800x450 thickframe=yes`（位置/尺寸/样式全部还原）。
    - 视频窗口 `WM_CLOSE`：`visible=False`，进程存活；主窗口 `WM_CLOSE`：
      `mainVisible=False videoVisible=True`，进程存活（会话与视频继续）。
    - 托盘：`NotifyIcon` 回调消息 `WM_APP+0x51` 的双击路径能把主窗口重新显示
      （`mainVisible=True`）；右键路径弹出的菜单经截图确认是
      **显示主窗口 / 显示视频窗口 / 退出** 三项。
    - 托盘图标由 `Shell_NotifyIcon` 注册在**主窗口句柄**上，Windows 默认把它放进
      通知区溢出面板；图标绿/灰两态与 tooltip 文本由 Dart 每秒推送
      （`updateStatus`）。
    - 未在真机上点击验证：托盘菜单的 `显示视频窗口`/`退出` 两项（`退出` 会
      `DestroyWindow` 主窗口结束进程，无法回滚），以及溢出面板里图标的真实像素
      —— 这两条只做了代码审阅 + 同路径的 `Show/Hide`/菜单回调实测。

### 无线性能基线

无线模式（`SCREEN_CAST_WIRELESS=true`：桌面经 ADB/TCP 启动服务端，视频与控制直连
手机局域网地址），OPPO OPD2201 / Android 14，手机 `192.168.1.134` 与 PC
`192.168.1.203` 同一 /24 Wi-Fi；1280×720 H.264，编码目标 8 Mbps / 关键帧 1 s /
60 fps，手机面板默认 120 Hz，Windows 覆盖窗口 D3D11 双缓冲。

**帧率与丢弃（60 秒连续滚动动画，Baidu 结果页 + 滑动）**

| 指标 | 每秒值（60 s 窗口） |
| --- | --- |
| decoded | 中位 ≈120，范围 108–146 帧/秒 |
| uploaded | 中位 ≈76，范围 63–91 帧/秒 |
| dropped | 中位 ≈45，范围 38–69 帧/秒（≈37%） |

解释：手机面板 120 Hz（服务端 `[encoder] frames` 也是 110–134/s），而 Windows 的
呈现路径（DWM + 双缓冲）实测吞吐 ≈76 次/秒，源帧率高于呈现能力，因此多余帧按设计
丢弃——**这是显示吞吐上限，不是网络或上传管线的问题**。把手机刷新率锁到 60 Hz 后
（上一节有线实测）解码/上传各 ≈60 帧/秒、丢弃仅 ≈0.7%。

**码率**

| 来源 | 值 |
| --- | --- |
| 配置请求 | `KEY_BIT_RATE=8000000`、`KEY_FRAME_RATE=60`、`KEY_I_FRAME_INTERVAL=1` |
| 编码器实际输出 | `[encoder] effective(output) KEY_BIT_RATE=8000000 KEY_I_FRAME_INTERVAL=-1 KEY_FRAME_RATE=60`（厂商编码器不回读关键帧间隔） |
| 滚动动画实测 | ≈16 000–18 000 kbps（中位 ≈17 Mbps，帧数 110–134/s，`bytes` 2.0–2.3 MB/s） |
| 静态时钟页实测 | ≈2 800 kbps（≈144 帧/秒，画面几乎不变） |

注意：滚动内容下实测码率约为配置目标的 2 倍，说明该 MTK 编码器在 120 fps 输入下
并不严格收敛到 `KEY_BIT_RATE`，基线里应使用实测值而不是配置值。

**RTT / 丢包（`adb shell ping -c 100 192.168.1.203`）**

```text
100 packets transmitted, 100 received, +1 duplicates, 0% packet loss, time 99141ms
rtt min/avg/max/mdev = 3.795/16.335/117.328/17.820 ms
```

**端到端延迟（毫秒时钟 + 单帧截图法，3 次取中位数）**

测法：PC 用 `tool/clock_server.py` 在 `127.0.0.1:8080` 提供毫秒时钟页（页面用
`/time` 往返校准到 PC 时钟，取最小 RTT 样本），手机通过 `adb reverse tcp:8080` 打开；
再用 [`tool/control_probe.ps1`](tool/control_probe.ps1) 的 `captureprint` 直接
`PrintWindow` 视频窗口取一帧并记录捕获时刻，延迟 = 捕获时刻 − 画面里的时钟值。
窗口/托盘行为用 [`tool/window_check.ps1`](tool/window_check.ps1) 回归：读取独立
窗口 rect/样式，投递 F11/Esc，关闭窗口与主窗口，并截图通知区。
这是“秒表 + 相机”法的软件等价实现（相机换成了带时间戳的窗口截帧），分辨率约 ±20 ms。

| 配置 | 样本（ms） | 中位数 |
| --- | --- | --- |
| `TCP_NODELAY=true`（默认） | 82 / 53 / 82 | **82 ms** |
| `TCP_NODELAY=false`（Nagle 开启） | 87 / 73 / 78 | **78 ms** |

**TCP_NODELAY 对比结论**：差值 4 ms（方向甚至略偏向关闭 Nagle 一侧），远在 ±20 ms
测量噪声内，**低于 10 ms 阈值，不构成关键优化**。原因是视频路径每次写入都是
数十 KB 的连续分片、Nagle 几乎不会合并出额外延迟，端到端延迟由编码、Wi-Fi 传输、
解码和呈现决定；NODELAY 真正有意义的场景是 27184 控制通道那种 5–9 字节的小帧
（本轮未单独计时）。因此保留默认开启（无成本、对控制通道有潜在收益），但不把它
写进性能结论。

#### 诊断实验 A：60 Hz 锁定对照（丢帧归因）

第一次用 `settings put system peak_refresh_rate/min_refresh_rate 60` 锁定**没有生效**：
`dumpsys display` 显示 modeId=4（60 Hz 模式），但 `dumpsys SurfaceFlinger` 仍是
144.00 Hz，`[encoder] frames` 118–131/s，60 秒动画丢弃率仍 ≈37%。

改用**省电模式**（`settings put global low_power 1`）后 SurfaceFlinger 才真正降到
60.00 Hz，`[encoder] frames` 变成 59–61/s，同一套滚动动画 60 秒：

| 指标 | 真实 60 Hz 源（60 s 窗口） |
| --- | --- |
| decoded | 58–61/s（中位 60） |
| uploaded | 55–61/s（中位 59） |
| dropped | 0–5/s，累计 **47 / 4154 帧 = 1.1%** |

结论：丢帧从 **37% 降到 1.1%**，说明瓶颈确实是「源帧率 > 呈现吞吐」，不是上传管线；
剩余的 ≈1% 是偶发的 present 在途（双缓冲槽位冲突），属于正常抖动。测后已恢复
（`low_power 0`、删除 peak/min 键、厂商键 `oplus_customize_screen_refresh_rate=4`）。

#### 诊断实验 B：码率收敛诊断

先探测编码器能力（该探测日志已保留在服务端启动日志里，仅打印不改变行为；
CBR 设置是临时实验代码，已回退）：

```text
[encoder] c2.mtk.avc.encoder bitrateModes: CBR=false VBR=true CQ=false
[encoder] OMX.MTK.VIDEO.ENCODER.AVC bitrateModes: CBR=false VBR=true CQ=false
[encoder] c2.android.avc.encoder bitrateModes: CBR=false VBR=true CQ=false
[encoder] OMX.google.h264.encoder bitrateModes: CBR=false VBR=true CQ=false
```

**该设备上没有任何 AVC 编码器支持 CBR（也没有 CQ），只有 VBR。** 对照（同一动画、
144 Hz 面板、约 100–127 帧/秒）：

| 配置 | 实测码率（`[encoder] 1s`） |
| --- | --- |
| 默认：`KEY_FRAME_RATE=60`，VBR | 10.2–23.7 Mbps，中位 ≈20 |
| `KEY_FRAME_RATE=120` + `KEY_BITRATE_MODE=CBR` | 14.8–25.2 Mbps，中位 ≈18 |

CBR 请求被**静默忽略**：`configure()` 不报错，`effective(output)` 仍显示
`KEY_BIT_RATE=8000000`，但码率完全不收敛（因为硬件不支持该模式，回退到 VBR）。

**决定性对照**：同一默认配置在实验 A 的 **60 fps 输入**下实测 **7.7–8.1 Mbps**，
正好落在配置目标附近；144 Hz 输入下则是 17–20 Mbps。因此结论是
**「该编码器不支持严格 CBR，码率超调来自输入帧率」**——要收敛码率应把编码器输入
限制在 60 fps（例如限制虚拟显示/编码器输出帧率），而不是依赖 CBR。
实验用的 CBR 补丁是临时的，已回退，仓库默认仍是 VBR 配置。

#### 诊断实验 C：有线同方法基线（Wi-Fi 净值）

同一套毫秒时钟 + 单帧截帧法，有线模式（USB `adb forward`）3 次：

| 模式 | 样本（ms） | 中位数 |
| --- | --- | --- |
| 有线 | 63 / 63 / 65 | **63 ms** |
| 无线 | 82 / 53 / 82 | **82 ms** |

**净值 = 82 − 63 = 19 ms**（均值差 ≈9 ms）；两种判据都 ≤20 ms，所以
**Wi-Fi 传输开销很小**，82 ms 的主要成分是本地处理与显示节奏（编码、解码、双缓冲
呈现、DWM 合成）。按既定判据，码率收敛不是降低延迟的主要杠杆——它影响的是带宽占用，
而带宽侧的答案已由实验 A/B 给出：输入帧率降到 60 fps 后同一配置即可落在 8 Mbps 附近。

未验证：

- Android 10–13 真机：当前只有 Android 14 设备；10–13 的
  DisplayManager/SurfaceControl 兼容性仅做编译和代码审查。
- 前台服务：已在真机确认 `isForeground=true`、`specialUse` 类型和带 action 的常驻
  通知；仍缺“通知上的停止”“Android 13+ 权限弹窗拒绝后”“ColorOS 自启动/电池跳转”
  “划掉任务卡后服务仍存活”的运行证据。
- 控制通道：本轮已在真机验证滚轮（`0x04`，方向已修正为同号）、有线第二条
  `adb forward`（27183+27184 同时存在并完成点击注入）、以及**同一次会话内旋转**后
  的 letterbox 重算与横竖屏点击命中（直连模式）。仍未验证：多控制端并发、注入到
  系统弹窗/锁屏等安全层时的行为、以及 Android 10–13 上的滚轮/旋转表现。
- 磁贴停止路径：已真机验证“运行中 → 停止”（状态 `STOPPING → STOPPED`、服务端
  `app_process` 消失、PC 会话断开），以及停止后再次启动并重新连接；仍未验证
  binder death、启动超时、Android 7.0–12 的旧启动路径。
- 旋转/分辨率变化、多 slice、重连等产品级行为；布局断点通过 `GlobalKey` 保留
  预览 surface，但若 `NativeVideoSurface` 被真正移除/重建，设备没有立即产生新帧时
  会暂时显示占位色直到下一帧。
- 全范围 `yuvj420p` 的颜色准确性；当前 shader 固定 BT.601 limited-range。
- PlatformView：Windows 不支持，本实现是原生独立顶层视频窗口。
- 双缓冲上传剩余的验收细节：无线模式的 60 秒、延迟、RTT、码率以及 60 Hz 源的
  丢帧归因已在上面的“无线性能基线”实测；仍未验证：拔插网线的真实回归、更长
  （>10 分钟）的稳定性；手机与 PC 的刷新率组合不同（例如源 120fps、显示器 60Hz）时，
  **硬解后应用层不丢帧**：超过显示器刷新率的部分由 DWM 合成时丢弃，应用层的
  `dropped` 计数看不到，需要看“呈现 fps”（`getStatus.presentFps` / tooltip 的
  `呈现 Nfps`）。
- 码率策略：该设备编码器只有 VBR，无法用 CBR 收敛；把输入帧率限制在 60 fps 的
  落地实现（例如限制虚拟显示刷新或编码器丢帧）尚未做，本轮只做了诊断。

## 端到端状态与模式对照

| 模式 | 服务端启动方式 | SCRC 视频路径 | 拔 USB 后 | 当前状态 |
| --- | --- | --- | --- | --- |
| 有线 | USB ADB push + `adb forward`（27183 + 27184） | `127.0.0.1:27183` | 预期中断（视频依赖 USB） | 已真机验证 |
| 无线 ADB/TCP | USB 初始 push + `adb tcpip 5555` | `<手机IP>:27183` | 旧进程被 adbd 清理，App 自动通过 ADB/TCP 重启 | 已真机验证（短暂中断后恢复） |
| Android App 直连 | Shizuku 在手机上启动 jar | `<手机IP>:27183` + 控制 27184 | 不依赖 USB | **已真机验证**（1205+ 帧 1280x720，含输入注入） |

> 三种 transport 都已落地：`wired` / `wireless` 由桌面经 ADB 启动，`direct` 只连接。
> 桌面直连时 `CastSession` 不构造 `AdbLauncher`，因此拔掉 USB 完全不影响画面。

## 项目交接 / 后续任务

按优先级（详细状态见开头「项目现状（交接速览）」）：

1. ~~**前台服务 + 通知**~~ —— 已实现并在真机确认：`isForeground=true`、
   `specialUse` 类型、带“停止” action 的常驻通知；主界面与磁贴都经服务启停。
   仍缺：通知上的“停止”、任务卡划掉后存活、ColorOS 跳转的实际效果。
2. ~~**桌面 App 直连模式**~~ —— 已完成：`CastTransportMode.direct` 只连接
   `<phone-ip>:27183`，桌面不执行任何 ADB 命令，UI 增加“直连”分段入口。
3. ~~**控制通道（输入注入）**~~ —— 已完成：27184 独立 TCP 通道、双向分离、
   触摸/按键注入已在真机验证（含 BACK 生效）。滚轮（悬停定位 + 同号 `AXIS_VSCROLL`）、
   同一次会话内旋转的 letterbox 重算、有线模式第二条 forward 均已真机验证；
   点击命中在 2026-11 做了专门回归（见「项目现状」）。
4. ~~**记录层加密**~~ —— 已完成：`Transport` / `SecureChannel` / `PskCipher`
   三层，SCRC 与控制协议零改动，AES-GCM 已在真机跑通。仍缺：重放保护、
   密钥轮换、PSK 的带外交互（目前靠命令行/UI 手填）。
5. ~~**视频窗口独立化 + 托盘驻留**~~ —— 已完成：独立顶层窗口（自绘标题栏、锁比例
   缩放、全屏/最小化/关闭）、托盘图标与右键菜单、主窗口关闭不中断投屏。
6. ~~**硬解与比例/点击修正**~~ —— 已完成：D3D11VA 硬解 + 软解回退；按内容区裁切、
   按设备比例缩放、旋转跟随；点击按整帧归一化映射，真机误差 ≤3 设备像素。
7. **Shizuku 运行时的剩余验证** —— 已跑通授权弹窗、jar 写入、`app_process`、
   磁贴启停（含服务运行中点击停止）、一键投送、直连回显、前台服务前台态。仍缺：
   binder death、启动超时。
8. **Android 10–13** —— 当前捕获只在 Android 14 / API 34 真机验证。
9. **稳定性剩余项**：D3D device removed 后的渲染器整体重建、多 slice 帧、
   密钥帧恢复、前后台切换、多控制端并发。
10. **性能剩余项**：present 仍由 UI 线程驱动（高刷源无法跑满）；GDI fallback 无自动化
    覆盖；内容区探测已是触发式，但单次仍是整帧 Y 平面测量。

## 故障排查

### Windows 端

```powershell
flutter analyze
flutter test
flutter build windows --debug
```

- 找不到 FFmpeg DLL：确认 `third_party/ffmpeg/bin/avcodec-62.dll` 存在，或运行
  `tool/fetch_ffmpeg.ps1`。
- 找不到 Build Tools：`vswhere` 应找到 `D:\VSBuildTools`；Flutter doctor 的 Windows
  项应为绿色。
- 有线连接失败：确认 `adb devices` 只有一个 `device`，并检查 forward
  `adb forward --list`（有线模式应有 `tcp:27183` 与 `tcp:27184` 两条）。
- 控制通道没反应但视频正常：先看 `adb forward --list` 是否有 27184；再看停止日志，
  `adb forward cleanup skipped:` 表示某条移除失败（清理仍会继续尝试另一条）。
- 滚轮无效：服务端日志应有
  `[control] wheel rawDelta=120 axisVScroll=120 hover=(x,y) hoverSource=...`；
  `hoverSource=display-center` 说明客户端还没发过 0x02 移动，滚动会落在屏幕中心。
- 触摸位置偏移：看 `Input letterbox updated:` 的 `content=` / `offset=` 与
  `source=` 的比例是否一致；真实尺寸读取失败时会打印回退到 logical/encoder 的警告。
- 无线连接失败：确认手机与 PC 同一网段、`<phone-ip>:27183` 可访问、
  ADB/TCP 5555 未被防火墙阻断；检查 `/data/local/tmp/screencast-server.log`。
- 预览黑屏/纯色：先看 UI 是 `Win32 · D3D11` 还是 `GDI`；GDI 不承载视频。
  再检查 `configureFrame`/`presentFrame` 是否报错。
- 视频窗口不出现：确认 `create` 返回成功、`Win32 · D3D11` 已显示；窗口关闭后走
  托盘菜单「显示视频窗口」或按钮「显示视频窗口」重新打开（关闭只是 `SW_HIDE`）。
- 视频窗口挡住主窗口/位置奇怪：它是独立顶层窗口，位置/尺寸由用户拖动与缩放决定，
  不再跟随主窗口；双击标题区或 F11 进入全屏、Esc 退出。
- 自动连接没反应：先看桌面端是否打印
  `[discovery] listening on udp/0.0.0.0:27185`，以及手机上服务端日志里有没有
  `SCRC server listening on 0.0.0.0:27183`（服务端绑定 127.0.0.1 时 PC 连不上）。
  再看 Windows 防火墙是否允许了该 exe 的入站 UDP；被拦截时日志里只有监听行、
  不会有任何 `[discovery] offer`。
- 自动连接报“要求 PSK”：手机服务端是用 `--psk-hex` 启动的，而桌面 UI 已不再提供
  PSK 输入框；需要加密时用 `--dart-define=SCREEN_CAST_PSK_HEX=<hex>` 重新构建桌面端，
  或者改用不带 `--psk-hex` 的方式启动服务端。
- 扫描不到局域网设备：确认手机控制 App 的“启动服务”处于运行中（服务端监听
  0.0.0.0:27183），并且 PC 与手机在同一 /24；扫描是按本地网卡的 /24 逐个探测
  27183 端口的，跨网段或防火墙拦截会扫不到。

### Android App / Shizuku

```powershell
cd android-app
.\gradlew.bat :app:assembleDebug
adb install -r app\build\outputs\apk\debug\app-debug.apk
```

- 显示“Shizuku 未运行”：安装 Shizuku，按 Android 11+ 无线调试流程激活，再返回
  App。
- 已激活但未授权：点击“请求 Shizuku 授权”；若拒绝，检查 Shizuku App 中的授权列表。
- 启动后服务立刻退出：读取
  `/data/local/tmp/screencast-server.log`；确认 `app_process` 能访问 jar、
  设备允许 shell 创建虚拟显示、编码器可用。
- Binder 断开：重新激活 Shizuku，回到 App；状态会变为异常/未授权。
- Tile 点击无反应：确认 Shizuku 已授权；Tile 点击会尝试启动/停止，长按由
  `QS_TILE_PREFERENCES` 打开 App。

## 关键文件索引

| 文件 | 作用 |
| --- | --- |
| [`lib/src/host/adb_launcher.dart`](lib/src/host/adb_launcher.dart) | USB/无线 ADB 启动、forward 编排、ADB/TCP 与自动恢复 |
| [`lib/src/host/adb_forward.dart`](lib/src/host/adb_forward.dart) | 27183/27184 隧道列表：逐条安装、幂等清理 |
| [`lib/src/transport/cast_transport.dart`](lib/src/transport/cast_transport.dart) | wired/wireless 配置和 endpoint |
| [`lib/src/transport/scrc_socket_client.dart`](lib/src/transport/scrc_socket_client.dart) | 可配置 host/port 的 SCRC socket |
| [`lib/src/pipeline/cast_session.dart`](lib/src/pipeline/cast_session.dart) | ADB/socket/解码编排，existingTcpSerial 恢复入口 |
| [`lib/src/cast/cast_controller.dart`](lib/src/cast/cast_controller.dart) | UI 状态、无线自动恢复、发现自动连接入口 |
| [`lib/src/discovery/cast_offer.dart`](lib/src/discovery/cast_offer.dart) | 发现包模型与严格解析（type/端口/IPv4 校验） |
| [`lib/src/discovery/cast_offer_listener.dart`](lib/src/discovery/cast_offer_listener.dart) | UDP 27185 监听、子网与来源地址双重校验 |
| [`lib/src/discovery/local_subnet.dart`](lib/src/discovery/local_subnet.dart) | 本地子网表、掩码→前缀、同网段判定 |
| [`lib/src/discovery/windows_ip_table.dart`](lib/src/discovery/windows_ip_table.dart) | `GetIpAddrTable` FFI（Windows 真实掩码） |
| [`lib/src/discovery/auto_connect.dart`](lib/src/discovery/auto_connect.dart) | 自动连接策略：开关、冷却、PSK 分支、失败上报 |
| [`lib/src/ffmpeg/ffmpeg_decoder.dart`](lib/src/ffmpeg/ffmpeg_decoder.dart) | FFmpeg FFI H.264 解码：D3D11VA 硬解、软解回退、内容区检测 |
| [`lib/src/ffmpeg/ffmpeg_runtime.dart`](lib/src/ffmpeg/ffmpeg_runtime.dart) | libav* 函数绑定（含 `av_hwdevice_ctx_*`、`av_hwframe_transfer_data`） |
| [`lib/src/ffmpeg/ffmpeg_abi.dart`](lib/src/ffmpeg/ffmpeg_abi.dart) | FFmpeg 8.1.2 结构体偏移/枚举常量（运行时校验 `codec_id`） |
| [`lib/src/ffmpeg/frame_content_rect.dart`](lib/src/ffmpeg/frame_content_rect.dart) | 从首帧 Y 平面探测 letterbox 内容区（左右/上下黑边） |
| [`lib/src/ffmpeg/hardware_frame_bridge.dart`](lib/src/ffmpeg/hardware_frame_bridge.dart) | 同步调用插件 C 导出：取设备、`CopySubresourceRegion` 拷帧 |
| [`lib/src/windows/nv12_frame_writer.dart`](lib/src/windows/nv12_frame_writer.dart) | YUV420p→NV12 直接写入映射内存（支持按内容区裁切） |
| [`lib/src/windows/nv12_frame_buffer.dart`](lib/src/windows/nv12_frame_buffer.dart) | 双 staging texture 轮换、in-flight 丢帧 |
| [`lib/src/cast/cast_frame_stats.dart`](lib/src/cast/cast_frame_stats.dart) | 解码/上传/丢弃计数与每秒采样窗口 |
| [`lib/src/windows/native_video_surface.dart`](lib/src/windows/native_video_surface.dart) | 原生帧上传、创建/显示独立视频窗口、托盘状态推送 |
| [`packages/screen_cast_windows/windows/d3d11_renderer.cpp`](packages/screen_cast_windows/windows/d3d11_renderer.cpp) | NV12 纹理、shader、最后帧保留、硬解纹理拷贝 |
| [`packages/screen_cast_windows/windows/native_video_view.cpp`](packages/screen_cast_windows/windows/native_video_view.cpp) | 独立视频窗口、标题栏/全屏/缩放、输入捕获与坐标换算 |
| [`packages/screen_cast_windows/windows/hardware_frame_bridge.cpp`](packages/screen_cast_windows/windows/hardware_frame_bridge.cpp) | 3 个 `extern "C"` 导出：设备借用、同步拷帧（硬解路径） |
| [`packages/screen_cast_windows/windows/tray_icon.cpp`](packages/screen_cast_windows/windows/tray_icon.cpp) | 托盘图标（连接态两色）、tooltip、通知区回调 |
| [`android-server/src/main/java/.../Server.java`](android-server/src/main/java/com/example/screencast/server/Server.java) | SCRC 监听、bind address、共享 InputMapping |
| [`android-server/src/main/java/.../VirtualDisplayFactory.java`](android-server/src/main/java/com/example/screencast/server/VirtualDisplayFactory.java) | DisplayManager/SurfaceControl 捕获 |
| [`android-server/src/main/java/.../LetterboxGeometry.java`](android-server/src/main/java/com/example/screencast/server/LetterboxGeometry.java) | fit 计算内容区/边距、归一化→显示坐标 |
| [`android-server/src/main/java/.../InputMapping.java`](android-server/src/main/java/com/example/screencast/server/InputMapping.java) | 每次创建虚拟显示后重算并发布 letterbox |
| [`android-server/src/main/java/.../InputInjector.java`](android-server/src/main/java/com/example/screencast/server/InputInjector.java) | 触摸/按键注入、滚轮 hover+scroll |
| [`android-server/src/main/java/.../WheelMapping.java`](android-server/src/main/java/com/example/screencast/server/WheelMapping.java) | Windows delta → AXIS_VSCROLL 符号转换 |
| [`android-app/.../ServerLauncher.kt`](android-app/app/src/main/java/com/example/screencast/controller/ServerLauncher.kt) | Shizuku shell 启动/停止、jar 安装、超时 |
| [`android-app/.../MainActivity.kt`](android-app/app/src/main/java/com/example/screencast/controller/MainActivity.kt) | Shizuku 权限、引导、启动/停止、添加磁贴按钮 |
| [`android-app/.../ScreenCastTileService.kt`](android-app/app/src/main/java/com/example/screencast/controller/ScreenCastTileService.kt) | QS 磁贴：状态图标/标签、后台启停、未授权展开、API 33/34 版本差异、点击后广播发现 |
| [`android-app/.../DiscoveryBroadcaster.kt`](android-app/app/src/main/java/com/example/screencast/controller/DiscoveryBroadcaster.kt) | 手机侧多网卡 UDP 广播（5×1s，无密钥） |
| [`android-app/.../CastStateStore.java`](android-app/app/src/main/java/com/example/screencast/controller/CastStateStore.java) | Activity/Tile 状态共享 |

## 验证环境

- Windows：`D:\VSBuildTools`，MSVC v143，Windows SDK 10.0.26100，无 VS IDE；
  显示器 1920×1200 @125% DPI（视频窗口尺寸均为物理像素）
- Flutter：Windows desktop runner，D3D11
- ADB：`%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`
- Android 真机：OPPO OPD2201 **平板**，Android 14 / API 34，serial
  `<device-serial>`（已隐去）；屏幕 2800×2000（竖屏 `wm size` 报 2000×2800），
  编码帧 1280×720，letterbox 内容随旋转在 514×720 / 1008×720 之间切换
- 局域网验证：设备 `192.168.1.134`，Windows `192.168.1.203`，同一 /24
- FFmpeg：8.1.2 Windows x64 shared build，`third_party/ffmpeg/bin`
- Android App：Gradle 8.14，AGP 8.7.3，Kotlin 2.0.21，compileSdk 35，minSdk 26，
  Shizuku API 13.1.5
- Shizuku 已在验证设备上激活并授权：授权弹窗、shell `app_process`（UID 2000）、
  快捷设置磁贴与前台服务均已在 OPPO Android 14 真机跑通（含磁贴启停与一键投送）。
  仍未做运行时验证的边界：binder death 后的状态恢复、启动超时路径。

## 安全与许可证

- **加密是可选的**：配置 `--psk-hex` 后 SCRC 与控制两个端口都走 AES-GCM 记录层，
  具备机密性和完整性；不配置则完全明文（启动会打印 WARNING）。
- **发现广播无认证**：UDP 27185 的 offer 不含密钥，同网段可被伪造；它只能让桌面
  尝试连接同子网地址，实际会话仍要过 SCRC + `SecureChannel`。产品化前应加签名或
  一次性的用户确认。
- 即使启用 PSK，仍然**没有**前向保密、没有重放保护、PSK 靠带外分发；记录层也没有
  做流量填充，长度模式仍可被观察。产品化前应换成带握手和会话密钥的协议。
- 局域网模式绑定 `0.0.0.0`，只应在可信网络使用；控制端口能连上就能注入输入。
- 无线 ADB 模式临时启用 **ADB/TCP 5555**；ADB 需要 RSA 授权，但端口暴露在局域网，
  产品化前应关闭或限制来源。停止且 USB 在线时会切回 USB。
- Android App 是普通应用，通过 Shizuku 获得用户授权的 shell binder；没有 root、
  ADB 协议栈或自我提权代码。Shizuku 未激活时不应尝试任何特权操作。
- `newProcess` 是 Shizuku 13.1.5 的实际 shell primitive；`Shell.Result` 属于 libsu，
  不是 Shizuku API。当前实现对有限命令使用 `IRemoteProcess.waitForTimeout`，对
  start/stop 使用协程超时和 binder-death 监听，不在主线程同步等待。
- FFmpeg 运行库为 **GPLv3**；发布前确认许可证兼容性。
- Shizuku API 为 MIT；其余项目许可证需在发布前补充。

## 文档

- [架构细节与限制](docs/architecture.md)
- [Windows 独立视频窗口 / 托盘插件](packages/screen_cast_windows/README.md)
- [Android 控制 App / Shizuku 集成](android-app/README.md)
- [FFmpeg 运行库说明](third_party/ffmpeg/README.md)
- [app_process 服务端](android-server/README.md)

