import 'package:flutter/foundation.dart';

/// Control-channel message types.
///
/// These values are part of the wire protocol shared with
/// `android-server/.../ControlProtocol.java`; the video stream keeps using the
/// untouched SCRC protocol on port 27183, this channel lives on 27184.
enum ControlMessageType {
  /// Touch down at a normalized position.
  touchDown(0x01),

  /// Touch move at a normalized position.
  touchMove(0x02),

  /// Touch up at a normalized position.
  touchUp(0x03),

  /// Vertical wheel scroll; payload is the raw signed int32 Windows wheel
  /// delta (`WM_MOUSEWHEEL` / `GET_WHEEL_DELTA_WPARAM`, multiples of 120,
  /// positive = wheel rotated away from the user).
  wheel(0x04),

  /// Key down; payload is an Android KeyEvent keycode.
  keyDown(0x05),

  /// Key up; payload is an Android KeyEvent keycode.
  keyUp(0x06);

  const ControlMessageType(this.code);

  /// Wire value: the single type byte at the start of the frame.
  final int code;

  bool get isTouch =>
      this == ControlMessageType.touchDown ||
      this == ControlMessageType.touchMove ||
      this == ControlMessageType.touchUp;

  bool get isKey =>
      this == ControlMessageType.keyDown ||
      this == ControlMessageType.keyUp;

  static ControlMessageType? fromCode(int code) {
    for (final type in ControlMessageType.values) {
      if (type.code == code) {
        return type;
      }
    }
    return null;
  }
}

/// One control frame: `1 byte type | 4 byte big-endian payload length | payload`.
///
/// Payload layouts:
///   * touch: two IEEE-754 float32, big-endian, normalized 0.0-1.0 (x, y)
///   * wheel: one signed int32, big-endian: the raw Windows wheel delta
///     (positive = scroll up / away from the user). The Android server passes
///     it to `MotionEvent.AXIS_VSCROLL` unchanged; the identical sign was
///     verified on a real device.
///   * key:   one signed int32, big-endian, Android KeyEvent keycode
@immutable
class ControlMessage {
  const ControlMessage._(this.type, this.payload);

  /// 1 byte type + 4 bytes big-endian length.
  static const int headerBytes = 5;

  /// Defensive cap; Android rejects anything larger.
  static const int maxPayloadBytes = 64;

  static const int touchPayloadBytes = 8;
  static const int wheelPayloadBytes = 4;
  static const int keyPayloadBytes = 4;

  final ControlMessageType type;
  final Uint8List payload;

  factory ControlMessage.touch(
    ControlMessageType type,
    double normalizedX,
    double normalizedY,
  ) {
    if (!type.isTouch) {
      throw ArgumentError.value(type, 'type', 'Expected a touch message type.');
    }
    final data = ByteData(touchPayloadBytes)
      ..setFloat32(0, normalizedX.clamp(0.0, 1.0), Endian.big)
      ..setFloat32(4, normalizedY.clamp(0.0, 1.0), Endian.big);
    return ControlMessage._(type, data.buffer.asUint8List());
  }

  factory ControlMessage.key(ControlMessageType type, int keyCode) {
    if (!type.isKey) {
      throw ArgumentError.value(type, 'type', 'Expected a key message type.');
    }
    final data = ByteData(keyPayloadBytes)..setInt32(0, keyCode, Endian.big);
    return ControlMessage._(type, data.buffer.asUint8List());
  }

  /// [windowsDelta] is the raw `GET_WHEEL_DELTA_WPARAM` value from
  /// `WM_MOUSEWHEEL`; it is sent unchanged so the server can apply the single
  /// sign flip required by `AXIS_VSCROLL`.
  factory ControlMessage.wheel(int windowsDelta) {
    final data = ByteData(wheelPayloadBytes)
      ..setInt32(0, windowsDelta, Endian.big);
    return ControlMessage._(ControlMessageType.wheel, data.buffer.asUint8List());
  }

  /// Serializes the frame for the socket.
  Uint8List encode() {
    final bytes = Uint8List(headerBytes + payload.length);
    final data = ByteData.view(bytes.buffer);
    data.setUint8(0, type.code);
    data.setInt32(1, payload.length, Endian.big);
    bytes.setRange(headerBytes, bytes.length, payload);
    return bytes;
  }

  /// Decodes one complete frame. Used by tests and by the Windows-side
  /// diagnostics; the Android server decodes the same layout in Java.
  factory ControlMessage.decode(Uint8List bytes) {
    if (bytes.length < headerBytes) {
      throw const FormatException('Control frame is shorter than its header.');
    }
    final data = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
    final typeCode = data.getUint8(0);
    final type = ControlMessageType.fromCode(typeCode);
    if (type == null) {
      throw FormatException('Unknown control message type 0x'
          '${typeCode.toRadixString(16)}.');
    }
    final length = data.getInt32(1, Endian.big);
    if (length < 0 || length > maxPayloadBytes) {
      throw FormatException('Invalid control payload length $length.');
    }
    if (bytes.length < headerBytes + length) {
      throw const FormatException('Control frame payload is truncated.');
    }
    return ControlMessage._(
      type,
      Uint8List.fromList(
        bytes.sublist(headerBytes, headerBytes + length),
      ),
    );
  }

  double get normalizedX {
    _requirePayload(touchPayloadBytes, 'touch');
    return ByteData.sublistView(payload).getFloat32(0, Endian.big);
  }

  double get normalizedY {
    _requirePayload(touchPayloadBytes, 'touch');
    return ByteData.sublistView(payload).getFloat32(4, Endian.big);
  }

  int get intPayload {
    if (payload.length < 4) {
      throw StateError('${type.name} payload must be 4 bytes, '
          'got ${payload.length}.');
    }
    return ByteData.sublistView(payload).getInt32(0, Endian.big);
  }

  void _requirePayload(int expected, String kind) {
    if (!type.isTouch || payload.length != expected) {
      throw StateError('$kind payload mismatch for ${type.name}: '
          '${payload.length} bytes.');
    }
  }

  @override
  String toString() {
    return 'ControlMessage(${type.name}, ${payload.length} bytes)';
  }
}
