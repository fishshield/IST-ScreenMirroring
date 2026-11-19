import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/ffmpeg/decoded_frame.dart';
import 'package:screen_cast_demo/src/windows/nv12_frame_buffer.dart';

void main() {
  const int width = 4;
  const int height = 2;
  const int rowPitch = 4;
  const int byteCount = rowPitch * (height + height ~/ 2);

  Nv12UploadTarget target({
    required int index,
    required int pointer,
    Uint8List? destination,
  }) {
    return Nv12UploadTarget(
      index: index,
      pointer: pointer,
      rowPitch: rowPitch,
      width: width,
      height: height,
      destination: destination ?? Uint8List(byteCount),
    );
  }

  DecodedFrame frame({int luma = 0x10, int chromaU = 0x80, int chromaV = 0x90}) {
    return DecodedFrame(
      width: width,
      height: height,
      pixelFormat: 0,
      y: Uint8List(width * height)..fillRange(0, width * height, luma),
      u: Uint8List(width >> 1)..fillRange(0, width >> 1, chromaU),
      v: Uint8List(width >> 1)..fillRange(0, width >> 1, chromaV),
      yStride: width,
      uStride: width >> 1,
      vStride: width >> 1,
    );
  }

  test('writes alternate between the two staging textures', () {
    final first = target(index: 0, pointer: 0x1000);
    final second = target(index: 1, pointer: 0x2000);
    final buffer = Nv12DoubleBuffer(targets: <Nv12UploadTarget>[first, second]);
    final decoded = frame();

    expect(buffer.write(decoded)!.index, 0);
    buffer.beginPresent(0);
    buffer.completePresent(
      0,
      pointer: 0x1100,
      rowPitch: rowPitch,
      destination: Uint8List(byteCount),
    );

    expect(buffer.write(decoded)!.index, 1);
    buffer.beginPresent(1);
    buffer.completePresent(
      1,
      pointer: 0x2100,
      rowPitch: rowPitch,
      destination: Uint8List(byteCount),
    );

    // Back to the first texture after the rotation.
    expect(buffer.write(decoded)!.index, 0);
    expect(buffer.presentedCount, 2);
    expect(buffer.droppedCount, 0);
  });

  test('drops a frame once both textures are being presented', () {
    final first = target(index: 0, pointer: 0x1000);
    final second = target(index: 1, pointer: 0x2000);
    final buffer = Nv12DoubleBuffer(targets: <Nv12UploadTarget>[first, second]);
    final decoded = frame();

    // First frame goes into texture 0 and starts presenting.
    expect(buffer.write(decoded)!.index, 0);
    buffer.beginPresent(0);
    expect(buffer.presentInFlight, isTrue);
    expect(buffer.pendingIndex, 0);

    // The second frame is pipelined into the other texture instead of waiting
    // for the first present: writing and presenting never share a texture.
    expect(buffer.write(decoded)!.index, 1);
    buffer.beginPresent(1);
    expect(buffer.inFlightCount, 2);

    // Only now, when both textures are busy, is the frame dropped (never queued).
    expect(buffer.write(decoded), isNull);
    expect(buffer.droppedCount, 1);
    expect(buffer.nextIndex, 0);

    buffer.completePresent(
      0,
      pointer: 0x1100,
      rowPitch: rowPitch,
      destination: Uint8List(byteCount),
    );
    expect(buffer.inFlightCount, 1);
    expect(buffer.write(decoded)!.index, 0);
    expect(buffer.presentedCount, 1);
    expect(buffer.droppedCount, 1);
  });

  test('a present in flight never blocks writing the other texture', () {
    final buffer = Nv12DoubleBuffer(
      targets: <Nv12UploadTarget>[
        target(index: 0, pointer: 0x1000),
        target(index: 1, pointer: 0x2000),
      ],
    );

    var written = 0;
    for (var attempt = 0; attempt < 2; attempt++) {
      final slot = buffer.write(frame());
      expect(slot, isNotNull, reason: 'attempt $attempt must not be dropped');
      buffer.beginPresent(slot!.index);
      written++;
    }
    expect(written, 2);
    expect(buffer.droppedCount, 0);
    expect(buffer.isInFlight(0), isTrue);
    expect(buffer.isInFlight(1), isTrue);
  });

  test('applies the remapped pointer and writes into the new mapping', () {
    final first = target(index: 0, pointer: 0x1000);
    final second = target(index: 1, pointer: 0x2000);
    final buffer = Nv12DoubleBuffer(targets: <Nv12UploadTarget>[first, second]);

    buffer.write(frame(luma: 0x11));
    buffer.beginPresent(0);

    // D3D11 hands out a fresh CPU mapping after Unmap -> CopyResource -> Map.
    final remapped = Uint8List(byteCount);
    buffer.completePresent(
      0,
      pointer: 0x7777,
      rowPitch: rowPitch,
      destination: remapped,
    );
    expect(first.pointer, 0x7777);
    expect(first.destination, same(remapped));

    // Alternate to the second target, then back to the remapped first one.
    buffer.write(frame());
    buffer.beginPresent(1);
    buffer.completePresent(
      1,
      pointer: 0x8888,
      rowPitch: rowPitch,
      destination: Uint8List(byteCount),
    );
    buffer.write(frame(luma: 0x22));

    expect(remapped[0], 0x22);
    expect(remapped[width], 0x22);
    // NV12 UV plane sits after the Y rows.
    expect(remapped[rowPitch * height], 0x80);
    expect(remapped[rowPitch * height + 1], 0x90);
  });

  test('a failed present clears its in-flight slot', () {
    final buffer = Nv12DoubleBuffer(
      targets: <Nv12UploadTarget>[
        target(index: 0, pointer: 0x1000),
        target(index: 1, pointer: 0x2000),
      ],
    );

    buffer.write(frame());
    buffer.beginPresent(0);
    buffer.write(frame());
    buffer.beginPresent(1);
    expect(buffer.write(frame()), isNull);

    buffer.failPresent(0);
    expect(buffer.isInFlight(0), isFalse);
    expect(buffer.inFlightCount, 1);
    expect(buffer.write(frame())!.index, 0);
    expect(buffer.droppedCount, 1);
  });

  test('rejects a frame whose size differs from the configured textures', () {
    final buffer = Nv12DoubleBuffer(
      targets: <Nv12UploadTarget>[
        target(index: 0, pointer: 0x1000),
        target(index: 1, pointer: 0x2000),
      ],
    );

    final wrongSize = DecodedFrame(
      width: 6,
      height: 2,
      pixelFormat: 0,
      y: Uint8List(12),
      u: Uint8List(3),
      v: Uint8List(3),
      yStride: 6,
      uStride: 3,
      vStride: 3,
    );
    expect(() => buffer.write(wrongSize), throwsStateError);
    expect(buffer.matches(width, height), isTrue);
    expect(buffer.matches(6, 2), isFalse);
  });

  test('refuses to present the same texture twice', () {
    final buffer = Nv12DoubleBuffer(
      targets: <Nv12UploadTarget>[
        target(index: 0, pointer: 0x1000),
        target(index: 1, pointer: 0x2000),
      ],
    );

    buffer.write(frame());
    buffer.beginPresent(0);
    expect(() => buffer.beginPresent(0), throwsStateError);
    // The other texture is allowed to present concurrently.
    buffer.beginPresent(1);
    expect(buffer.inFlightCount, 2);
    expect(() => buffer.failPresent(2), throwsRangeError);
  });

  test('an unmapped target is not written', () {
    final unmapped = Nv12UploadTarget(
      index: 0,
      pointer: 0,
      rowPitch: rowPitch,
      width: width,
      height: height,
      destination: Uint8List(byteCount),
    );
    final buffer = Nv12DoubleBuffer(
      targets: <Nv12UploadTarget>[
        unmapped,
        target(index: 1, pointer: 0x2000),
      ],
    );

    expect(() => buffer.write(frame()), throwsStateError);
  });
}
