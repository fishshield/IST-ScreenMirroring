import 'package:flutter/material.dart';

import '../../cast/cast_session_state.dart';
import '../../cast/frame_rate_hint.dart';
import '../../discovery/device_scanner.dart';
import 'status_badge.dart';

/// Merged control surface: scan for devices, connect with one tap, toggle the
/// background behaviours, and watch the session status.
class ControlPanel extends StatelessWidget {
  const ControlPanel({
    super.key,
    required this.state,
    required this.devices,
    required this.scanning,
    required this.onScan,
    required this.onConnect,
    required this.onStop,
    required this.onShowVideoWindow,
    required this.onAutoConnectChanged,
    required this.onLimit60FpsChanged,
  });

  final CastSessionState state;
  final List<DiscoveredDevice> devices;
  final bool scanning;
  final VoidCallback onScan;
  final ValueChanged<DiscoveredDevice> onConnect;
  final VoidCallback onStop;
  final VoidCallback onShowVideoWindow;
  final ValueChanged<bool> onAutoConnectChanged;
  final ValueChanged<bool> onLimit60FpsChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: const Color(0xFF0D141C),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '设备与连接',
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const Spacer(),
              CastStatusBadge(status: state.status),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              FilledButton.tonalIcon(
                key: const Key('scan-devices'),
                onPressed: scanning ? null : onScan,
                icon: scanning
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.radar_rounded, size: 18),
                label: Text(scanning ? '扫描中…' : '扫描设备'),
              ),
              const SizedBox(width: 12),
              Text(
                devices.isEmpty ? '尚未发现设备' : '发现 ${devices.length} 台设备',
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFF7F93A5),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (devices.isEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: const Text(
                '点“扫描设备”查找同一局域网或 USB 连接的手机；'
                '手机上的控制 App 需处于运行中。',
                style: TextStyle(
                  fontSize: 12,
                  height: 1.5,
                  color: Color(0xFF8193A4),
                ),
              ),
            )
          else
            Column(
              children: [
                for (final device in devices)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _DeviceRow(
                      device: device,
                      connected: _isConnected(device),
                      enabled: !state.status.isBusy,
                      onTap: () => onConnect(device),
                    ),
                  ),
              ],
            ),
          const SizedBox(height: 6),
          _OptionSwitch(
            switchKey: const Key('auto-connect-switch'),
            title: '自动连接（发现即连）',
            value: state.autoConnect,
            trailingLabel: state.autoConnect ? '已开启' : '已关闭',
            statusLine: state.discoveryStatus,
            statusIsError: state.discoveryError,
            onChanged: onAutoConnectChanged,
          ),
          const SizedBox(height: 6),
          _OptionSwitch(
            switchKey: const Key('limit-60fps-switch'),
            title: '限制 60 帧（降低带宽和编码器负载）',
            value: state.limit60Fps,
            trailingLabel: state.limit60Fps ? '--target-fps=60' : '不限制',
            helper: '仅当手机端支持帧率提示时生效；无效时请到 设置 → 显示与亮度 → '
                '屏幕刷新率 选“标准刷新率（60 Hz）”（实测有效）',
            onChanged: onLimit60FpsChanged,
          ),
          const SizedBox(height: 16),
          _MessageBox(status: state.status, message: state.message),
          if (state.status == CastStatus.running) ...[
            const SizedBox(height: 10),
            _FrameRateRow(state: state),
          ],
          const SizedBox(height: 14),
          if (state.status == CastStatus.running) ...[
            SizedBox(
              width: double.infinity,
              child: FilledButton.tonalIcon(
                key: const Key('show-video-window'),
                onPressed: onShowVideoWindow,
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
                label: const Text('显示视频窗口'),
              ),
            ),
            const SizedBox(height: 8),
          ],
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: state.canStop ? onStop : null,
              icon: const Icon(Icons.stop_rounded),
              label: Text(
                state.status == CastStatus.stopping ? '清理中……' : '停止并清理',
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetaChip(label: 'ADB HOST'),
              _MetaChip(label: 'UID 2000'),
              _MetaChip(label: 'FFmpeg FFI'),
              _MetaChip(label: 'SCRC v0'),
            ],
          ),
        ],
      ),
    );
  }

  bool _isConnected(DiscoveredDevice device) {
    if (state.status != CastStatus.running) {
      return false;
    }
    if (device.kind == DiscoveredDeviceKind.usb) {
      return state.serial != null && state.serial == device.serial;
    }
    return state.host.trim() == device.host;
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({
    required this.device,
    required this.connected,
    required this.enabled,
    required this.onTap,
  });

  final DiscoveredDevice device;
  final bool connected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isUsb = device.kind == DiscoveredDeviceKind.usb;
    return Material(
      color: connected
          ? const Color(0xFF35E0A1).withValues(alpha: 0.10)
          : Colors.white.withValues(alpha: 0.03),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: enabled && !connected ? onTap : null,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: connected
                  ? const Color(0xFF35E0A1).withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.06),
            ),
          ),
          child: Row(
            children: [
              Icon(
                isUsb ? Icons.usb_rounded : Icons.wifi_rounded,
                size: 20,
                color: connected
                    ? const Color(0xFF35E0A1)
                    : const Color(0xFF8FA1B1),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.label,
                      style: const TextStyle(
                        fontSize: 13,
                        fontFamily: 'monospace',
                        color: Color(0xFFD7E4EF),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      device.detail,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Color(0xFF72879A),
                      ),
                    ),
                  ],
                ),
              ),
              if (connected)
                const Text(
                  '已连接',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF35E0A1),
                    fontWeight: FontWeight.w600,
                  ),
                )
              else
                const Text(
                  '连接',
                  style: TextStyle(
                    fontSize: 12,
                    color: Color(0xFF35E0A1),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionSwitch extends StatelessWidget {
  const _OptionSwitch({
    required this.switchKey,
    required this.title,
    required this.value,
    required this.trailingLabel,
    required this.onChanged,
    this.helper,
    this.statusLine,
    this.statusIsError = false,
  });

  final Key switchKey;
  final String title;
  final bool value;
  final String trailingLabel;
  final ValueChanged<bool> onChanged;
  final String? helper;
  final String? statusLine;
  final bool statusIsError;

  @override
  Widget build(BuildContext context) {
    final status = statusLine ?? '';
    final statusColor = statusIsError
        ? const Color(0xFFFF8080)
        : const Color(0xFF7F93A5);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              height: 30,
              width: 42,
              child: FittedBox(
                fit: BoxFit.contain,
                child: Switch(
                  key: switchKey,
                  value: value,
                  onChanged: onChanged,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  color: Color(0xFFB3C2CF),
                ),
              ),
            ),
            Text(
              trailingLabel,
              style: const TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                color: Color(0xFF6F8293),
              ),
            ),
          ],
        ),
        if (status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              status,
              style: TextStyle(
                fontSize: 11,
                height: 1.45,
                color: statusColor,
              ),
            ),
          ),
        if (helper != null)
          Padding(
            padding: const EdgeInsets.only(left: 2, top: 2),
            child: Text(
              helper!,
              style: const TextStyle(
                fontSize: 11,
                height: 1.45,
                color: Color(0xFF6F8293),
              ),
            ),
          ),
      ],
    );
  }
}

class _FrameRateRow extends StatelessWidget {
  const _FrameRateRow({required this.state});

  final CastSessionState state;

  @override
  Widget build(BuildContext context) {
    final decode = state.framesPerSecond;
    final present = state.presentFps;
    final showHint = shouldShowFrameRateHint(
      decodeFps: decode,
      presentFps: present,
    );
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.speed_rounded,
                size: 16,
                color: Color(0xFF72879A),
              ),
              const SizedBox(width: 9),
              Text(
                frameRateSummary(decodeFps: decode, presentFps: present),
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: Color(0xFFA7B6C4),
                ),
              ),
            ],
          ),
          if (showHint)
            const Padding(
              padding: EdgeInsets.only(left: 25, top: 6),
              child: Text(
                frameRateHintText,
                style: TextStyle(
                  fontSize: 11,
                  height: 1.45,
                  color: Color(0xFFFFC078),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _MessageBox extends StatelessWidget {
  const _MessageBox({required this.status, required this.message});

  final CastStatus status;
  final String message;

  Color get _color {
    switch (status) {
      case CastStatus.error:
        return const Color(0xFFFF6B6B);
      case CastStatus.running:
        return const Color(0xFF35E0A1);
      default:
        return const Color(0xFF7F93A5);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: 58),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _color.withValues(alpha: 0.2)),
      ),
      child: Text(
        message,
        style: TextStyle(
          color: _color,
          fontSize: 12,
          height: 1.5,
        ),
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          letterSpacing: 0.6,
          color: Color(0xFF8FA1B1),
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
