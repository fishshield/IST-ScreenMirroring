import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// One LAN discovery announcement sent by the Android controller app.
///
/// The payload is deliberately small and carries **no secrets**: only the
/// phone address, the two TCP ports and a flag saying whether the running
/// server expects a PSK. The PSK itself never leaves the two endpoints; the
/// real session still goes through TCP + [SecureChannel], unchanged.
///
/// ```json
/// {"type":"screencast-offer","ip":"192.168.1.134",
///  "videoPort":27183,"controlPort":27184,"pskRequired":false}
/// ```
@immutable
class CastOffer {
  const CastOffer({
    required this.ip,
    this.videoPort = defaultVideoPort,
    this.controlPort = defaultControlPort,
    this.pskRequired = false,
  });

  /// Marker that distinguishes an offer from any other UDP payload.
  static const String type = 'screencast-offer';

  /// UDP port the desktop listens on; the phone broadcasts to it.
  static const int discoveryPort = 27185;

  static const int defaultVideoPort = 27183;
  static const int defaultControlPort = 27184;

  /// LAN address of the phone, as seen by the phone's own interface.
  final String ip;

  /// SCRC/H.264 TCP port (27183 in the shipped server).
  final int videoPort;

  /// Input-injection TCP port (27184 in the shipped server).
  final int controlPort;

  /// True when the running capture server was started with `--psk-hex`.
  ///
  /// The desktop then has to use its configured PSK; when false it connects
  /// without one even if a key is configured in the UI.
  final bool pskRequired;

  Map<String, Object?> toJson() => <String, Object?>{
        'type': type,
        'ip': ip,
        'videoPort': videoPort,
        'controlPort': controlPort,
        'pskRequired': pskRequired,
      };

  String encode() => jsonEncode(toJson());

  /// Parses and validates a broadcast datagram.
  ///
  /// Returns null for anything that is not a well-formed offer: a different
  /// `type`, a non-IPv4 address, out-of-range ports, a video/control port
  /// collision, or malformed JSON. Callers must treat null as "ignore".
  static CastOffer? tryParse(String text) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    return tryParseJson(decoded);
  }

  /// Validates an already-decoded JSON value (see [tryParse]).
  static CastOffer? tryParseJson(Object? decoded) {
    if (decoded is! Map) {
      return null;
    }
    if (decoded['type'] != type) {
      return null;
    }
    final rawIp = decoded['ip'];
    if (rawIp is! String) {
      return null;
    }
    final ip = rawIp.trim();
    final address = InternetAddress.tryParse(ip);
    if (address == null || address.rawAddress.length != 4) {
      return null;
    }

    final videoPort = _readPort(decoded['videoPort']);
    final controlPort = _readPort(decoded['controlPort']);
    if (videoPort == null || controlPort == null) {
      return null;
    }
    if (videoPort == controlPort) {
      return null;
    }

    final rawPsk = decoded['pskRequired'];
    final pskRequired = rawPsk is bool ? rawPsk : false;

    return CastOffer(
      ip: ip,
      videoPort: videoPort,
      controlPort: controlPort,
      pskRequired: pskRequired,
    );
  }

  static int? _readPort(Object? value) {
    if (value is! num) {
      return null;
    }
    final port = value.toInt();
    if (port != value) {
      return null;
    }
    if (port < 1024 || port > 65535) {
      return null;
    }
    return port;
  }

  @override
  bool operator ==(Object other) =>
      other is CastOffer &&
      other.ip == ip &&
      other.videoPort == videoPort &&
      other.controlPort == controlPort &&
      other.pskRequired == pskRequired;

  @override
  int get hashCode => Object.hash(ip, videoPort, controlPort, pskRequired);

  @override
  String toString() =>
      'CastOffer($ip video=$videoPort control=$controlPort '
      'pskRequired=$pskRequired)';
}
