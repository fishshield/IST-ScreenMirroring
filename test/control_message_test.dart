import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/control/control_client.dart';
import 'package:screen_cast_demo/src/control/control_message.dart';

void main() {
  test('touch frame uses 1-byte type, big-endian length and two floats', () {
    final message = ControlMessage.touch(
      ControlMessageType.touchDown,
      0.25,
      0.5,
    );
    final bytes = message.encode();

    expect(bytes.length, ControlMessage.headerBytes + 8);
    expect(bytes[0], 0x01);
    // 4-byte big-endian payload length.
    expect(bytes.sublist(1, 5), <int>[0, 0, 0, 8]);

    final data = ByteData.sublistView(bytes);
    expect(data.getFloat32(5, Endian.big), closeTo(0.25, 1e-6));
    expect(data.getFloat32(9, Endian.big), closeTo(0.5, 1e-6));
  });

  test('key frame carries a 4-byte big-endian Android keycode', () {
    final bytes =
        ControlMessage.key(ControlMessageType.keyUp, 66).encode();
    expect(bytes[0], 0x06);
    expect(bytes.sublist(1, 5), <int>[0, 0, 0, 4]);
    expect(ByteData.sublistView(bytes).getInt32(5, Endian.big), 66);
  });

  test('wheel frame carries the raw Windows delta unchanged', () {
    final bytes = ControlMessage.wheel(120).encode();
    expect(bytes[0], 0x04);
    expect(bytes.sublist(1, 5), <int>[0, 0, 0, 4]);
    // The Windows overlay must not pre-negate: the server owns the single sign
    // flip that turns the delta into AXIS_VSCROLL.
    expect(ByteData.sublistView(bytes).getInt32(5, Endian.big), 120);
    expect(ControlMessage.decode(bytes).intPayload, 120);
  });

  test('wheel frame round-trips a backwards delta', () {
    final bytes = ControlMessage.wheel(-240).encode();
    expect(ByteData.sublistView(bytes).getInt32(5, Endian.big), -240);
    expect(ControlMessage.decode(bytes).intPayload, -240);
  });

  test('normalized coordinates are clamped to 0..1', () {
    final message =
        ControlMessage.touch(ControlMessageType.touchMove, -0.5, 1.5);
    expect(message.normalizedX, 0.0);
    expect(message.normalizedY, 1.0);
  });

  test('decode rejects unknown types, oversized payloads and truncation', () {
    expect(
      () => ControlMessage.decode(Uint8List.fromList(<int>[0x7F, 0, 0, 0, 0])),
      throwsFormatException,
    );
    expect(
      () => ControlMessage.decode(
        Uint8List.fromList(<int>[0x01, 0, 0, 1, 0]),
      ),
      throwsFormatException,
    );
    expect(
      () => ControlMessage.decode(
        Uint8List.fromList(<int>[0x01, 0, 0, 0, 8, 0, 0]),
      ),
      throwsFormatException,
    );
  });

  test('control client frames messages over a real socket', () async {
    final server = await ServerSocketStub.start();
    addTearDown(server.close);

    final client = ControlClient(host: '127.0.0.1', port: server.port);
    await client.connect();
    addTearDown(client.close);

    expect(client.isConnected, isTrue);
    expect(
      client.send(ControlMessage.touch(ControlMessageType.touchDown, 0.5, 0.5)),
      isTrue,
    );
    expect(
      client.send(ControlMessage.key(ControlMessageType.keyDown, 21)),
      isTrue,
    );

    final received = await server.received;
    expect(received.length, ControlMessage.headerBytes + 8 + ControlMessage.headerBytes + 4);
    expect(received[0], 0x01);
    expect(received[13], 0x05);
  });

  test('control client reports a disconnect without throwing', () async {
    final server = await ServerSocketStub.start();
    var disconnected = false;

    final client = ControlClient(host: '127.0.0.1', port: server.port)
      ..onDisconnected = () => disconnected = true;
    await client.connect();
    await server.close();

    // Give the socket close a moment to propagate.
    for (var attempt = 0; attempt < 50 && !disconnected; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(disconnected, isTrue);
    expect(client.send(ControlMessage.wheel(1)), isFalse);
  });
}

/// Minimal one-shot TCP server that records the bytes a [ControlClient] sends.
class ServerSocketStub {
  ServerSocketStub._(this._server);

  final ServerSocket _server;
  final List<int> _bytes = <int>[];
  Socket? _client;

  static Future<ServerSocketStub> start() async {
    final stub = ServerSocketStub._(
      await ServerSocket.bind('127.0.0.1', 0),
    );
    stub._listen();
    return stub;
  }

  int get port => _server.port;

  Future<List<int>> get received async {
    // Two frames are expected by the caller (13 + 9 bytes).
    while (_bytes.length < 22) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    return List<int>.of(_bytes);
  }

  void _listen() {
    _server.listen((Socket socket) {
      _client = socket;
      socket.listen(
        (Uint8List chunk) {
          _bytes.addAll(chunk);
        },
        onDone: () {},
        onError: (Object _) {},
      );
    });
  }

  /// Closes the accepted connection first: closing only the [ServerSocket] does
  /// not terminate an established socket, so the peer would never see EOF.
  Future<void> close() async {
    await _client?.close();
    _client = null;
    await _server.close();
  }
}
