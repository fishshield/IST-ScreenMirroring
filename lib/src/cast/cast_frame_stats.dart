import 'package:flutter/foundation.dart';

/// One per-second sampling window of the decode → upload pipeline.
@immutable
class CastFrameStatsWindow {
  const CastFrameStatsWindow({
    required this.decoded,
    required this.uploaded,
    required this.dropped,
  });

  /// Frames handed to the sink during this window.
  final int decoded;

  /// Frames committed to a native staging texture during this window.
  final int uploaded;

  /// Frames skipped because the previous present was still in flight.
  final int dropped;

  @override
  String toString() =>
      'decoded=$decoded uploaded=$uploaded dropped=$dropped';
}

/// Cumulative counters plus the sampling window used for the once-per-second
/// debug log.
///
/// Kept separate from the UI state so the numbers can be unit-tested without a
/// widget tree or a native presenter.
class CastFrameStats {
  int _decoded = 0;
  int _uploaded = 0;
  int _dropped = 0;
  int _unavailable = 0;
  int _failed = 0;

  int _decodedAtSample = 0;
  int _uploadedAtSample = 0;
  int _droppedAtSample = 0;

  int get decoded => _decoded;

  int get uploaded => _uploaded;

  int get dropped => _dropped;

  /// Frames that had no native presenter (non-Windows, GDI fallback).
  int get unavailable => _unavailable;

  /// Frames whose upload threw.
  int get failed => _failed;

  void recordDecoded() => _decoded++;

  void recordUploaded() => _uploaded++;

  void recordDropped() => _dropped++;

  void recordUnavailable() => _unavailable++;

  void recordFailed() => _failed++;

  /// Deltas since the previous call; starts a new sampling window.
  CastFrameStatsWindow sampleWindow() {
    final window = CastFrameStatsWindow(
      decoded: _decoded - _decodedAtSample,
      uploaded: _uploaded - _uploadedAtSample,
      dropped: _dropped - _droppedAtSample,
    );
    _decodedAtSample = _decoded;
    _uploadedAtSample = _uploaded;
    _droppedAtSample = _dropped;
    return window;
  }

  void reset() {
    _decoded = 0;
    _uploaded = 0;
    _dropped = 0;
    _unavailable = 0;
    _failed = 0;
    _decodedAtSample = 0;
    _uploadedAtSample = 0;
    _droppedAtSample = 0;
  }

  @override
  String toString() => 'CastFrameStats(decoded: $_decoded, '
      'uploaded: $_uploaded, dropped: $_dropped, '
      'unavailable: $_unavailable, failed: $_failed)';
}
