/// Why the letterbox rect is being measured.
///
/// Probing is trigger driven; the enum is only used for the log line
/// `[content] probe: reason=... rect=...`.
enum ContentProbeReason {
  /// First decoded frame of the session.
  initial('initial'),

  /// The native video window finished an interactive resize.
  resize('resize'),

  /// The decoded frame dimensions changed (encoder reconfiguration).
  sizeChange('size-change'),

  /// Safety sweep when no trigger arrived for a long time.
  timer('timer');

  const ContentProbeReason(this.logName);

  final String logName;
}

/// Content rect of the mirrored phone screen inside a decoded video frame.
///
/// The Android capture mirrors the device into the encoder's 1280x720 surface,
/// and SurfaceFlinger keeps the device aspect ratio, so the encoded frame
/// carries black bars on the left/right. Presenting the whole frame therefore
/// shows two black pillars. [detectFrameContentRect] finds those bars and is
/// re-run periodically (see `FfmpegDecoder`) so a rotation re-fits the window;
/// the renderer crops them and the window matches the phone's aspect ratio.
class FrameContentRect {
  const FrameContentRect({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
  });

  /// Normalized coordinates in the decoded frame (0.0 - 1.0).
  final double left;
  final double top;
  final double width;
  final double height;

  static const FrameContentRect full = FrameContentRect(
    left: 0,
    top: 0,
    width: 1,
    height: 1,
  );

  bool get isFull =>
      left == 0 && top == 0 && width == 1 && height == 1;

  /// Width/height ratio of the cropped content in *pixels* of the frame.
  double aspectFor(int frameWidth, int frameHeight) {
    final contentWidth = width * frameWidth;
    final contentHeight = height * frameHeight;
    if (contentWidth <= 0 || contentHeight <= 0) {
      return frameHeight == 0 ? 1 : frameWidth / frameHeight;
    }
    return contentWidth / contentHeight;
  }

  @override
  String toString() =>
      'FrameContentRect(${left.toStringAsFixed(3)}, ${top.toStringAsFixed(3)}, '
      '${width.toStringAsFixed(3)}x${height.toStringAsFixed(3)})';

  @override
  bool operator ==(Object other) =>
      other is FrameContentRect &&
      other.left == left &&
      other.top == top &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(left, top, width, height);
}

/// Detects the letterbox bars around the mirrored screen.
///
/// Handles both orientations: the encoder can pad the content on the left/right
/// (portrait device inside a 16:9 frame) or on the top/bottom (landscape device
/// inside a 16:9 frame). Returns null when the frame has no bars (or when they
/// are too small / asymmetric to be trusted), in which case the presenter keeps
/// the full frame.
FrameContentRect? detectFrameContentRect({
  required List<int> y,
  required int stride,
  required int width,
  required int height,
  int blackThreshold = 32,
}) {
  if (width < 8 || height < 8 || stride < width || y.length < stride * height) {
    return null;
  }

  final rowStep = (height ~/ 32).clamp(1, height);
  final columnStep = (width ~/ 32).clamp(1, width);

  bool columnIsBlack(int x) {
    for (var row = 0; row < height; row += rowStep) {
      if (y[row * stride + x] > blackThreshold) {
        return false;
      }
    }
    return true;
  }

  bool rowIsBlack(int row) {
    final offset = row * stride;
    for (var column = 0; column < width; column += columnStep) {
      if (y[offset + column] > blackThreshold) {
        return false;
      }
    }
    return true;
  }

  final leftBar = _leadingRun(width, columnIsBlack);
  if (leftBar == null) {
    return null;
  }
  final rightBar = _trailingRun(width, columnIsBlack);
  if (rightBar == null) {
    return null;
  }
  final topBar = _leadingRun(height, rowIsBlack);
  final bottomBar = topBar == null ? null : _trailingRun(height, rowIsBlack);

  // A real letterbox is symmetric; asymmetric dark edges are more likely part
  // of the phone UI (dark wallpaper, black status bar) and must not be cropped.
  final horizontalTolerance = (width * 0.02).ceil().clamp(2, width);
  final verticalTolerance = (height * 0.02).ceil().clamp(2, height);

  var x = 0;
  var cropWidth = width;
  if (leftBar >= 2 || rightBar >= 2) {
    if (leftBar < 2 ||
        rightBar < 2 ||
        (leftBar - rightBar).abs() > horizontalTolerance ||
        leftBar + rightBar >= width * 0.9) {
      return null;
    }
    x = leftBar;
    cropWidth = width - leftBar - rightBar;
  }

  var yOffset = 0;
  var cropHeight = height;
  if (topBar != null && bottomBar != null) {
    if (topBar >= 2 || bottomBar >= 2) {
      if (topBar < 2 ||
          bottomBar < 2 ||
          (topBar - bottomBar).abs() > verticalTolerance ||
          topBar + bottomBar >= height * 0.9) {
        return null;
      }
      yOffset = topBar;
      cropHeight = height - topBar - bottomBar;
    }
  }

  if (cropWidth == width && cropHeight == height) {
    return null;
  }

  return FrameContentRect(
    left: x / width,
    top: yOffset / height,
    width: cropWidth / width,
    height: cropHeight / height,
  );
}

/// Length of the leading black run from the start of [extent], or null when
/// there is no run at all (empty content).
int? _leadingRun(int extent, bool Function(int index) isBlack) {
  for (var index = 0; index < extent; index++) {
    if (!isBlack(index)) {
      return index;
    }
  }
  return null;
}

/// Length of the trailing black run from the end of [extent].
int? _trailingRun(int extent, bool Function(int index) isBlack) {
  for (var index = 0; index < extent; index++) {
    if (!isBlack(extent - 1 - index)) {
      return index;
    }
  }
  return null;
}
