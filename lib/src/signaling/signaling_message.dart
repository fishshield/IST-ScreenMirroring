import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Minimal JSON control message used by the signaling layer.
///
/// The envelope is `{"type": "...", ...payload}`. Media NAL units never travel
/// through this channel; they use the SCRC socket framing instead.
@immutable
class SignalingMessage {
  SignalingMessage({
    required this.type,
    Map<String, Object?> payload = const <String, Object?>{},
  })  : assert(type.isNotEmpty, 'type must not be empty'),
        payload = Map<String, Object?>.unmodifiable(payload);

  final String type;
  final Map<String, Object?> payload;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        ...payload,
      };

  String encode() => jsonEncode(toJson());

  static SignalingMessage? tryParse(Object? raw) {
    if (raw is! String) {
      return null;
    }

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        return null;
      }

      final type = decoded['type'];
      if (type is! String || type.isEmpty) {
        return null;
      }

      final payload = <String, Object?>{...decoded}..remove('type');
      return SignalingMessage(type: type, payload: payload);
    } on FormatException {
      return null;
    }
  }

  @override
  String toString() => 'SignalingMessage($type)';
}
