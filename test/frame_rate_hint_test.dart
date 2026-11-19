import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/cast/frame_rate_hint.dart';

void main() {
  test('shows the hint when presentation lags by more than 20%', () {
    expect(
      shouldShowFrameRateHint(decodeFps: 120, presentFps: 60),
      isTrue,
    );
    expect(
      shouldShowFrameRateHint(decodeFps: 120, presentFps: 96),
      isFalse,
      reason: 'exactly 20% is still acceptable',
    );
    expect(
      shouldShowFrameRateHint(decodeFps: 60, presentFps: 59),
      isFalse,
    );
  });

  test('never shows the hint without a present sample', () {
    expect(shouldShowFrameRateHint(decodeFps: 120, presentFps: 0), isFalse);
    expect(shouldShowFrameRateHint(decodeFps: 0, presentFps: 0), isFalse);
  });

  test('ignores the warm-up samples right after start', () {
    expect(shouldShowFrameRateHint(decodeFps: 5, presentFps: 1), isFalse);
  });

  test('summary and hint text match the UI contract', () {
    expect(frameRateSummary(decodeFps: 120, presentFps: 60),
        '解码 120fps · 呈现 60fps');
    expect(frameRateHintText, contains('限制 60 帧'));
  });
}
