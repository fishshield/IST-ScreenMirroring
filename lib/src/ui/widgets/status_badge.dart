import 'package:flutter/material.dart';

import '../../cast/cast_session_state.dart';

class CastStatusBadge extends StatelessWidget {
  const CastStatusBadge({super.key, required this.status});

  final CastStatus status;

  Color _color() {
    switch (status) {
      case CastStatus.idle:
        return const Color(0xFF8A9AAA);
      case CastStatus.starting:
      case CastStatus.stopping:
        return const Color(0xFFF0C674);
      case CastStatus.running:
        return const Color(0xFF35E0A1);
      case CastStatus.error:
        return const Color(0xFFFF6B6B);
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(99),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Text(
            status.label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
