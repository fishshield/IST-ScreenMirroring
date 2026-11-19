# android-server

`app_process` Java 捕获服务端。由**主机侧 ADB** 以 shell 用户（UID 2000）启动，
在设备本地监听 SCRC/H.264 socket。

## 状态

已实现：

- 参数解析、TCP 监听、SCRC 帧封装。
- 反射隐藏 API 创建虚拟显示，将默认显示镜像到编码器输入 Surface。
- `MediaCodec` `video/avc` surface-input 编码，API 30+ 启用 `KEY_LOW_LATENCY`。
- Annex-B NAL 拆分、SPS/PPS 缓存、逐 NAL 写入 SCRC。
- 显示 API 失败时输出完整错误堆栈并终止。
- **控制通道（27184）**：与 SCRC 视频端口分离的输入注入 socket，独立线程处理连接，
  断线只停止注入，不影响视频会话（详见下文“控制通道”）。

真机验证（OPPO OPD2201，Android 14 / API 34）：

- shell UID 2000；
- DisplayManager 路径创建 `VirtualDisplay displayId=3`；
- `c2.mtk.avc.encoder`，`KEY_LOW_LATENCY=1`；
- 抓取 244,407 字节 SCRC，FFmpeg 解出 14 帧 1280x720；
- 强制 `--display-backend=surfacecontrol` 时也成功，FFmpeg 解出 11 帧 1280x720。

未验证：

- Android 10–13 真机兼容性（当前只有 Android 14 设备）。
- 旋转、分辨率变化、多 slice、重连等完整产品级行为。

**不使用 MediaProjection。** 所有显示创建都走 shell 可用的隐藏 API；两条反射路径
都失败时不会静默切换到屏幕捕获授权。

## 文件

```text
src/main/java/com/example/screencast/server/
├── Server.java                        # main + video accept loop + control thread
├── ServerOptions.java                 # bind address、端口、control-port、尺寸、码率、帧率等
├── ControlProtocol.java               # 控制帧常量（与 Dart 侧一致）
├── ControlServer.java                 # 27184 监听，每个连接独立线程
├── InputInjector.java                 # 归一化 → 视频像素 → 显示像素 + injectInputEvent
├── PskCipher.java                     # AES-GCM 密钥（--psk-hex）
├── SecureRecordOutputStream.java      # 记录层加密（SCRC 输出方向）
├── SecureRecordInputStream.java       # 记录层解密（控制输入方向）
├── DisplayMetadata.java               # DisplayManagerGlobal 元数据（回退路径用）
├── VirtualDisplayFactory.java         # DisplayManager → SurfaceControl 回退
├── VirtualDisplayCaptureBackend.java  # MediaCodec surface 编码与 NAL 输出
├── AvcNalSplitter.java                # Annex-B / 长度前缀 NAL 拆分
├── CaptureLog.java                    # adb shell + logcat 日志
├── CaptureException.java
├── ScrcPacketWriter.java              # SCRC framing（协议未改）
├── NalUnitSink.java
└── CaptureBackend.java
src/test/java/com/example/screencast/server/
└── CaptureCoreCheck.java              # JVM 辅助检查（非 Android 运行时）
```

## 控制通道

视频仍是 SCRC（`--port`，默认 27183），控制是另一条独立 TCP 通道（`--control-port`，
默认 27184）。`Server` 构造时同时绑定两个端口；`serve()` 用一个守护线程跑控制监听，
每个控制连接再开独立线程。

帧格式（5 字节头 + payload，大端）：

| 类型 | 名称 | payload |
| ---: | --- | --- |
| 0x01/0x02/0x03 | 触摸按下/移动/抬起 | 4 字节 float X + 4 字节 float Y，归一化 0.0–1.0 |
| 0x04 | 滚轮 | 4 字节 int32，正数 = 向下滚动 |
| 0x05/0x06 | 按键按下/抬起 | 4 字节 int32，Android KeyEvent keycode |
| 0x10 | 停止服务（仅控制 App → 服务端） | 无 payload；服务端关闭监听并退出 |

`0x10` 是“停止服务”在 Shizuku 不可用时的唯一可行路径：捕获进程属于 shell（UID
2000），普通 App 无法 `pkill`，但可以在这个已经用于输入的控制通道上请求服务端自己
退出。旧服务端会把它当成未知类型忽略，所以 App 发完请求后会再探测 27184 是否关闭。

**坐标映射**（`InputInjector`，注入前打印，便于核对）：

```text
normalized 0..1
  ├─ × 视频编码尺寸 1280×720            → video=(x,y)        ← 协议要求的第一步
  ├─ 去掉虚拟显示的 letterbox 内边距     → content=1008×720 offset=136
  └─ 缩放回默认显示的逻辑尺寸 2800×2000  → display=(x,y)      ← 真正注入的坐标
```

视频帧是 2800×2000 的显示按比例塞进 1280×720 的结果，左右各 136 px 黑边。
直接把 video 像素注入会在 2800×2000 的显示上只覆盖左上角 1280×720，所以最后一步
必须换算回显示坐标；日志会同时打印三段数值：

```text
[control] touch down norm=(0.5007,0.4988) video=(640.8,359.2) display=(1402,997)
```

注入走隐藏的 `InputManager.injectInputEvent`（需要 shell 的 INJECT_EVENTS）。
Android 14 上 `InputManager.getInstance()` 在 app_process 里会抛
`NullPointerException`，实现里有回退：直接取 `ServiceManager.getService("input")`
并用 `IInputManager$Stub.asInterface`，实际验证可用。

控制连接断开时只记录一行 `control disconnected: ...`，不会结束视频会话。

## 记录层加密

`--psk-hex` 启用后，两个端口都在 socket 与协议之间多一层 AES-GCM：

```text
Socket → SecureRecordOutputStream/InputStream(PskCipher) → SCRC / 控制帧
```

- 每条记录：`[4 字节大端长度][12 字节 nonce][密文][16 字节 GCM tag]`，
  与 Dart 侧 `SecureChannel` 完全一致；长度覆盖 nonce+密文+tag。
- 单条记录明文上限 64 KB；SCRC 或控制帧本身都不感知加密，解析代码零改动。
- 未配置 `--psk-hex` 时退化为明文，并在启动时打印
  `WARNING: no --psk-hex; SCRC video and control traffic is UNENCRYPTED.`。
- 控制通道收到坏记录（密钥不匹配/被篡改）时抛 `IOException`，只断开该控制连接，
  视频会话继续；SCRC 输出方向加密失败会让本次视频会话结束。

## 显示路径与 Android 版本

1. **DisplayManager**
   - 反射调用隐藏静态方法
     `DisplayManager.createVirtualDisplay(String, int, int, displayIdToMirror, Surface)`。
   - 不需要 Context，适合 shell app_process。
   - Android 14+ 的系统实现使用这条路径；Android 10–13 上若该方法不存在，会记录
     明确日志并进入下一条回退。
   - Android 10–13 的公开 `createVirtualDisplay(String,int,int,int,Surface,int)`
     是实例方法，需要 app Context 且 AUTO_MIRROR 受签名权限限制；shell app_process
     不使用这条脆弱路径，SurfaceControl 回退才是这些版本的可靠实现。
2. **SurfaceControl**
   - 反射 `SurfaceControl.createDisplay(name, secure)`，再在 transaction 中执行
     `setDisplaySurface` / `setDisplayProjection` / `setDisplayLayerStack`。
   - Android 10/11 需要 `secure=true`；Android 12+（包括 14+）使用 `secure=false`。
   - Android 14+ 的旧 SurfaceControl 辅助方法语义改变：
     `setDisplayProjection()` 用 layer stack rect 的尺寸 resize 虚拟显示，
     `setDisplayLayerStack()` 的参数实际是 displayIdToMirror。本实现按 API 34
     分别传入输出尺寸和默认 display id；旧版本传源显示尺寸 + 真实 layer stack。
3. 两条路径均失败：抛出带两个 suppressed cause 的 `CaptureException`，打印
   `DisplayManager... failed` 和 `SurfaceControl... failed`。**没有 MediaProjection
   分支。**

`ServerOptions` 默认镜像 `Display.DEFAULT_DISPLAY`。旋转/多显示器暂按默认显示处理。

## 编码路径

```text
MediaCodec.createEncoderByType("video/avc")
  ├─ format: surface color, bitrate, fps, I-frame interval
  ├─ API 30+: KEY_LOW_LATENCY=1
  ├─ configure(format, null, null, CONFIGURE_FLAG_ENCODE)
  ├─ createInputSurface()                 ← 编码器唯一输入方式
  ├─ VirtualDisplayFactory.create(inputSurface)
  └─ start()
      └─ 编码输出 → Annex-B 拆分 → SPS/PPS 缓存 → ScrcPacketWriter
```

编码失败重试：如果带 `KEY_LOW_LATENCY` 的 `configure()` 失败，会记录日志并在
API 30+ 去掉该 key 再试一次；不会改变 SCRC 协议。

## 构建

推荐脚本（输出到 `assets/server/screencast-server.jar`，供 Dart `AdbLauncher`
作为 asset 读取）：

```powershell
powershell -ExecutionPolicy Bypass -File .\tool\build_server.ps1
```

需要 JDK、Android SDK Build-Tools（含 d8）和 `android.jar`。构建脚本现在会把
`android.jar` 同时传给 `javac` 和 `d8`，并在打包后把 jar 同步到
`android-app/app/src/main/assets/screencast-server.jar`——Android 控制 App 打包的是
自己 assets 里的那份副本，不同步就会悄悄发出旧的服务端。

手动等价命令（macOS/Linux 把 `d8.bat` 换成 `d8`）：

```powershell
$sdk = $env:ANDROID_HOME
$androidJar = Get-ChildItem "$sdk\platforms" -Recurse -Filter android.jar |
  Sort-Object FullName -Descending | Select-Object -First 1 -ExpandProperty FullName
$buildTools = Get-ChildItem "$sdk\build-tools" -Directory |
  Sort-Object Name -Descending | Select-Object -First 1
$sources = Get-ChildItem -Recurse -Filter *.java src\main\java |
  ForEach-Object { $_.FullName }

New-Item -ItemType Directory -Force build\classes, build\dex | Out-Null
javac --release 8 -cp $androidJar -d build\classes $sources
jar --create --file build\server-classes.jar -C build\classes .
& "$($buildTools.FullName)\d8.bat" --min-api 24 --lib $androidJar `
  --output build\dex build\server-classes.jar
jar --create --file build\screencast-server.jar -C build\dex classes.dex
```

辅助检查：

```powershell
javac -cp build\server\classes -d build\server\test-classes `
  src\test\java\com\example\screencast\server\CaptureCoreCheck.java
java -cp "build\server\classes;build\server\test-classes" `
  com.example.screencast.server.CaptureCoreCheck
```

## CLI

```text
--port=27183
--control-port=27184
--bind-address=127.0.0.1
--psk-hex=<32|48|64 hex chars>      # 可选；不填则明文
--max-payload-bytes=16777216
--width=1280
--height=720
--bit-rate=8000000
--frame-rate=60
--i-frame-interval=1
--target-fps=0                       # 0=不限制；>0 时调用 Surface.setFrameRate
--display-backend=auto|displaymanager|surfacecontrol
```

`--bind-address` 默认 `127.0.0.1`（仅设备 loopback，配合 `adb forward`）。
传 `0.0.0.0` 时监听所有接口，供局域网直连；此时**不要**创建 `adb forward`。
宽高必须为偶数。Dart 的 `AdbLauncher` 会自动传 `--port` 和对应 bind address，
其他参数使用默认值；可以手动用 `adb shell` 或 `tool/adb_launch.ps1` 覆盖。`auto`
默认先试 DisplayManager，再试 SurfaceControl；后两种用于单独验证某条回退路径。

`--target-fps` 只是**提示**：服务端在创建虚拟显示后反射调用
`Surface.setFrameRate(n, FIXED_SOURCE, ONLY_IF_SEAMLESS)`（Android 11+），5 秒后把实际
帧数写进日志：`[encoder] target-fps=60 actual=59 (hint applied)` /
`[encoder] target-fps=60 actual=98 (hint ignored by ROM)`。被忽略时不做应用层丢帧
（丢 P 帧会花屏）；实测 OPPO Android 14 会忽略该提示，系统设置里切“标准刷新率
（60 Hz）”有效。

## 启动

有线模式：

```powershell
adb push .\assets\server\screencast-server.jar /data/local/tmp/screencast-server.jar
adb forward tcp:27183 tcp:27183
adb shell "CLASSPATH=/data/local/tmp/screencast-server.jar app_process /system/bin com.example.screencast.server.Server --port=27183 --bind-address=127.0.0.1"
```

局域网模式（手机与 Windows 同一网络；Windows 直接连手机 IP）：

```powershell
adb push .\assets\server\screencast-server.jar /data/local/tmp/screencast-server.jar
adb tcpip 5555
adb connect <phone-lan-ip>:5555
adb -s <phone-lan-ip>:5555 shell "CLASSPATH=/data/local/tmp/screencast-server.jar app_process /system/bin com.example.screencast.server.Server --port=27183 --bind-address=0.0.0.0"
# 不执行 adb forward；Windows 连接 <phone-lan-ip>:27183
```

Dart 应用会在无线启动时自动执行 `adb tcpip 5555` / `adb connect`，并在 USB
拔线导致旧 app_process 退出后，通过仍在线上的 ADB/TCP 自动重启服务端。手动
前台运行时没有这个自动恢复逻辑。

在设备日志中应看到：

```text
[capture] Server UID=2000 ...
[capture] Creating virtual display: API ...
[capture] Virtual display backend: DisplayManager ... (或 SurfaceControl ...)
[capture] MediaCodec encoder started: ...
SCRC server listening ...
```

若失败，会看到明确的 `DisplayManager... failed` / `SurfaceControl... failed` /
`Capture setup failed` 堆栈。

## 注意

- 服务端默认只监听 `127.0.0.1`，必须通过 `adb forward` 访问。
- `--bind-address=0.0.0.0` 时监听所有接口，供局域网直连；SCRC **没有认证/加密**，
  只应在可信局域网使用。
- SCRC 仍是“一个 NAL 一个包”，不带 Annex-B 起始码。
- 产品化前需要补旋转/尺寸变化、多 slice 聚合、重连和硬件兼容性测试。
