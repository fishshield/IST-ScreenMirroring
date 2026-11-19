import 'dart:typed_data';

/// One SCRC transport frame.
///
/// Wire format, all integers big-endian:
///
/// ```text
/// 0               4               8
/// +---------------+---------------+
/// | magic: SCRC   | payloadLength |
/// +---------------+---------------+
/// | payload: exactly one H.264 NAL unit, without Annex-B start code |
/// +---------------------------------------------------------------+
/// ```
class ScrcPacket {
  ScrcPacket({required this.payload}) {
    if (payload.isEmpty) {
      throw ArgumentError.value(
        payload,
        'payload',
        'One packet must contain exactly one non-empty H.264 NAL unit.',
      );
    }
    if (payload.length > maxPayloadLength) {
      throw ArgumentError.value(
        payload.length,
        'payload.length',
        'The payload exceeds the $maxPayloadLength byte limit.',
      );
    }
  }

  /// ASCII "SCRC" as a 32-bit big-endian integer.
  static const int magic = 0x53435243;
  static const int headerLength = 8;
  static const int maxPayloadLength = 16 * 1024 * 1024;

  final Uint8List payload;

  Uint8List encode() {
    final bytes = Uint8List(headerLength + payload.length);
    final header = ByteData.sublistView(bytes);
    header.setUint32(0, magic, Endian.big);
    header.setUint32(4, payload.length, Endian.big);
    bytes.setRange(headerLength, bytes.length, payload);
    return bytes;
  }

  @override
  String toString() => 'ScrcPacket(${payload.length} bytes)';
}

class ScrcProtocolException implements Exception {
  const ScrcProtocolException(this.message);

  final String message;

  @override
  String toString() => 'ScrcProtocolException: $message';
}
