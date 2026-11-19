import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/ffmpeg/decoded_frame.dart';
import 'package:screen_cast_demo/src/windows/nv12_frame_writer.dart';

void main() {
  test('writes Y and interleaved UV into NV12 with a padded row pitch', () {
    final destination = Uint8List(8 * 3);
    final frame = DecodedFrame(
      width: 4,
      height: 2,
      pixelFormat: 0,
      y: Uint8List.fromList([
        1, 2, 3, 4, 99, 99, // row 0, stride 6
        5, 6, 7, 8, 99, 99, // row 1
      ]),
      u: Uint8List.fromList([10, 20, 30, 40, 99, 99]),
      v: Uint8List.fromList([50, 60, 70, 80, 99, 99]),
      yStride: 6,
      uStride: 6,
      vStride: 6,
    );

    Nv12FrameWriter.write(
      destination: destination,
      rowPitch: 8,
      frame: frame,
    );

    expect(destination.sublist(0, 8), [1, 2, 3, 4, 0, 0, 0, 0]);
    expect(destination.sublist(8, 16), [5, 6, 7, 8, 0, 0, 0, 0]);
    expect(
      destination.sublist(16, 24),
      [10, 50, 20, 60, 0, 0, 0, 0],
    );
  });

  test('rejects odd dimensions and undersized destinations', () {
    final frame = DecodedFrame(
      width: 3,
      height: 2,
      pixelFormat: 0,
      y: Uint8List(6),
      u: Uint8List(3),
      v: Uint8List(3),
      yStride: 3,
      uStride: 2,
      vStride: 2,
    );

    expect(
      () => Nv12FrameWriter.write(
        destination: Uint8List(64),
        rowPitch: 4,
        frame: frame,
      ),
      throwsArgumentError,
    );

    final evenFrame = DecodedFrame(
      width: 4,
      height: 2,
      pixelFormat: 0,
      y: Uint8List(8),
      u: Uint8List(4),
      v: Uint8List(4),
      yStride: 4,
      uStride: 2,
      vStride: 2,
    );
    expect(
      () => Nv12FrameWriter.write(
        destination: Uint8List(8),
        rowPitch: 4,
        frame: evenFrame,
      ),
      throwsRangeError,
    );
  });
}
