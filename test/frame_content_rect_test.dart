import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/ffmpeg/frame_content_rect.dart';

/// Builds a Y plane with `leftBar`/`rightBar` columns of black pixels around a
/// bright content area, mimicking the encoder's letterboxed output.
Uint8List _frame({
  required int width,
  required int height,
  required int leftBar,
  required int rightBar,
  int background = 200,
  int bar = 0,
}) {
  final stride = width;
  final y = Uint8List(stride * height);
  for (var row = 0; row < height; row++) {
    for (var column = 0; column < width; column++) {
      final inBar = column < leftBar || column >= width - rightBar;
      y[row * stride + column] = inBar ? bar : background;
    }
  }
  return y;
}

void main() {
  test('detects symmetric letterbox bars and crops to the content rect', () {
    const width = 1280;
    const height = 720;
    final y = _frame(width: width, height: height, leftBar: 383, rightBar: 383);

    final rect = detectFrameContentRect(
      y: y,
      stride: width,
      width: width,
      height: height,
    );

    expect(rect, isNotNull);
    expect(rect!.left, closeTo(383 / 1280, 1e-9));
    expect(rect.top, 0);
    expect(rect.width, closeTo(514 / 1280, 1e-9));
    expect(rect.height, 1);
    expect(rect.aspectFor(width, height), closeTo(514 / 720, 1e-6));
  });

  test('returns null when the frame has no bars', () {
    const width = 640;
    const height = 360;
    final y = _frame(width: width, height: height, leftBar: 0, rightBar: 0);

    expect(
      detectFrameContentRect(y: y, stride: width, width: width, height: height),
      isNull,
    );
  });

  test('ignores asymmetric dark edges (phone UI, not letterbox)', () {
    const width = 640;
    const height = 360;
    final y = _frame(width: width, height: height, leftBar: 120, rightBar: 4);

    expect(
      detectFrameContentRect(y: y, stride: width, width: width, height: height),
      isNull,
    );
  });

  test('rejects undersized or inconsistent buffers', () {
    expect(
      detectFrameContentRect(
        y: Uint8List(10),
        stride: 10,
        width: 4,
        height: 4,
      ),
      isNull,
    );
    expect(
      detectFrameContentRect(
        y: Uint8List(10),
        stride: 4,
        width: 8,
        height: 8,
      ),
      isNull,
    );
  });
}
