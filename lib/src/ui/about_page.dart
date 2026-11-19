import 'package:flutter/material.dart';

/// Static explanation page: architecture, rendering boundary and the video
/// window. These texts used to live on the main screen; the control surface is
/// now a focused device list.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key, this.onShowVideoWindow});

  final VoidCallback? onShowVideoWindow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bodyStyle = theme.textTheme.bodySmall?.copyWith(
      color: const Color(0xFF8193A4),
      height: 1.6,
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '关于 / 架构',
          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820),
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'SCREEN CAST / DEMO',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 2.2,
                      fontWeight: FontWeight.w700,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Android 画面，Windows 原生呈现',
                    style: theme.textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'ADB 推送并启动 shell 端 Java 服务端，或由手机上的控制 App 通过 Shizuku '
                    '启动同一服务端；SCRC/H.264 经有线端口转发或局域网直连进入 Dart，再由 '
                    'FFmpeg FFI 解码。YUV420p 帧经共享内存写入原生 D3D11 NV12 纹理，在独立的 '
                    'Win32 视频窗口中呈现。',
                    style: bodyStyle,
                  ),
                  const SizedBox(height: 24),
                  _Section(
                    title: '渲染边界',
                    child: Text(
                      'Flutter Windows 目前没有 Android 式 PlatformView，因此视频由原生顶层 HWND '
                      '承载：Dart 只同步窗口位置/尺寸，并把 FFmpeg 解出的帧直接写进原生映射的 '
                      'NV12 staging texture；D3D11 完成 YUV→RGB 采样并保留最后一帧，避免无新帧'
                      '时闪烁。主窗口关闭后应用驻留托盘，投屏不中断。',
                      style: bodyStyle,
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '实时预览',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '视频不嵌在主界面里，而是在独立的视频窗口中播放（可移动、缩放、全屏、'
                          '跟随设备旋转）。需要时可以随时把它带到前台。',
                          style: bodyStyle,
                        ),
                        if (onShowVideoWindow != null) ...[
                          const SizedBox(height: 12),
                          FilledButton.tonalIcon(
                            onPressed: onShowVideoWindow,
                            icon: const Icon(Icons.open_in_new, size: 16),
                            label: const Text('显示视频窗口'),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  _Section(
                    title: '快捷键',
                    child: Text(
                      '视频窗口：双击标题栏或 F11 全屏，Esc 退出全屏。'
                      '键盘方向键 / Enter / Esc / Backspace 会注入到手机。',
                      style: bodyStyle,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF0D141C),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}
