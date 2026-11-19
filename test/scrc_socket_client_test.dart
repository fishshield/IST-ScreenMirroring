import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet.dart';
import 'package:screen_cast_demo/src/transport/scrc_socket_client.dart';

void main() {
  test('reads SCRC frames split across TCP chunks', () async {
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final first = ScrcPacket(
      payload: Uint8List.fromList(<int>[0x67, 0x42, 0x00, 0x1f]),
    ).encode();
    final second = ScrcPacket(
      payload: Uint8List.fromList(<int>[0x68, 0xce, 0x38, 0x80]),
    ).encode();

    final serverTask = listener.first.then((Socket socket) async {
      socket.add(first.sublist(0, 5));
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      socket.add(<int>[...first.sublist(5), ...second.sublist(0, 2)]);
      await socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      socket.add(second.sublist(2));
      await socket.flush();
      await socket.close();
    });

    final client = ScrcSocketClient(
      host: listener.address.address,
      port: listener.port,
    );
    expect(client.endpoint, '${listener.address.address}:${listener.port}');
    final connection = await client.connect();
    final packets = await connection.packets.take(2).toList().timeout(
          const Duration(seconds: 3),
        );

    expect(packets, hasLength(2));
    expect(packets[0].payload, <int>[0x67, 0x42, 0x00, 0x1f]);
    expect(packets[1].payload, <int>[0x68, 0xce, 0x38, 0x80]);

    await serverTask;
    await connection.close();
    await listener.close();
  });

  test('rejects an empty configured host', () async {
    final client = ScrcSocketClient(host: '  ', port: 27183);
    await expectLater(
      client.connect(),
      throwsA(isA<ScrcConnectionException>()),
    );
  });
}
