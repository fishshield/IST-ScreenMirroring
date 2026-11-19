import 'dart:typed_data';

import 'frame_content_rect.dart';

/// A decoded frame handed to the presenter.
///
/// Two variants exist:
///  * software (default): YUV420p planes copied out of FFmpeg-owned memory,
///    written as NV12 through `Nv12FrameWriter`;
///  * hardware ([hardwarePresented]): a D3D11VA texture that the native side
///    already copied into the overlay with `CopySubresourceRegion`. Its planes
///    are empty on purpose — there is no CPU copy on that path.
class DecodedFrame {
  const DecodedFrame({
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.y,
    required this.u,
    required this.v,
    required this.yStride,
    required this.uStride,
    required this.vStride,
    this.contentRect,
  }) : hardwarePresented = false;

  /// A frame that was already presented from a D3D11 texture.
  ///
  /// No plane data is retained, so [isYuv420p] is false and the software upload
  /// path must not touch it.
  DecodedFrame.hardware({
    required this.width,
    required this.height,
    this.contentRect,
  })  : pixelFormat = 171, // AV_PIX_FMT_D3D11
        y = _empty,
        u = _empty,
        v = _empty,
        yStride = 0,
        uStride = 0,
        vStride = 0,
        hardwarePresented = true;

  static final Uint8List _empty = Uint8List(0);

  final int width;
  final int height;

  /// FFmpeg `AVPixelFormat`; 0 = yuv420p, 12 = yuvj420p, 171 = d3d11.
  final int pixelFormat;

  final Uint8List y;
  final Uint8List u;
  final Uint8List v;

  final int yStride;
  final int uStride;
  final int vStride;

  /// True when the frame travelled the D3D11VA path and is already on screen.
  final bool hardwarePresented;

  /// Sub-rect of the frame that holds the mirrored screen, once detected.
  ///
  /// The encoder letterboxes the phone into the 16:9 frame; the renderer crops
  /// to this rect so no black pillars are shown.
  final FrameContentRect? contentRect;

  bool get isYuv420p => pixelFormat == 0 || pixelFormat == 12;

  @override
  String toString() => hardwarePresented
      ? 'DecodedFrame(${width}x$height, d3d11va)'
      : 'DecodedFrame(${width}x$height, format=$pixelFormat)';
}
