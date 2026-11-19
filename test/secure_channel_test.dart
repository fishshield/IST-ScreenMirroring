import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/control/control_message.dart';
import 'package:screen_cast_demo/src/crypto/psk_cipher.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet.dart';
import 'package:screen_cast_demo/src/protocol/scrc_packet_decoder.dart';
import 'package:screen_cast_demo/src/transport/secure_channel.dart';
import 'package:screen_cast_demo/src/transport/transport.dart';

/// 16-byte AES-128 key; longer keys are covered by the cipher tests below.
const String _psk = '00112233445566778899aabbccddeeff';

void main() {
  group('PskCipher', () {
    test('rejects malformed hex and unsupported key lengths', () {
      String keyOf(int bytes) => List<String>.filled(bytes, '00').join();
      expect(PskCipher.validateHex(''), isNull);
      expect(PskCipher.validateHex(keyOf(16)), isNull);
      expect(PskCipher.validateHex(keyOf(24)), isNull);
      expect(PskCipher.validateHex(keyOf(32)), isNull);
      expect(PskCipher.validateHex('abc'), isNotNull);
      expect(PskCipher.validateHex('zz${keyOf(16).substring(2)}'), isNotNull);
      expect(PskCipher.validateHex(keyOf(8)), isNotNull);
      expect(
        () => PskCipher.fromHex(keyOf(8)),
        throwsA(isA<PskException>()),
      );
    });

    test('fromHex returns null for a blank key', () {
      expect(PskCipher.fromHex('   '), isNull);
    });
  });

  test('(a) encrypt -> decrypt returns the original bytes, across records',
      () async {
    final link = _MemoryLink();
    final cipher = PskCipher.fromHex(_psk)!;
    final sender = SecureChannel(link.a, cipher);
    final receiver = SecureChannel(link.b, cipher);
    addTearDown(() async {
      await sender.close();
      await receiver.close();
    });

    // 150 KB spans three 64 KB records.
    final payload = Uint8List.fromList(
      List<int>.generate(150 * 1024, (int index) => (index * 31) & 0xFF),
    );
    final received = <int>[];
    final done = Completer<void>();
    receiver.incoming.listen(
      (Uint8List chunk) {
        received.addAll(chunk);
        if (received.length >= payload.length && !done.isCompleted) {
          done.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!done.isCompleted) {
          done.completeError(error, stackTrace);
        }
      },
    );

    sender.send(payload);
    await done.future.timeout(const Duration(seconds: 10));

    expect(received.length, payload.length);
    expect(received, payload);
  });

  test('(b) tampering any ciphertext byte fails authentication', () async {
    final capture = _CaptureTransport();
    final cipher = PskCipher.fromHex(_psk)!;
    final sender = SecureChannel(capture, cipher);
    final receiverEnd = _MemoryEndpoint();
    final receiver = SecureChannel(receiverEnd, PskCipher.fromHex(_psk));
    addTearDown(() async {
      await sender.close();
      await receiver.close();
    });

    final errors = <Object>[];
    final errorSeen = Completer<Object>();
    receiver.incoming.listen(
      (_) {},
      onError: (Object error) {
        errors.add(error);
        if (!errorSeen.isCompleted) {
          errorSeen.complete(error);
        }
      },
    );

    sender.send(Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]));
    await _pumpUntil(() => capture.sent.isNotEmpty);
    final record = Uint8List.fromList(capture.sent);

    // Flip one byte in the ciphertext area (after length + nonce).
    final tampered = Uint8List.fromList(record);
    tampered[record.length - 20] ^= 0xFF;
    receiverEnd.deliver(tampered);

    final error = await errorSeen.future.timeout(const Duration(seconds: 5));
    expect(error, isA<PskException>());
    expect(errors.single, isA<PskException>());
  });

  test('(c) SCRC frames round-trip unchanged through the record layer',
      () async {
    final link = _MemoryLink();
    final sender = SecureChannel(link.a, PskCipher.fromHex(_psk));
    final receiver = SecureChannel(link.b, PskCipher.fromHex(_psk));
    addTearDown(() async {
      await sender.close();
      await receiver.close();
    });

    final payload = Uint8List.fromList(
      List<int>.generate(700, (int index) => (index * 7) & 0xFF),
    );
    final packet = ScrcPacket(payload: payload);

    final decoder = ScrcPacketDecoder();
    final decoded = <ScrcPacket>[];
    receiver.incoming.listen(
      (Uint8List chunk) => decoded.addAll(decoder.add(chunk)),
      onError: (Object error) => fail('unexpected error: $error'),
    );

    sender.send(packet.encode());
    await _pumpUntil(() => decoded.isNotEmpty);

    expect(decoded.single.payload, payload);
  });

  test('(c) control frames round-trip unchanged through the record layer',
      () async {
    final link = _MemoryLink();
    final sender = SecureChannel(link.a, PskCipher.fromHex(_psk));
    final receiver = SecureChannel(link.b, PskCipher.fromHex(_psk));
    addTearDown(() async {
      await sender.close();
      await receiver.close();
    });

    final message =
        ControlMessage.touch(ControlMessageType.touchDown, 0.25, 0.75);
    final decoded = <ControlMessage>[];
    final buffer = <int>[];
    receiver.incoming.listen(
      (Uint8List chunk) {
        buffer.addAll(chunk);
        if (buffer.length >= message.encode().length) {
          decoded.add(ControlMessage.decode(Uint8List.fromList(buffer)));
        }
      },
      onError: (Object error) => fail('unexpected error: $error'),
    );

    sender.send(message.encode());
    await _pumpUntil(() => decoded.isNotEmpty);

    expect(decoded.single.type, ControlMessageType.touchDown);
    expect(decoded.single.normalizedX, closeTo(0.25, 1e-6));
    expect(decoded.single.normalizedY, closeTo(0.75, 1e-6));
  });

  test('encryption changes the wire bytes; a null cipher passes through',
      () async {
    // Encrypted: the wire must not contain the plaintext.
    final capture = _CaptureTransport();
    final secure = SecureChannel(capture, PskCipher.fromHex(_psk));
    addTearDown(secure.close);
    final secret = Uint8List.fromList(<int>[9, 9, 9, 9, 9, 9, 9, 9]);
    secure.send(secret);
    await _pumpUntil(() => capture.sent.isNotEmpty);
    expect(capture.sent.length, secureRecordLength(secret.length));
    expect(capture.sent.sublist(4 + 12, 4 + 12 + secret.length), isNot(secret));

    // Plaintext: bytes arrive untouched and unframed.
    final plainCapture = _CaptureTransport();
    final plain = SecureChannel(plainCapture, null);
    addTearDown(plain.close);
    plain.send(Uint8List.fromList(<int>[1, 2, 3]));
    await _pumpUntil(() => plainCapture.sent.isNotEmpty);
    expect(plainCapture.sent, <int>[1, 2, 3]);
  });

  test('malformed record length closes the stream with an error', () async {
    final endpoint = _MemoryEndpoint();
    final receiver = SecureChannel(endpoint, PskCipher.fromHex(_psk));
    addTearDown(receiver.close);

    final errorSeen = Completer<Object>();
    receiver.incoming.listen(
      (_) {},
      onError: (Object error) {
        if (!errorSeen.isCompleted) {
          errorSeen.complete(error);
        }
      },
    );

    // Length field claims more than the 64 KB + 28 byte maximum.
    endpoint.deliver(
      Uint8List.fromList(<int>[0x00, 0x10, 0x00, 0x00, 0, 0, 0, 0]),
    );
    expect(
      await errorSeen.future.timeout(const Duration(seconds: 5)),
      isA<PskException>(),
    );
  });
}

/// Total encrypted record size for [plaintextLength] bytes.
int secureRecordLength(int plaintextLength) {
  return SecureChannel.lengthBytes +
      PskCipher.nonceBytes +
      plaintextLength +
      PskCipher.tagBytes;
}

/// Two connected in-memory [Transport] endpoints.
class _MemoryLink {
  _MemoryLink() {
    a = _MemoryEndpoint();
    b = _MemoryEndpoint();
    a.peer = b;
    b.peer = a;
  }

  late final _MemoryEndpoint a;
  late final _MemoryEndpoint b;
}

class _MemoryEndpoint implements Transport {
  _MemoryEndpoint();

  late _MemoryEndpoint peer;
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  void send(Uint8List bytes) {
    if (_closed || peer._closed) {
      return;
    }
    peer.deliver(Uint8List.fromList(bytes));
  }

  /// Feeds raw bytes into this endpoint's inbound stream.
  void deliver(Uint8List bytes) {
    if (!_incoming.isClosed) {
      _incoming.add(Uint8List.fromList(bytes));
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }
}

/// Transport that records everything written and never delivers it.
class _CaptureTransport implements Transport {
  final List<int> sent = <int>[];

  @override
  Stream<Uint8List> get incoming => const Stream<Uint8List>.empty();

  @override
  void send(Uint8List bytes) {
    sent.addAll(bytes);
  }

  @override
  Future<void> close() async {}
}

Future<void> _pumpUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met within $timeout.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}
