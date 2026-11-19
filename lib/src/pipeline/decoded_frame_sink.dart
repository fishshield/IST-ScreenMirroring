import '../ffmpeg/decoded_frame.dart';

/// What happened to a decoded frame on its way to the native presenter.
enum FrameUploadStatus {
  /// Copied into a staging texture and handed to the native presenter.
  ///
  /// The present itself is asynchronous: the upload call returns as soon as the
  /// bytes are in native memory.
  uploaded,

  /// Skipped on purpose because the previous present had not completed yet.
  ///
  /// Dropping is preferred over queueing: a queued frame would only add latency
  /// and would still be displayed long after it was captured.
  dropped,

  /// No native presenter is available (non-Windows host, GDI fallback, overlay
  /// not created/embedded yet). This is not an error.
  unavailable,
}

/// Destination for frames after FFmpeg has decoded them.
///
/// A frame is only reported as [FrameUploadStatus.uploaded] when its bytes were
/// written into a native upload texture. Throwing means the presenter failed
/// while copying the frame.
abstract interface class DecodedFrameSink {
  Future<FrameUploadStatus> presentFrame(DecodedFrame frame);
}
