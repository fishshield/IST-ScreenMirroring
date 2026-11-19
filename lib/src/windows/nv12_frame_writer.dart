import 'dart:typed_data';

import '../ffmpeg/decoded_frame.dart';

/// Writes a decoded YUV420p frame as NV12 directly into native-mapped memory.
///
/// The destination is the CPU view of a D3D11 staging texture. The Y plane is
/// copied row-by-row and the U/V planes are interleaved in the same pass, so
/// the decoded frame crosses the Dart/native boundary exactly once. There is
/// intentionally no intermediate `Uint8List` copy and no MethodChannel payload
/// containing pixel bytes.
///
/// NV12 layout used by the D3D11 upload texture:
///
///     [ Y: height rows, rowPitch bytes each ]
///     [ UV: height/2 rows, rowPitch bytes each, U/V interleaved ]
class Nv12FrameWriter {
  const Nv12FrameWriter._();

  /// Number of bytes required for [width] x [height] NV12 with [rowPitch].
  static int requiredBytes({
    required int width,
    required int height,
    required int rowPitch,
  }) {
    _checkLayout(width: width, height: height, rowPitch: rowPitch);
    return rowPitch * (height + (height >> 1));
  }

  /// Copies [frame] into [destination] without allocating an intermediate
  /// plane buffer. [destination] must be a view over the native mapped memory
  /// and at least [requiredBytes] long.
  ///
  /// [left]/[top]/[width]/[height] select the sub-rectangle to write; the
  /// caller uses it to crop the encoder's letterbox bars. All four are in
  /// pixels of the decoded frame and must be even (NV12 chroma alignment).
  static void write({
    required Uint8List destination,
    required int rowPitch,
    required DecodedFrame frame,
    int left = 0,
    int top = 0,
    int? width,
    int? height,
  }) {
    if (!frame.isYuv420p) {
      throw ArgumentError.value(
        frame.pixelFormat,
        'frame.pixelFormat',
        'Only YUV420p frames can be written as NV12.',
      );
    }
    final cropWidth = width ?? frame.width;
    final cropHeight = height ?? frame.height;
    if (left < 0 ||
        top < 0 ||
        left + cropWidth > frame.width ||
        top + cropHeight > frame.height ||
        (left & 1) != 0 ||
        (top & 1) != 0) {
      throw ArgumentError(
        'Invalid NV12 crop: left=$left top=$top '
        '${cropWidth}x$cropHeight inside ${frame.width}x${frame.height}.',
      );
    }
    _checkLayout(
      width: cropWidth,
      height: cropHeight,
      rowPitch: rowPitch,
    );

    final chromaWidth = cropWidth >> 1;
    final chromaHeight = cropHeight >> 1;
    final needed = requiredBytes(
      width: cropWidth,
      height: cropHeight,
      rowPitch: rowPitch,
    );
    if (destination.length < needed) {
      throw RangeError(
        'NV12 destination is ${destination.length} bytes, needs $needed.',
      );
    }
    if (frame.y.length < frame.yStride * frame.height ||
        frame.u.length < frame.uStride * (frame.height >> 1) ||
        frame.v.length < frame.vStride * (frame.height >> 1)) {
      throw RangeError('Decoded YUV420p plane dimensions are inconsistent.');
    }

    // Y plane is a straight row copy, using the native row pitch rather than
    // the FFmpeg stride.
    for (var row = 0; row < cropHeight; row++) {
      final sourceOffset = (top + row) * frame.yStride + left;
      final destinationOffset = row * rowPitch;
      destination.setRange(
        destinationOffset,
        destinationOffset + cropWidth,
        frame.y,
        sourceOffset,
      );
    }

    // Interleave U and V while copying into the NV12 UV plane.
    final uvBase = rowPitch * cropHeight;
    final chromaLeft = left >> 1;
    final chromaTop = top >> 1;
    for (var row = 0; row < chromaHeight; row++) {
      var destinationOffset = uvBase + row * rowPitch;
      final uOffset = (chromaTop + row) * frame.uStride + chromaLeft;
      final vOffset = (chromaTop + row) * frame.vStride + chromaLeft;
      for (var column = 0; column < chromaWidth; column++) {
        destination[destinationOffset++] = frame.u[uOffset + column];
        destination[destinationOffset++] = frame.v[vOffset + column];
      }
    }
  }

  static void _checkLayout({
    required int width,
    required int height,
    required int rowPitch,
  }) {
    if (width <= 0 || height <= 0 || (width & 1) != 0 || (height & 1) != 0) {
      throw ArgumentError(
        'NV12 requires positive even dimensions, got ${width}x$height.',
      );
    }
    if (rowPitch < width || (rowPitch & 1) != 0) {
      throw ArgumentError.value(
        rowPitch,
        'rowPitch',
        'Must be at least the width and even.',
      );
    }
  }
}
