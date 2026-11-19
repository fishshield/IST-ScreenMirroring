# screen_cast_android

> **拓扑 A 遗留**：根应用已不再依赖本插件，也不再把 `screen_cast_android` 列入
> `pubspec.yaml`。保留此目录仅用于上一版 Android 插件契约参考；实际启动已移到
> Windows 主机的 `lib/src/host/adb_launcher.dart`。

Flutter Android 插件的 MethodChannel 骨架。

## 职责

- 注册 channel：`dev.screencast/control`。
- 暴露 `startServer` / `stopServer` / `getPreviewTextureId` / `getStatus`。
- 预留预览纹理 id（当前为 `null`）。

## 不负责

- 启动 `app_process`。
- ADB 连接或端口转发。
- 屏幕采集、MediaCodec 编码、FFmpeg 解码。

## 为什么 `startServer` 会失败

插件运行在 Flutter 应用进程（应用 UID），而目标架构要求采集服务端以 shell
用户（UID 2000）运行。子进程无法改变父进程 UID，应用内也没有主机侧 `adb`
工具，因此这里**故意**返回：

```text
HOST_LAUNCH_REQUIRED
```

实际启动请使用仓库根目录的 `tool/adb_launch.ps1` 或 `tool/adb_launch.sh`。
如果最终选择 Flutter 桌面主机拓扑，应把启动逻辑放到主机侧，而不是这个 Android
插件里；插件可继续只负责纹理/解码桥接（或完全移除）。

## 构建

本目录是 path dependency 的插件包，不应单独构建。根应用的 Flutter Gradle
工程会引入它。`build.gradle` 使用：

- `compileSdk = 35`
- `minSdk = 24`
- Kotlin JVM target `17`

如本机 SDK / AGP / Kotlin 版本不同，请同步调整 `build.gradle`。
