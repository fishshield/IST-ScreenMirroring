import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet_decoder.dart';

void main() {
  group('ScrcPacket', () {
    test('encodes the 8-byte big-endian header', () {
      final packet = ScrcPacket(
        payload: Uint8List.fromList(<int>[0x65, 0x88, 0x84, 0x00]),
      );

      final bytes = packet.encode();

      expect(bytes, hasLength(12));
      expect(bytes.sublist(0, 4), <int>[0x53, 0x43, 0x52, 0x43]);
      expect(
        ByteData.sublistView(bytes).getUint32(4, Endian.big),
        packet.payload.length,
      );
      expect(bytes.sublist(8), packet.payload);
    });

    test('rejects an empty NAL payload', () {
      expect(
        () => ScrcPacket(payload: Uint8List(0)),
        throwsArgumentError,
      );
    });
  });

  group('ScrcPacketDecoder', () {
    test('waits for complete header and payload across chunks', () {
      final source = ScrcPacket(
        payload: Uint8List.fromList(List<int>.generate(32, (int i) => i)),
      ).encode();
      final decoder = ScrcPacketDecoder();

      expect(decoder.add(source.sublist(0, 3)), isEmpty);
      expect(decoder.add(source.sublist(3, 8)), isEmpty);
      expect(decoder.add(source.sublist(8, 21)), isEmpty);

      final packets = decoder.add(source.sublist(21));

      expect(packets, hasLength(1));
      expect(packets.single.payload, source.sublist(8));
      expect(decoder.bufferedBytes, 0);
    });

    test('decodes multiple concatenated frames', () {
      final first = ScrcPacket(
        payload: Uint8List.fromList(<int>[1, 2, 3]),
      ).encode();
      final second = ScrcPacket(
        payload: Uint8List.fromList(<int>[9, 8, 7, 6, 5]),
      ).encode();

      final packets = ScrcPacketDecoder().add(<int>[...first, ...second]);

      expect(packets, hasLength(2));
      expect(packets[0].payload, <int>[1, 2, 3]);
      expect(packets[1].payload, <int>[9, 8, 7, 6, 5]);
    });

    test('rejects an invalid magic', () {
      final bytes = ByteData(8)
        ..setUint32(0, 0x4E4F5045, Endian.big)
        ..setUint32(4, 1, Endian.big);

      expect(
        () => ScrcPacketDecoder().add(bytes.buffer.asUint8List()),
        throwsA(isA<ScrcProtocolException>()),
      );
    });

    test('rejects a payload over the configured limit', () {
      final bytes = ByteData(8)
        ..setUint32(0, ScrcPacket.magic, Endian.big)
        ..setUint32(4, 17, Endian.big);

      final decoder = ScrcPacketDecoder(maxPayloadLength: 16);

      expect(
        () => decoder.add(bytes.buffer.asUint8List()),
        throwsA(isA<ScrcProtocolException>()),
      );
    });

    test('rejects a zero-length payload', () {
      final bytes = ByteData(8)
        ..setUint32(0, ScrcPacket.magic, Endian.big)
        ..setUint32(4, 0, Endian.big);

      expect(
        () => ScrcPacketDecoder().add(bytes.buffer.asUint8List()),
        throwsA(isA<ScrcProtocolException>()),
      );
    });
  });
}
