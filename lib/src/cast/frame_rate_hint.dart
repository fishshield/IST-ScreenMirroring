/// Frame-rate presentation helpers shared by the control panel and tests.
library;

/// Decode rate below which the hint is not shown: the first samples after a
/// session starts are not representative.
const int kFrameRateHintMinDecodeFps = 10;

/// The hint appears when presentation lags decoding by more than 20%.
const double kFrameRateHintThreshold = 0.2;

/// True when the decoder is producing noticeably more frames than the window
/// actually presents (the source runs faster than the display/swap chain).
bool shouldShowFrameRateHint({
  required int decodeFps,
  required int presentFps,
}) {
  if (decodeFps < kFrameRateHintMinDecodeFps || presentFps <= 0) {
    return false;
  }
  return (decodeFps - presentFps) > decodeFps * kFrameRateHintThreshold;
}

/// `解码 120fps · 呈现 60fps`
String frameRateSummary({required int decodeFps, required int presentFps}) {
  return '解码 ${decodeFps}fps · 呈现 ${presentFps}fps';
}

/// Hint shown under the summary when the delta is significant.
const String frameRateHintText =
    '源帧率高于呈现能力，可开启“限制 60 帧”减少带宽和编码器负载';
