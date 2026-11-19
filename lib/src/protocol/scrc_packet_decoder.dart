import 'dart:typed_data';

import 'scrc_packet.dart';

/// Incremental decoder for the SCRC transport framing.
///
/// Feed TCP chunks with [add]. Any number of frames may be buffered internally;
/// only complete frames are emitted. The decoder is stateful and not safe for
/// concurrent calls.
class ScrcPacketDecoder {
  ScrcPacketDecoder({this.maxPayloadLength = ScrcPacket.maxPayloadLength}) {
    if (maxPayloadLength <= 0) {
      throw ArgumentError.value(
        maxPayloadLength,
        'maxPayloadLength',
        'Must be greater than zero.',
      );
    }
  }

  final int maxPayloadLength;

  Uint8List _buffer = Uint8List(0);

  int get bufferedBytes => _buffer.length;

  List<ScrcPacket> add(List<int> chunk) {
    if (chunk.isEmpty) {
      return const <ScrcPacket>[];
    }

    final merged = Uint8List(_buffer.length + chunk.length)
      ..setRange(0, _buffer.length, _buffer)
      ..setRange(_buffer.length, _buffer.length + chunk.length, chunk);
    _buffer = merged;

    final packets = <ScrcPacket>[];
    while (_buffer.length >= ScrcPacket.headerLength) {
      final header = ByteData.sublistView(
        _buffer,
        0,
        ScrcPacket.headerLength,
      );
      final magic = header.getUint32(0, Endian.big);
      if (magic != ScrcPacket.magic) {
        throw ScrcProtocolException(
          'Invalid magic 0x${magic.toRadixString(16).padLeft(8, '0')}; '
          'expected 0x${ScrcPacket.magic.toRadixString(16)}.',
        );
      }

      final payloadLength = header.getUint32(4, Endian.big);
      if (payloadLength == 0) {
        throw const ScrcProtocolException('Empty NAL payload.');
      }
      if (payloadLength > maxPayloadLength) {
        throw ScrcProtocolException(
          'NAL payload of $payloadLength bytes exceeds the $maxPayloadLength '
          'byte limit.',
        );
      }

      final frameLength = ScrcPacket.headerLength + payloadLength;
      if (_buffer.length < frameLength) {
        break;
      }

      final payload = Uint8List.fromList(
        _buffer.sublist(ScrcPacket.headerLength, frameLength),
      );
      packets.add(ScrcPacket(payload: payload));
      _buffer = Uint8List.fromList(_buffer.sublist(frameLength));
    }

    return packets;
  }

  void reset() {
    _buffer = Uint8List(0);
  }
}
