import 'dart:typed_data';

import '../ffmpeg/decoded_frame.dart';
import 'nv12_frame_writer.dart';

/// One side of the NV12 double buffer: a mapped staging texture.
///
/// [pointer] and [destination] come from the native side and are replaced after
/// every `presentFrame`, because a D3D11 staging texture receives a fresh CPU
/// mapping when it is remapped.
class Nv12UploadTarget {
  Nv12UploadTarget({
    required this.index,
    required this.pointer,
    required this.rowPitch,
    required this.width,
    required this.height,
    required Uint8List destination,
  }) : _destination = destination;

  /// Native texture slot, 0 or 1.
  final int index;

  int pointer;
  int rowPitch;
  final int width;
  final int height;

  Uint8List _destination;

  /// CPU view over the mapped staging texture.
  Uint8List get destination => _destination;

  int get byteCount => Nv12FrameWriter.requiredBytes(
        width: width,
        height: height,
        rowPitch: rowPitch,
      );

  bool get isMapped =>
      pointer != 0 && rowPitch >= width && _destination.length >= byteCount;

  /// Applies the remapped pointer returned by `presentFrame`.
  void rebind({
    required int pointer,
    required int rowPitch,
    required Uint8List destination,
  }) {
    this.pointer = pointer;
    this.rowPitch = rowPitch;
    _destination = destination;
  }

  @override
  String toString() => 'Nv12UploadTarget(index: $index, ${width}x$height, '
      'pitch: $rowPitch, pointer: $pointer)';
}

/// Double-buffered NV12 upload into two native staging textures.
///
/// Writes alternate between the two targets, and a target that is currently
/// being presented is never written: the native side unmaps/remaps that texture
/// during the present, so the other texture is used instead. That makes writing
/// and presenting contention-free, and keeps the decode loop from waiting for a
/// present.
///
/// A frame is dropped — never queued — when the target the rotation picked is
/// still in flight, or when both textures are busy. In practice that only
/// happens when the source produces frames faster than the desktop can present
/// them, which is exactly the frame budget worth dropping.
class Nv12DoubleBuffer {
  Nv12DoubleBuffer({required List<Nv12UploadTarget> targets})
      : assert(targets.length == targetCount, 'needs exactly two targets'),
        assert(
          targets.every(
            (Nv12UploadTarget target) =>
                target.width == targets.first.width &&
                target.height == targets.first.height,
          ),
          'both targets must share the frame size',
        ),
        _targets = List<Nv12UploadTarget>.of(targets);

  /// Number of staging textures rotated by this buffer.
  static const int targetCount = 2;

  final List<Nv12UploadTarget> _targets;
  int _nextIndex = 0;
  final Set<int> _inFlight = <int>{};
  int _presentedCount = 0;
  int _droppedCount = 0;

  int get width => _targets.first.width;

  int get height => _targets.first.height;

  /// The target the next [write] will use.
  Nv12UploadTarget get nextTarget => _targets[_nextIndex];

  int get nextIndex => _nextIndex;

  /// Index currently being presented, or null when nothing is in flight.
  int? get pendingIndex => _inFlight.isEmpty ? null : _inFlight.first;

  bool get presentInFlight => _inFlight.isNotEmpty;

  /// Number of textures whose `presentFrame` has not returned yet (0..2).
  int get inFlightCount => _inFlight.length;

  bool isInFlight(int index) => _inFlight.contains(index);

  int get presentedCount => _presentedCount;

  int get droppedCount => _droppedCount;

  List<Nv12UploadTarget> get targets => List<Nv12UploadTarget>.unmodifiable(
        _targets,
      );

  bool matches(int width, int height) =>
      this.width == width && this.height == height;

  /// Writes [frame] into the next staging texture.
  ///
  /// [left]/[top]/[width]/[height] select the sub-rectangle written into the
  /// (already cropped) staging texture; see `Nv12FrameWriter.write`.
  ///
  /// Returns the target that now holds the frame, or `null` when the frame was
  /// dropped because that texture is still being presented.
  Nv12UploadTarget? write(
    DecodedFrame frame, {
    int left = 0,
    int top = 0,
    int? width,
    int? height,
  }) {
    final cropWidth = width ?? frame.width;
    final cropHeight = height ?? frame.height;
    if (!matches(cropWidth, cropHeight)) {
      throw StateError(
        'NV12 buffer is configured for $this.width x $this.height, '
        'frame is $cropWidth x $cropHeight.',
      );
    }
    if (_inFlight.contains(_nextIndex)) {
      // That texture is still being unampped/remapped natively: skipping this
      // frame is the whole point of the drop policy, do not wait for it.
      _droppedCount++;
      return null;
    }
    final target = _targets[_nextIndex];
    if (!target.isMapped) {
      throw StateError('NV12 upload target ${target.index} is not mapped.');
    }
    Nv12FrameWriter.write(
      destination: target.destination,
      rowPitch: target.rowPitch,
      frame: frame,
      left: left,
      top: top,
      width: cropWidth,
      height: cropHeight,
    );
    _nextIndex = (_nextIndex + 1) % targetCount;
    return target;
  }

  /// Marks [index] as being presented; its mapping is invalid until
  /// [completePresent] or [failPresent].
  void beginPresent(int index) {
    RangeError.checkValidIndex(index, _targets, 'index');
    if (!_inFlight.add(index)) {
      throw StateError('NV12 target $index is already being presented.');
    }
  }

  /// Applies the mapping returned by a successful `presentFrame`.
  void completePresent(
    int index, {
    required int pointer,
    required int rowPitch,
    required Uint8List destination,
  }) {
    RangeError.checkValidIndex(index, _targets, 'index');
    _targets[index].rebind(
      pointer: pointer,
      rowPitch: rowPitch,
      destination: destination,
    );
    _inFlight.remove(index);
    _presentedCount++;
  }

  /// The present failed: the target's mapping is unknown and has to be
  /// re-established by a fresh `configureFrame` before it is written again.
  void failPresent(int index) {
    RangeError.checkValidIndex(index, _targets, 'index');
    _inFlight.remove(index);
  }

  @override
  String toString() => 'Nv12DoubleBuffer(${width}x$height, '
      'next: $_nextIndex, inFlight: ${_inFlight.toList()..sort()}, '
      'presented: $_presentedCount, dropped: $_droppedCount)';
}
