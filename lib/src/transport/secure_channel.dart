import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../crypto/psk_cipher.dart';
import 'transport.dart';

/// ChaCha/TLS-style record layer: encrypts an arbitrary [Transport] without
/// knowing anything about the bytes it carries.
///
/// Record framing on the wire:
///
/// ```text
/// +----------------+----------------+------------------+-----------+
/// | length: uint32 | nonce: 12 bytes| ciphertext       | tag: 16 B |
/// +----------------+----------------+------------------+-----------+
///        big-endian   random per record   plaintext length   GCM tag
/// ```
///
/// The length covers `nonce + ciphertext + tag`. A byte stream needs an explicit
/// record boundary; the GCM tag alone cannot delimit records.
///
/// Each [send] is split into records of at most [maxRecordBytes] plaintext
/// bytes. Encryption is asynchronous (the cipher API is Future-based), so sends
/// are queued and written in order. The incoming stream decrypts record by
/// record and emits plaintext chunks; neither SCRC nor the control protocol is
/// parsed here.
///
/// With a null cipher the channel degrades to a pass-through and logs a warning.
class SecureChannel implements Transport {
  SecureChannel(this._inner, this._cipher) {
    if (_cipher == null) {
      debugPrint(
        'SecureChannel: WARNING: no PSK configured, traffic is PLAINTEXT.',
      );
      _passthrough = true;
      _incoming = _inner.incoming;
    } else {
      _incoming = _plaintext.stream;
      unawaited(_pump());
    }
  }

  /// Maximum plaintext bytes per record.
  static const int maxRecordBytes = 64 * 1024;

  /// `length` field in front of the record body.
  static const int lengthBytes = 4;

  /// Nonce + GCM tag that every record carries.
  static const int overheadBytes = PskCipher.nonceBytes + PskCipher.tagBytes;

  final Transport _inner;
  final PskCipher? _cipher;
  final StreamController<Uint8List> _plaintext =
      StreamController<Uint8List>();

  late final Stream<Uint8List> _incoming;
  bool _passthrough = false;
  bool _closed = false;
  Future<void> _sendQueue = Future<void>.value();

  bool get isEncrypted => !_passthrough;

  @override
  Stream<Uint8List> get incoming => _incoming;

  @override
  void send(Uint8List bytes) {
    if (_closed || bytes.isEmpty) {
      return;
    }
    if (_passthrough) {
      _inner.send(bytes);
      return;
    }
    var offset = 0;
    while (offset < bytes.length) {
      final end = math.min(offset + maxRecordBytes, bytes.length);
      // The crypto API is async; copy now so a caller reusing its buffer cannot
      // mutate the bytes before the record is sealed.
      final chunk = Uint8List.fromList(
        Uint8List.sublistView(bytes, offset, end),
      );
      _sendQueue = _sendQueue
          .then((_) => _sendRecord(chunk))
          .catchError((Object error, StackTrace stackTrace) {
        _failChannel(error, stackTrace);
      });
      offset = end;
    }
  }

  Future<void> _sendRecord(Uint8List plaintext) async {
    final cipher = _cipher;
    if (cipher == null || _closed) {
      return;
    }
    final nonce = cipher.newNonce();
    final sealed = await cipher.seal(nonce, plaintext);
    final record = Uint8List(lengthBytes + overheadBytes + plaintext.length);
    ByteData.sublistView(record).setUint32(
      0,
      PskCipher.nonceBytes + sealed.length,
      Endian.big,
    );
    record.setRange(lengthBytes, lengthBytes + PskCipher.nonceBytes, nonce);
    record.setRange(lengthBytes + PskCipher.nonceBytes, record.length, sealed);
    _inner.send(record);
  }

  Future<void> _pump() async {
    final cipher = _cipher;
    if (cipher == null) {
      return;
    }
    final buffer = _RecordBuffer();
    try {
      await for (final chunk in _inner.incoming) {
        buffer.add(chunk);
        while (true) {
          final record = buffer.tryTake();
          if (record == null) {
            break;
          }
          final clear = await cipher.open(record.nonce, record.sealed);
          if (_plaintext.isClosed || _closed) {
            return;
          }
          _plaintext.add(clear);
        }
      }
      await _closePlaintext();
    } catch (error, stackTrace) {
      _failChannel(error, stackTrace);
      await _safeCloseInner();
    }
  }

  void _failChannel(Object error, StackTrace stackTrace) {
    if (_closed) {
      return;
    }
    _closed = true;
    if (!_plaintext.isClosed) {
      _plaintext.addError(error, stackTrace);
      unawaited(_plaintext.close());
    }
    unawaited(_safeCloseInner());
  }

  Future<void> _safeCloseInner() async {
    try {
      await _inner.close();
    } catch (_) {
      // The peer is already gone.
    }
  }

  Future<void> _closePlaintext() async {
    if (!_plaintext.isClosed) {
      await _plaintext.close();
    }
  }

  @override
  Future<void> close() async {
    if (_closed && _passthrough) {
      return;
    }
    _closed = true;
    if (_passthrough) {
      await _safeCloseInner();
      return;
    }
    try {
      await _sendQueue;
    } catch (_) {
      // Already reported through _failChannel.
    }
    await _safeCloseInner();
    await _closePlaintext();
  }
}

class _Record {
  const _Record(this.nonce, this.sealed);

  final Uint8List nonce;
  final Uint8List sealed;
}

/// Splits a byte stream into length-prefixed records.
class _RecordBuffer {
  Uint8List _data = Uint8List(0);
  int _start = 0;

  int get _available => _data.length - _start;

  void add(Uint8List chunk) {
    if (chunk.isEmpty) {
      return;
    }
    final next = Uint8List(_available + chunk.length);
    next.setRange(0, _available, _data, _start);
    next.setRange(_available, next.length, chunk);
    _data = next;
    _start = 0;
  }

  /// Returns null when more bytes are needed.
  _Record? tryTake() {
    if (_available < SecureChannel.lengthBytes) {
      return null;
    }
    final length = ByteData.sublistView(
      _data,
      _start,
      _start + SecureChannel.lengthBytes,
    ).getUint32(0, Endian.big);

    final maxLength = SecureChannel.maxRecordBytes + SecureChannel.overheadBytes;
    if (length < PskCipher.nonceBytes + PskCipher.tagBytes ||
        length > maxLength) {
      throw PskException(
        'Invalid record length $length (expected ${PskCipher.nonceBytes + PskCipher.tagBytes}'
        '..$maxLength).',
      );
    }
    final total = SecureChannel.lengthBytes + length;
    if (_available < total) {
      return null;
    }
    final nonceStart = _start + SecureChannel.lengthBytes;
    final sealedStart = nonceStart + PskCipher.nonceBytes;
    final record = _Record(
      Uint8List.fromList(
        Uint8List.sublistView(_data, nonceStart, sealedStart),
      ),
      Uint8List.fromList(
        Uint8List.sublistView(_data, sealedStart, _start + total),
      ),
    );
    _start += total;
    if (_start == _data.length) {
      _data = Uint8List(0);
      _start = 0;
    }
    return record;
  }
}
