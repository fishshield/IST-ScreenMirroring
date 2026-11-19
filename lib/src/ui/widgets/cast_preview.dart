import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../cast/cast_session_state.dart';
import '../../windows/native_video_surface.dart';

class CastPreview extends StatefulWidget {
  const CastPreview({
    super.key,
    required this.state,
    required this.viewportRevision,
    required this.clipViewportKey,
    required this.nativeVideoController,
  });

  final CastSessionState state;
  final ValueListenable<int> viewportRevision;
  final GlobalKey clipViewportKey;
  final NativeVideoSurfaceController nativeVideoController;

  @override
  State<CastPreview> createState() => _CastPreviewState();
}

class _CastPreviewState extends State<CastPreview> {
  String _backend = '检测中';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final state = widget.state;
    final viewportRevision = widget.viewportRevision;
    final clipViewportKey = widget.clipViewportKey;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1016),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 2, 6, 12),
            child: Row(
              children: [
                const Icon(
                  Icons.window_outlined,
                  size: 18,
                  color: Color(0xFF8FA1B1),
                ),
                const SizedBox(width: 9),
                Text(
                  '实时预览',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    'Win32 · $_backend',
                    style: TextStyle(
                      fontSize: 9,
                      letterSpacing: 0.5,
                      color: colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                _ControlBadge(link: state.controlLink),
                const SizedBox(width: 14),
                Text(
                  state.frameSize ?? '--',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8FA1B1),
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  '${state.framesDecoded} frames',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8FA1B1),
                    fontFamily: 'monospace',
                  ),
                ),
                if (state.framesPerSecond > 0) ...[
                  const SizedBox(width: 14),
                  Text(
                    '${state.framesPerSecond} fps',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8FA1B1),
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
                const SizedBox(width: 14),
                Text(
                  '${state.framesDropped} dropped',
                  style: TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: state.framesDropped > 0
                        ? const Color(0xFFF0C674)
                        : const Color(0xFF8FA1B1),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(1),
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: NativeVideoSurface(
                  clipViewportKey: clipViewportKey,
                  controller: widget.nativeVideoController,
                  revision: viewportRevision,
                  onBackendChanged: (String backend) {
                    if (mounted) {
                      setState(() {
                        _backend = backend;
                      });
                    }
                  },
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 12, 6, 2),
            child: Row(
              children: [
                Icon(
                  Icons.lan_outlined,
                  size: 14,
                  color: colorScheme.primary,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '${state.endpoint}  ·  SCRC / H.264  ·  '
                    '${state.adbSerial ?? "未连接设备"}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF8093A4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Input-channel indicator. Video and control are independent links: this can
/// read "控制已断开" while frames keep flowing.
class _ControlBadge extends StatelessWidget {
  const _ControlBadge({required this.link});

  final ControlLinkState link;

  @override
  Widget build(BuildContext context) {
    final Color color;
    final IconData icon;
    switch (link) {
      case ControlLinkState.connected:
        color = const Color(0xFF35E0A1);
        icon = Icons.mouse_outlined;
      case ControlLinkState.connecting:
        color = const Color(0xFFF0C674);
        icon = Icons.sync_rounded;
      case ControlLinkState.disconnected:
        color = const Color(0xFFFF9F6B);
        icon = Icons.link_off_rounded;
      case ControlLinkState.idle:
        color = const Color(0xFF6F8293);
        icon = Icons.mouse_outlined;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: color),
          const SizedBox(width: 5),
          Text(
            link.label,
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 0.3,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
