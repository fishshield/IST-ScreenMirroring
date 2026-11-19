1. 一句话状态

端到端可用，非产品化完成态。
Windows Flutter 控制端 + Android app_process 捕获端已跑通：有线 ADB、无线 ADB/TCP、手机 App/Shizuku 直连三种模式均可工作；H.264 走 SCRC 协议（协议未改），Windows 侧 D3D11VA 硬解 + 软解回退，画面显示在独立顶层视频窗口，主窗口关闭后驻留托盘、投屏不中断。控制通道支持触摸/滚轮/按键注入，真机点击误差 ≤3 设备像素。

    明确约束：整个项目不使用 MediaProjection。
    Android 捕获服务端通过 DisplayManager 反射或 SurfaceControl 回退创建虚拟显示，MediaCodec 全程 surface-input 编码。

当前验证主设备：OPPO OPD2201 平板，Android 14 / API 34。Android 10–13、音频、多控制端、产品级认证/密钥轮换等尚未完成。
2. 架构与数据流
text

Windows host                                      Android device (UID 2000)
AdbLauncher / 手机 App(Shizuku)
  ├─ adb push screencast-server.jar
  ├─ wired: adb forward 27183 + 27184
  ├─ wireless: adb tcpip 5555，视频直连手机 IP
  └─ app_process 启动 ServerSocket
       video: 27183 SCRC/H.264
       control: 27184 输入注入
       discovery: UDP 27185 一键投送

Windows:
ScrcSocketClient → TcpTransport → SecureChannel(AES-GCM 可选) → ScrcPacketDecoder
→ NalDecodeQueue → FfmpegDecoder(D3D11VA 硬解/软解回退)
→ D3D11 NV12 纹理 → 独立顶层视频窗口
→ WM_MOUSE*/WM_KEY* → ControlClient → 27184 → InputInjector

关键端口：
端口	用途
27183/TCP	SCRC 视频流，协议零改动
27184/TCP	控制通道，触摸/滚轮/按键注入，0x10 停止服务
27185/UDP	局域网发现，一键投送/自动连接
5555/TCP	无线 ADB 模式临时启用
3. 当前功能状态（简版）
模块	状态	说明
ADB 启动服务端 USB/无线	✅ 已验证	无线拔 USB 后可通过 ADB/TCP 自动重启恢复
SCRC 视频传输	✅ 已验证	协议未改；TCP_NODELAY 默认开
H.264 解码	✅ 已验证	D3D11VA 硬解 + 软解回退，FFmpeg 8.1.2 FFI
Windows 呈现	✅ 已验证	独立顶层窗口 + D3D11 NV12；按内容区裁切/比例缩放/旋转跟随
视频窗口交互	✅ 已验证	最小化/全屏/关闭图标、淡入淡出、F11/Esc、锁比例缩放；关闭只隐藏
托盘驻留	✅ 基本验证	主窗口关闭进托盘；菜单三项，退出 未手工点击验证
控制通道 27184	✅ 已验证	点击/滚轮/按键；同会话旋转 letterbox 重算；误差 ≤3 设备像素
一键投送 UDP 27185	✅ 已验证	手机磁贴/服务启动广播，PC 自动直连，常规约 1.2–1.4 s
设备扫描与连接	✅ 已实现	USB + 局域网 27184 扫描；不探 27183，避免触发服务端重建捕获
PSK/AES-GCM 记录层	✅ 已验证	三层封装协议零改动；UI 已移除 PSK 输入，需 --dart-define 或服务端 --psk-hex
Shizuku 控制 App	✅ 部分边界	授权、jar 写入、app_process、磁贴启停、前台服务已真机跑通；binder death 后重新授权流程缺单测
帧率可观测	✅ 已验证	状态栏/tooltip 显示解码 fps · 呈现 fps，差值 >20% 提示
限制 60 帧 --target-fps	⚠️ 服务端已实现	本机 ROM 忽略 Surface.setFrameRate；系统设置切“标准刷新率 60Hz”有效
Android 10–13	❌ 未验证	仅 Android 14 真机
音频	❌ 未实现	仅视频
4. 最近完成的关键改动（2026-11）

    后台运行卡片去 OPPO 化：改为通用“后台运行（可选）”，按厂商显示文案，ColorOS 家族保留自启动管理深链，其它机型走应用设置。

    视频窗口体验与图标：关闭只隐藏，主窗口回前台并出现“显示视频窗口”；标题栏只保留三个图标；显示/隐藏淡入淡出、全屏 180ms 补间；新增 Windows/Android 应用图标。

    修复投屏周期性卡顿：设备扫描原来探测 27183 视频端口，被服务端当成新观众触发重建显示/编码器；现在只探 27184，自动扫描在会话运行期间跳过，间隔 10s、并发 32、超时 200ms。

    磁贴跟随桌面连接会话：桌面经无线 ADB 启停服务端后，通过 am broadcast 通知手机 App（SERVER_STARTED/STOPPED，受 android.permission.DUMP 保护），磁贴重新绑定状态。

    Shizuku 断开后投屏不中断：前台服务 watchdog 改为探测 27184，binder death 只把状态置 SHIZUKU_LOST；停止服务新增控制通道 0x10，以 27184 关闭为成功判据。

    主界面重构：有线/无线/直连合并为设备扫描列表；移除局域网 IP/PSK 输入框；关于/架构页独立。

    A/B/C/D 四项：内容区探测变化触发；NAL 队列溢出清空等待 IDR；原生统计 Present fps；服务端 --target-fps + PC“限制 60 帧”开关。

    硬解与点击修正：D3D11VA 复用渲染设备零拷贝呈现；点击按“整帧归一化”映射，竖屏/横屏/缩放窗口误差 ≤3 设备像素；修复 ResizeBuffers 失败导致 DWM 拉伸旧帧。

5. 已验证到什么程度
已验证

    flutter analyze 0 issues；flutter test 100 个单测通过。

    FFmpeg 真实解码：sample_320x180.h264 解出 15 帧 YUV420p；无插件 DLL 时走软解回退。

    Android 14 真机：DisplayManager 路径、SurfaceControl 回退均成功；c2.mtk.avc.encoder，KEY_LOW_LATENCY=1。

    有线模式：27183 + 27184 两条 forward；点击、滚轮、ESC→BACK 注入成功。

    无线模式：服务端 0.0.0.0，无 forward，客户端直连手机 IP；拔 USB 后自动恢复。

    Direct 模式：桌面不执行 ADB，手机 App/Shizuku 启动服务端，PC 直连 1280×720，连续帧增长。

    D3D11VA 硬解：60 秒滚动动画 decoded/uploaded 基本相等、dropped=0；此前软解约 37% 丢弃。

    独立视频窗口 + 托盘：F11/Esc、关闭隐藏、主窗口关闭不中断、托盘双击恢复主窗口已验证；托盘菜单 退出 未手工点击。

    一键投送：手机磁贴/App 启动服务后 PC 1.2–1.4s 自动连接；PSK 分支、同网段校验、5 次广播只连 1 次有单测/真机验证。

    PSK：AES-128 真机 742+ 帧解密；错误密钥链路报错不花屏。

    控制坐标：竖屏/横屏点击图标中心，注入误差 ≤3 设备像素；同会话旋转 letterbox 自动重算。

未验证/未完成

    Android 10–13 捕获路径。

    音频。

    多控制端并发、重放保护、密钥轮换、PSK 带外交互。

    Shizuku binder death 后重新授权流程单测；启动超时路径。

    托盘菜单 退出 手工验证；托盘图标在通知区溢出面板中的真实像素。

    D3D device removed 后渲染器整体重建。

    呈现仍在 UI 线程 Present，高刷源无法真正跑满。

    GDI fallback 只画占位色，无自动化覆盖。

    内容区探测仍是启发式整帧 Y 平面测量；深色 UI/非对称黑边可能退化为整帧显示。

6. 最容易踩坑的设计约定

    坐标契约：客户端发送的是“整帧归一化坐标”。
    服务端 InputInjector 先 videoX = nx * videoWidth，再减 letterbox 偏移。窗口只显示内容区时，必须先把点击点还原到整帧：nx = contentRect.left + fx * contentRect.width。这是最容易改出偏移的地方。

    letterbox 是动态的。
    视频帧恒 1280×720；平板 2800×2000 竖屏内容约 514×720 @ offset 383，横屏约 1008×720 @ offset 136。服务端每次注入前轮询 Display.getRealSize() 与旋转，变化即重算，不需要重连。

    扫描不要探 27183。
    视频监听会把任何连接当新观众并重建捕获，造成周期性卡顿。扫描只探 27184。

    视频窗口是独立顶层窗口，不是 PlatformView。
    Flutter Windows 无可用 Android 式 PlatformView；WS_CHILD 会被合成层遮挡。当前是 WS_POPUP | WS_THICKFRAME、无 owner、任务栏可见，WM_NCPAINT 自绘 40px 标题栏。关闭只 SW_HIDE，托盘 退出 才真正结束进程。

    硬解是同步 FFI 桥。
    hardware_frame_bridge.cpp 导出 3 个 C 函数，Dart 直接 DynamicLibrary.open 调用；不能走 MethodChannel，否则 AVFrame 已释放。ABI 偏移由 tool/ffmpeg_abi_dump.c 生成，运行时校验 codec_id，不符只软解。

    PSK 是记录层，不是协议改动。
    SecureChannel 在 socket 与协议之间分帧加解密，SCRC 魔数/长度和控制帧类型不变。UI 已移除 PSK 入口，需要时用 --dart-define=SCREEN_CAST_PSK_HEX 或服务端 --psk-hex。

7. 建议的下一步优先级

    把“窗口坐标 → 整帧归一化”换算抽成纯函数并补竖屏/横屏/缩放/letterbox 组合单测。

    一键投送收尾：给 offer 增加签名/信任确认，替代“同网段即可信”；多网卡真机验证。

    呈现移到独立线程，避免 UI 线程 Present 阻塞，让高刷源跑满。

    托盘菜单逐项人工验证，尤其 退出；把托盘图标固定到通知区可见位置。

    D3D device removed 后渲染器整体重建。

    Android 10–13 捕获路径、Shizuku 运行时边界（binder death、启动超时）验证。

    产品化安全：认证、前向保密、重放保护、密钥轮换、限制 0.0.0.0 暴露面、关闭/限制 5555。

8. 快速上手
powershell

# 依赖：Flutter Windows desktop、MSVC Build Tools、Android SDK/platform-tools
flutter analyze
flutter test
tool\build_server.ps1          # 改过 Android 服务端时重编 jar
flutter build windows --debug

# 有线 + 自动启动
flutter run -d windows --debug --dart-define=SCREEN_CAST_AUTOSTART=true

# 无线直连
flutter run -d windows --debug `
  --dart-define=SCREEN_CAST_AUTOSTART=true `
  --dart-define=SCREEN_CAST_WIRELESS=true `
  --dart-define=SCREEN_CAST_HOST=192.168.1.134

# 一键投送：监听 UDP 27185
flutter run -d windows --debug --dart-define=SCREEN_CAST_AUTOCONNECT=true

启动后应看到：主窗口“设备与连接”列表；连接成功后独立视频窗口按设备画面比例出现；日志依次出现 [hwaccel] D3D11VA decode enabled、[content] probe: reason=...、[cast] 1s decoded=.. uploaded=..。

常用联调工具：tool/adb_launch.ps1、tool/control_probe.ps1、tool/window_check.ps1、tool/clock_server.py、tool/check_server.ps1。
9. 新人阅读顺序

    本文“一句话状态 + 架构 + 功能状态”。

    README「项目现状（交接速览）」中的「关键设计约定（改动前必读）」。

    docs/architecture.md。

    关键文件：lib/src/host/adb_launcher.dart、lib/src/transport/scrc_socket_client.dart、lib/src/ffmpeg/ffmpeg_decoder.dart、packages/screen_cast_windows/windows/d3d11_renderer.cpp、native_video_view.cpp、android-server/.../VirtualDisplayCaptureBackend.java、InputInjector.java、android-app/.../ServerLauncher.kt、ScreenCastTileService.kt。

    跑一遍 flutter analyze / flutter test / 有线自动启动，再按需看无线/一键投送。

结论： 当前项目已具备“Windows 控制端 + Android 捕获端 + 视频/控制/发现/加密/托盘/硬解”的完整演示链路，核心风险集中在产品化安全、Android 版本覆盖、呈现线程、内容区启发式检测和少数托盘/Shizuku 边界验证。新开发者可按上面的功能状态表和“改动前必读”快速定位可改与不可踩的区域。
