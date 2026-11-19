# screen_cast_windows

Flutter Windows 独立视频窗口插件（C++17 / Win32 / D3D11 / NV12 / 托盘）。

## 这不是 PlatformView

Flutter Windows embedder 目前没有可用的 PlatformView 实现。本插件最初按子窗口方式
实现，但真机桌面验证发现 `WS_CHILD` 窗口会被 Flutter 的合成层遮挡；随后改成 owned
popup overlay，本版再改为**独立顶层窗口**：

1. Dart 侧 `NativeVideoSurface` 只负责触发一次创建、显示/隐藏与托盘状态推送，
   不再计算或同步 bounds。
2. 插件通过 `PluginRegistrarWindows::GetView()->GetNativeWindow()` 取得 Flutter
   视图 HWND，仅用于确定初始居中位置；窗口不挂在它下面。
3. 创建 **独立 `WS_POPUP | WS_THICKFRAME`** 顶层窗口（`WS_EX_APPWINDOW`，无 owner）：
   - `WM_NCCALCSIZE` 返回 0，客户区覆盖整个窗口（无系统边框/标题栏）；
   - `WM_NCHITTEST`：顶部 40px（DPI 缩放）`HTCAPTION` 可拖动；四边/四角 8px
     `HT*` 可缩放；其余 `HTCLIENT`；
   - 初始尺寸按视频宽高比：横屏 640×360、竖屏 360×640 逻辑像素（DPI 缩放），
     居中于 Flutter 窗口所在显示器；最小 240×135；
   - 双击拖拽区或 F11 切换全屏（去掉 `WS_THICKFRAME`、覆盖当前显示器），Esc 退出
     全屏并恢复原位置/尺寸；
   - `WM_CLOSE` 只隐藏窗口，不销毁、不断开会话；
   - 左键按下 `SetFocus`，键盘事件进入视频窗口后才会注入。
4. `shell32` 托盘：`Shell_NotifyIcon` 注册在主窗口句柄上，主窗口 `WM_CLOSE`
   改为 `SW_HIDE` 并保持托盘图标；右键菜单 **显示主窗口 / 显示视频窗口 / 退出**，
   双击图标恢复主窗口。图标为运行时绘制的绿/灰圆点，tooltip 由 Dart
   `updateStatus` 推送（`已连接 · 1280×720 · 76fps` / `未连接`）。
5. D3D11 初始化失败时才使用 GDI 纯色 fallback；成功时由 D3D11 呈现视频。
6. 视频窗口不是全局置顶的：普通前台窗口可以正常盖住它。

它不是 PlatformView：没有 widget 级裁剪、变换、透明度或截图合成语义。若需要这些
能力，应改用 Flutter Texture + D3D11 shared texture。

## 视频渲染链路

```text
FFmpeg DecodedFrame (YUV420p)
  │  Dart: Nv12FrameWriter.write（两张 staging texture 轮换）
  ▼
Native-mapped NV12 staging texture ×2  ← 一个 CPU 写入点，无像素序列化
  │  Unmap(index) + CopyResource
  ▼
DXGI_FORMAT_NV12 video texture
  │  per-plane SRV: R8 (Y) / R8G8 (UV)
  ▼
Pixel shader: 固定 BT.601 limited-range YUV→RGB
  │
  ▼
Swap-chain render target
```

- 原生创建四个纹理：两张 NV12 staging upload texture、NV12 shader-resource video
  texture，以及 swap-chain back buffer / render target。
- `configureFrame` 把两张 staging texture 都 `Map`，返回两组
  `{index, pointer, rowPitch}`。Dart 用 `dart:ffi` 直接把 Y 和交错的 UV 写进映射内存。
- 每帧只做一次 Dart→native 的 CPU 拷贝。MethodChannel 只传指针、宽高和元数据，
  **不传输像素字节**。
- 上传是**双缓冲 + 异步呈现**：`Nv12DoubleBuffer` 在两张纹理间轮换，写入完成即返回；
  `presentFrame(index)` 异步执行 `Unmap(index)` → `CopyResource` → `Map(index)`。
  写入只落在没有在呈现的那张纹理上；轮到的纹理仍在途（或两张都在途）时，新帧直接
  丢弃（不排队），丢弃数由 `CastController` 统计并显示。
  实测 60Hz 源连续 60 秒：≈60 帧/秒上传、累计丢弃 ≈0.7%。
- 原生记录最近呈现的纹理索引（`getStatus.displayedIndex`）；未被呈现的那张纹理全程
  保持映射，所以下一次写入不会撞上正在 remap 的资源。
- 没有新帧时 `has_frame_` 保持为 true，`Render()` 重绘上一张 video texture；第一帧
  之前才使用青绿色清屏占位。

### NV12 与 shader 细节

- 使用 `DXGI_FORMAT_NV12`，由一个 NV12 resource 的 Y plane 和 UV plane 组成。
  这比单独 Y/UV texture 更接近硬件视频路径；NV12 是单个 resource，因此没有两个
  独立 subresource 可分别 `UpdateSubresource`，而是直接映射整张 staging texture。
- 像素格式转换在 Dart 写入共享映射时完成：Y 逐行复制，U/V 交错写入 UV plane。
  没有额外的中间 `Uint8List`，也没有为了转换再分配一块 CPU buffer；转换与唯一
  一次 Dart→native 拷贝合并完成。
- shader 用两个 per-plane SRV 采样 NV12：Y 为 `R8_UNORM`，UV 为
  `R8G8_UNORM`；使用固定的 BT.601 limited-range 矩阵，不做 HDR/色彩管理。
- 用 `SV_VertexID` 生成覆盖整个客户区的 quad，不依赖顶点缓冲。

## MethodChannel

Channel: `dev.screencast/windows_view`

| 方法 | 参数 | 说明 |
| --- | --- | --- |
| `create` | 无 | 创建独立视频窗口并显示，返回 `{d3d11: bool}` |
| `setBounds` | `visible`（几何参数已忽略） | 兼容旧 Dart 构建，只处理显隐 |
| `setVisible` | `visible` | 显示/隐藏视频窗口 |
| `showVideoWindow` | 无 | 把视频窗口带到前台（占位卡按钮用） |
| `showMainWindow` | 无 | 把 Flutter 主窗口恢复并置前（自动连接失败时用来显示错误） |
| `updateStatus` | `connected/width/height/fps` | 刷新托盘图标与 tooltip |
| `configureFrame` | `width/height`（偶数） | 创建并映射两张 NV12 上传纹理，返回 `{targets:[{index,pointer,rowPitch}],width,height}` |
| `presentFrame` | `index`（0/1） | 提交指定纹理上已写入的 NV12 帧，返回 `{index,pointer,rowPitch,width,height}`（remap 后的新指针） |
| `getStatus` | 无 | `{created,d3d11,hasFrame,frameWidth,frameHeight,displayedIndex,lastError}` |
| `dispose` | 无 | 销毁窗口与 D3D 资源 |

Dart 侧标题会显示 `Win32 · D3D11` 或 `Win32 · GDI`，用于确认实际后端。

## 已真实验证

使用 Visual Studio Build Tools 2026（`D:\VSBuildTools`，MSVC v143 + Windows SDK
10.0.26100，无 VS IDE）：

- `flutter build windows --debug` 成功；
- OPPO OPD2201 / Android 14 真机，1280x720 H.264；
- Windows 应用实际显示 Android 桌面，UI 计数超过 1400 帧；
- 颜色正常，未见 YUV 平面错位；
- 最小化/恢复、WM_PAINT 后仍保留上一帧，没有闪烁清屏；
- 无新帧期间不再清空 render target；
- 独立窗口：`rect=(412,251)-(1212,701) 800x450 thickframe=yes owner=0`
  （=640×360 逻辑像素 @125% DPI）；F11 → `1920x1200 thickframe=no`，Esc 精确还原；
  关闭视频窗口后进程仍在；关闭主窗口后视频窗口仍在（托盘驻留）；
  托盘回调双击可恢复主窗口，右键菜单三项经截图确认。

调试用自动启动（不改变正常默认行为）：

```powershell
flutter run -d windows --dart-define=SCREEN_CAST_AUTOSTART=true
```

## 已知限制

- 视频窗口是独立顶层窗口：不再随 Flutter 布局/滚动裁剪或移动，位置与尺寸由用户
  拖拽/缩放决定（这是本版的目标行为）。
- 模态对话框/弹出菜单跨过视频窗口时会被视频窗口盖住（反之亦然，取决于 Z 序）。
- 截图/录屏 Flutter 窗口时，视频窗口作为独立顶层窗口，合成结果取决于截图工具。
- 当前固定 BT.601 limited-range 矩阵；`yuvj420p` 全范围流会有轻微色偏。
- 每个解码帧仍走一次 MethodChannel 元数据往返（`presentFrame`），但它**不再阻塞**
  解码循环：写入后立即返回，present 未完成时丢帧并计数。尚未做跨帧合批或多张
  in-flight 的自适应丢帧。
- 布局在侧栏/堆叠之间切换时，`CastPreview` 通过 `GlobalKey` 保留 State 和原生
  surface；如果整个预览被移除或 `NativeVideoSurface` 真正 dispose，原生 renderer
  会重新初始化，设备端若没有立即产生新帧会暂时显示占位色，直到下一帧到达。
- 只实现 NV12 呈现；未支持 YUY2、BGRA 或 HDR。D3D11VA 硬件解码帧由
  `hardware_frame_bridge.cpp` 的 `CopySubresourceRegion` 直接拷入 NV12 video texture。
