import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';

import 'decoded_frame.dart';
import 'ffmpeg_abi.dart';
import 'ffmpeg_runtime.dart';
import 'frame_content_rect.dart';
import 'hardware_frame_bridge.dart';

/// Which path this decoder instance ended up on.
enum FfmpegDecodeBackend {
  /// Software H.264 decode + `Nv12FrameWriter` upload.
  software,

  /// D3D11VA decode; frames are copied GPU->GPU into the overlay.
  d3d11va,
}

/// Minimal H.264 decoder backed by FFmpeg's libavcodec through dart:ffi.
///
/// SCRC carries individual NAL units without Annex-B start codes. This wrapper
/// re-adds a 4-byte start code, prefixes the latest SPS/PPS, sends the packet
/// directly to avcodec, and either copies decoded YUV420p planes into
/// [DecodedFrame] (software) or lets the native overlay copy the D3D11 texture
/// (hardware).
///
/// The D3D11VA path reuses the overlay's `ID3D11Device` so the decoded texture
/// can be copied with `CopySubresourceRegion` without leaving the GPU. Every
/// hardware failure degrades to the software path; the two coexist.
class FfmpegDecoder {
  FfmpegDecoder._(this._libraries, this._bridge, this._preferHardware) {
    _open();
  }

  static const int avCodecIdH264 = 27;
  static const int _averrorEagain = -11;
  static const int _averrorEof = -541478725;

  /// Safety sweep for the content rect. A probe is *triggered* (first frame,
  /// frame-size change, video-window resize) rather than timed; this long
  /// interval only exists so a rotation that produces no trigger at all is
  /// eventually picked up. 60 s keeps `[content] probe` lines at ≤2 per minute.
  static const Duration contentProbeInterval = Duration(seconds: 60);

  final FfmpegLibraries _libraries;
  final HardwareFrameBridge? _bridge;
  final bool _preferHardware;

  FfmpegDecodeBackend _backend = FfmpegDecodeBackend.software;

  Pointer<Void> _codec = nullptr;
  Pointer<Void> _context = nullptr;
  Pointer<Void> _packet = nullptr;
  Pointer<_AVFrame> _frame = nullptr;

  /// Scratch software frame for the cross-device download fallback.
  Pointer<_AVFrame> _downloadFrame = nullptr;

  Uint8List? _sps;
  Uint8List? _pps;
  bool _closed = false;
  bool _loggedCrossDevice = false;
  bool _loggedCopyFailure = false;

  /// Detected from the frame (see [FrameContentRect]) and refreshed on
  /// triggers (first frame, size change, window resize) plus a slow safety
  /// sweep, so a device rotation re-fits the window.
  FrameContentRect? _contentRect;
  bool _contentRectDetected = false;
  DateTime _lastContentProbe = DateTime.fromMillisecondsSinceEpoch(0);
  ContentProbeReason? _pendingProbe;
  int _probedWidth = 0;
  int _probedHeight = 0;

  /// Asks for a content-rect probe on the next decoded frame.
  ///
  /// Used by the native video window when the user finishes resizing it: the
  /// visible content aspect may have changed even though the encoded frame did
  /// not.
  void requestContentProbe() {
    _pendingProbe = ContentProbeReason.resize;
  }

  /// Which path the decoder is actually using.
  FfmpegDecodeBackend get backend => _backend;

  static bool get isAvailable => FfmpegRuntime.findLibraryDirectory() != null;

  factory FfmpegDecoder.open({
    String? libraryDirectory,
    HardwareFrameBridge? bridge,
    bool preferHardware = true,
  }) {
    final libraries = FfmpegLibraries.open(
      libraryDirectory: libraryDirectory,
    );
    return FfmpegDecoder._(
      libraries,
      bridge ?? (preferHardware ? HardwareFrameBridge.tryOpen() : null),
      preferHardware,
    );
  }

  /// FFmpeg asks which pixel format to decode into. Only D3D11VA is accepted;
  /// returning [FfmpegAbi.pixFmtNone] makes FFmpeg reject hardware decoding,
  /// which is what triggers the software fallback in [_openHardware].
  static int _selectHardwareFormat(Pointer<Void> context, Pointer<Int32> formats) {
    if (formats == nullptr) {
      return FfmpegAbi.pixFmtNone;
    }
    for (var index = 0; index < 64; index++) {
      final format = formats[index];
      if (format == FfmpegAbi.pixFmtNone) {
        break;
      }
      if (format == FfmpegAbi.pixFmtD3d11) {
        return FfmpegAbi.pixFmtD3d11;
      }
    }
    return FfmpegAbi.pixFmtNone;
  }

  void _open() {
    _codec = _libraries.findDecoder(avCodecIdH264);
    if (_codec == nullptr) {
      throw const FfmpegException('FFmpeg H.264 decoder is not available.');
    }

    if (_preferHardware && _openHardware()) {
      _backend = FfmpegDecodeBackend.d3d11va;
      debugPrint('[hwaccel] D3D11VA decode enabled (shared device)');
    } else {
      if (_preferHardware) {
        debugPrint('[hwaccel] falling back to software decoding');
      }
      _backend = FfmpegDecodeBackend.software;
      _openSoftware();
    }

    _packet = _libraries.packetAlloc();
    _frame = _libraries.frameAlloc().cast<_AVFrame>();
    if (_packet == nullptr || _frame == nullptr) {
      throw const FfmpegException('FFmpeg packet/frame allocation failed.');
    }
  }

  void _openSoftware() {
    _context = _libraries.allocContext(_codec);
    if (_context == nullptr) {
      throw const FfmpegException('avcodec_alloc_context3 failed.');
    }
    final openResult = _libraries.openContext(_context, _codec, nullptr);
    if (openResult < 0) {
      throw FfmpegException('avcodec_open2 failed ($openResult).');
    }
  }

  /// Tries to open the decoder on the overlay's D3D11 device.
  ///
  /// Returns false (after logging why) when any step is unavailable, so the
  /// caller can open a plain software context instead.
  bool _openHardware() {
    final bridge = _bridge;
    if (bridge == null) {
      debugPrint(
        '[hwaccel] native bridge unavailable; '
        'using separate device, cross-device copy required '
        '(falling back to software decode)',
      );
      return false;
    }

    final handles = bridge.acquireDevice();
    if (handles == null) {
      debugPrint(
        '[hwaccel] using separate device, cross-device copy required '
        '(overlay device is not ready; falling back to software decode)',
      );
      return false;
    }

    final deviceCtx = _createSharedHwDevice(handles.device, handles.context);
    if (deviceCtx == nullptr) {
      bridge.releaseDevice(handles.device, handles.context);
      return false;
    }

    final context = _libraries.allocContext(_codec);
    if (context == nullptr) {
      _unrefBuffer(deviceCtx);
      return false;
    }
    if (!_abiMatches(context)) {
      debugPrint(
        '[hwaccel] FFmpeg ABI mismatch (AVCodecContext layout changed); '
        'using software decoding',
      );
      _freeContext(context);
      _unrefBuffer(deviceCtx);
      return false;
    }

    // get_format: only accept AV_PIX_FMT_D3D11. `fromFunction` needs the static
    // function itself, so it is referenced directly rather than through a
    // field.
    _writePointer(
      context,
      FfmpegAbi.offsetGetFormat,
      Pointer.fromFunction<Int32 Function(Pointer<Void>, Pointer<Int32>)>(
        _selectHardwareFormat,
        FfmpegAbi.pixFmtNone,
      ).cast<Void>(),
    );
    // hw_device_ctx: ownership of the reference moves to the codec context.
    _writePointer(context, FfmpegAbi.offsetHwDeviceCtx, deviceCtx);

    final openResult = _libraries.openContext(context, _codec, nullptr);
    if (openResult < 0) {
      debugPrint(
        '[hwaccel] avcodec_open2 with D3D11VA failed ($openResult); '
        'using software decoding',
      );
      // avcodec_free_context releases hw_device_ctx (and with it the device
      // references we handed over).
      _freeContext(context);
      return false;
    }

    _context = context;
    return true;
  }

  /// Builds an AVHWDeviceContext around the overlay's device, so FFmpeg never
  /// creates a second ID3D11Device.
  Pointer<Void> _createSharedHwDevice(int device, int context) {
    final ref = _libraries.hwDeviceCtxAlloc(FfmpegAbi.hwDeviceTypeD3d11va);
    if (ref == nullptr) {
      debugPrint('[hwaccel] av_hwdevice_ctx_alloc failed');
      return nullptr;
    }
    final data = _readPointer(ref, FfmpegAbi.offsetBufferData);
    if (data == nullptr) {
      _unrefBuffer(ref);
      return nullptr;
    }
    final hwctx = _readPointer(data, FfmpegAbi.offsetHwDeviceHwctx);
    if (hwctx == nullptr) {
      _unrefBuffer(ref);
      return nullptr;
    }
    // AVD3D11VADeviceContext takes ownership of both references; that is why
    // the bridge hands out AddRef'ed pointers.
    _writePointer(hwctx, FfmpegAbi.offsetD3d11vaDevice,
        Pointer<Void>.fromAddress(device));
    _writePointer(hwctx, FfmpegAbi.offsetD3d11vaDeviceContext,
        Pointer<Void>.fromAddress(context));

    final init = _libraries.hwDeviceCtxInit(ref);
    if (init < 0) {
      debugPrint('[hwaccel] av_hwdevice_ctx_init failed ($init)');
      // The device pointers were handed to the context; let its destructor
      // release them rather than releasing here as well.
      _unrefBuffer(ref);
      return nullptr;
    }
    return ref;
  }

  bool _abiMatches(Pointer<Void> context) {
    final codecId = (context.cast<Uint8>() + FfmpegAbi.offsetCodecId)
        .cast<Int32>()
        .value;
    return codecId == FfmpegAbi.codecIdH264;
  }

  Pointer<Void> _readPointer(Pointer<Void> base, int offset) {
    return (base.cast<Uint8>() + offset).cast<Pointer<Void>>().value;
  }

  void _writePointer(Pointer<Void> base, int offset, Pointer<Void> value) {
    (base.cast<Uint8>() + offset).cast<Pointer<Void>>().value = value;
  }

  void _unrefBuffer(Pointer<Void> ref) {
    final cell = calloc<Pointer<Void>>();
    try {
      cell.value = ref;
      _libraries.bufferUnref(cell);
    } finally {
      calloc.free(cell);
    }
  }

  void _freeContext(Pointer<Void> context) {
    _freePointer(context, _libraries.freeContext);
  }

  /// Feeds one SCRC NAL unit. The NAL must not include an Annex-B start code,
  /// matching the SCRC protocol contract.
  List<DecodedFrame> decode(Uint8List nalUnit) {
    _ensureOpen();
    if (nalUnit.isEmpty) {
      return const <DecodedFrame>[];
    }

    // Keep the latest parameter sets and re-insert them into each packet so
    // the SCRC stream does not depend on a separate codec-configuration frame.
    final nalType = nalUnit[0] & 0x1f;
    if (nalType == 7) {
      _sps = Uint8List.fromList(nalUnit);
    } else if (nalType == 8) {
      _pps = Uint8List.fromList(nalUnit);
    }

    // Only VCL NAL units (non-IDR slice 1, IDR slice 5) carry decodable frame
    // data. Parameter sets are cached above and re-inserted into every access
    // unit. Other NAL types are currently ignored by this minimal decoder.
    if (nalType != 1 && nalType != 5) {
      return const <DecodedFrame>[];
    }

    final hasStartCode = nalUnit.length >= 3 &&
        nalUnit[0] == 0 &&
        nalUnit[1] == 0 &&
        (nalUnit[2] == 1 ||
            (nalUnit.length >= 4 && nalUnit[2] == 0 && nalUnit[3] == 1));
    final prefixLength = hasStartCode ? 0 : 4;
    final byteCount = prefixLength + nalUnit.length;
    final input = calloc<Uint8>(byteCount + 64);
    try {
      final bytes = input.asTypedList(byteCount);
      if (prefixLength == 4) {
        bytes.setAll(0, const <int>[0, 0, 0, 1]);
      }
      bytes.setAll(prefixLength, nalUnit);
      return _sendEncoded(input, byteCount);
    } finally {
      calloc.free(input);
    }
  }

  /// Flushes delayed frames. Call only when the stream has ended; the decoder
  /// is not intended to decode more packets after this.
  List<DecodedFrame> flush() {
    _ensureOpen();

    final result = _libraries.sendPacket(_context, nullptr);
    if (result < 0 && result != _averrorEof && result != _averrorEagain) {
      throw FfmpegException('decoder flush failed ($result).');
    }
    return _receiveFrames();
  }

  List<DecodedFrame> _sendEncoded(Pointer<Uint8> data, int size) {
    if (size <= 0 || data == nullptr) {
      return const <DecodedFrame>[];
    }

    final parameterBytes = <int>[];
    if (_sps != null) {
      parameterBytes.addAll(const <int>[0, 0, 0, 1]);
      parameterBytes.addAll(_sps!);
    }
    if (_pps != null) {
      parameterBytes.addAll(const <int>[0, 0, 0, 1]);
      parameterBytes.addAll(_pps!);
    }

    final ranged = data.asTypedList(size);
    final packetSize = parameterBytes.length + size;
    final padded = _libraries.avMallocz(packetSize + 64);
    if (padded == nullptr) {
      throw const FfmpegException('av_mallocz failed for packet data.');
    }
    final packetBytes = padded.asTypedList(packetSize);
    packetBytes.setAll(0, parameterBytes);
    packetBytes.setAll(parameterBytes.length, ranged);

    final packetResult = _libraries.packetFromData(_packet, padded, packetSize);
    if (packetResult < 0) {
      _libraries.avFree(padded);
      throw FfmpegException('av_packet_from_data failed ($packetResult).');
    }

    try {
      final frames = <DecodedFrame>[];
      var result = _libraries.sendPacket(_context, _packet);
      if (result == _averrorEagain) {
        frames.addAll(_receiveFrames());
        result = _libraries.sendPacket(_context, _packet);
      }
      if (result < 0) {
        throw FfmpegException('avcodec_send_packet failed ($result).');
      }
      frames.addAll(_receiveFrames());
      return frames;
    } finally {
      _libraries.packetUnref(_packet);
    }
  }

  List<DecodedFrame> _receiveFrames() {
    final frames = <DecodedFrame>[];

    while (true) {
      final result = _libraries.receiveFrame(_context, _frame.cast<Void>());
      if (result == _averrorEagain || result == _averrorEof) {
        break;
      }
      if (result < 0) {
        throw FfmpegException('avcodec_receive_frame failed ($result).');
      }

      try {
        frames.add(_copyFrame());
      } finally {
        _libraries.frameUnref(_frame.cast<Void>());
      }
    }

    return frames;
  }

  DecodedFrame _copyFrame() {
    final frame = _frame.ref;
    if (_backend == FfmpegDecodeBackend.d3d11va &&
        frame.format == FfmpegAbi.pixFmtD3d11) {
      return _copyHardwareFrame(frame);
    }
    if (_backend == FfmpegDecodeBackend.d3d11va) {
      // The hwaccel decoder can hand out software frames (for example after an
      // unusual stream change); keep them on the existing software path.
      debugPrint(
        '[hwaccel] decoder returned pixel format ${frame.format} instead of '
        'D3D11; using the software copy path for this frame',
      );
    }
    return _copySoftwareFrame(frame);
  }

  /// Copies the decoded D3D11 texture into the overlay while the AVFrame still
  /// owns it, so no reference counting is needed on the Dart side.
  DecodedFrame _copyHardwareFrame(_AVFrame frame) {
    final width = frame.width;
    final height = frame.height;
    if (width <= 0 || height <= 0) {
      throw FfmpegException(
        'Decoder returned invalid dimensions ${width}x$height.',
      );
    }

    final texture = frame.data[0].address;
    final slice = frame.data[1].address;
    final error = StringBuffer();
    final result = _bridge!.copyTexture(
      texture: texture,
      slice: slice,
      width: width,
      height: height,
      error: error,
    );
    if (result == 0) {
      return DecodedFrame.hardware(
        width: width,
        height: height,
        contentRect: _detectContentRectFromHardwareFrame(width, height),
      );
    }

    // A copy can fail transiently (window resized/destroyed, device busy). Only
    // a foreign device means the whole session cannot use the shared device;
    // everything else downloads this frame and keeps trying the GPU path.
    if (result == 1 && !_loggedCrossDevice) {
      _loggedCrossDevice = true;
      debugPrint(
        '[hwaccel] using separate device, cross-device copy required; '
        'downloading hardware frames for this session',
      );
    } else if (result != 1 && !_loggedCopyFailure) {
      _loggedCopyFailure = true;
      debugPrint(
        '[hwaccel] native copy failed (${error.toString().trim()}); '
        'downloading this frame and retrying on the next one',
      );
    }
    return _copyDownloadedFrame(width, height);
  }

  /// Cross-device fallback: let FFmpeg download the texture to NV12, then split
  /// it into YUV420p planes for the existing software upload path.
  DecodedFrame _copyDownloadedFrame(int width, int height) {
    final scratch = _ensureDownloadFrame();
    final result = _libraries.hwFrameTransferData(
      scratch.cast<Void>(),
      _frame.cast<Void>(),
      0,
    );
    if (result < 0) {
      throw FfmpegException('av_hwframe_transfer_data failed ($result).');
    }
    try {
      final frame = scratch.ref;
      if (frame.format != FfmpegAbi.pixFmtNv12) {
        throw FfmpegException(
          'Hardware download produced pixel format ${frame.format}; '
          'expected NV12.',
        );
      }
      return _nv12ToYuv420p(frame, width, height);
    } finally {
      _libraries.frameUnref(scratch.cast<Void>());
    }
  }

  /// Content-rect detection for the hardware path.
  ///
  /// D3D11 frames have no CPU-readable planes, so one frame is downloaded
  /// (≈1.4 MB for 1280x720) to measure the letterbox bars. That only happens on
  /// a trigger (first frame, frame-size change, video-window resize) or on the
  /// 60 s safety sweep; with no change there is no readback at all.
  FrameContentRect? _detectContentRectFromHardwareFrame(int width, int height) {
    if (!_shouldProbeContent(width, height)) {
      return _contentRect;
    }
    try {
      final downloaded = _copyDownloadedFrame(width, height);
      return _detectContentRect(
        y: downloaded.y,
        stride: downloaded.yStride,
        width: width,
        height: height,
      );
    } catch (error) {
      _pendingProbe = null;
      _contentRectDetected = true;
      _lastContentProbe = DateTime.now();
      _probedWidth = width;
      _probedHeight = height;
      _contentRect = null;
      debugPrint('[content] probe failed: $error; keeping the full frame');
      return null;
    }
  }

  /// Whether this frame needs to be measured.
  ///
  /// A frame-size change is itself a trigger; otherwise the cached rect is
  /// reused until [requestContentProbe] or the safety sweep asks again.
  bool _shouldProbeContent(int width, int height) {
    if (_contentRectDetected &&
        (width != _probedWidth || height != _probedHeight)) {
      _pendingProbe = ContentProbeReason.sizeChange;
    }
    if (!_contentRectDetected) {
      return true;
    }
    if (_pendingProbe != null) {
      return true;
    }
    return DateTime.now().difference(_lastContentProbe) >=
        contentProbeInterval;
  }

  /// Measures the letterbox bars from a Y plane and updates the cached rect.
  FrameContentRect? _detectContentRect({
    required List<int> y,
    required int stride,
    required int width,
    required int height,
  }) {
    final reason = _pendingProbe ??
        (_contentRectDetected
            ? ContentProbeReason.timer
            : ContentProbeReason.initial);
    _pendingProbe = null;
    _contentRectDetected = true;
    _lastContentProbe = DateTime.now();
    _probedWidth = width;
    _probedHeight = height;
    final rect = detectFrameContentRect(
      y: y,
      stride: stride,
      width: width,
      height: height,
    );
    _contentRect = rect;
    debugPrint(
      '[content] probe: reason=${reason.logName} rect=${rect ?? 'none'}',
    );
    return rect;
  }

  /// Software path: the planes are already in memory, but the trigger rules
  /// are identical, so a probe never runs on every frame.
  FrameContentRect? _maybeDetectContentRect({
    required List<int> y,
    required int stride,
    required int width,
    required int height,
  }) {
    if (!_shouldProbeContent(width, height)) {
      return _contentRect;
    }
    return _detectContentRect(
      y: y,
      stride: stride,
      width: width,
      height: height,
    );
  }

  Pointer<_AVFrame> _ensureDownloadFrame() {
    var scratch = _downloadFrame;
    if (scratch == nullptr) {
      scratch = _libraries.frameAlloc().cast<_AVFrame>();
      if (scratch == nullptr) {
        throw const FfmpegException('AVFrame allocation failed.');
      }
      _downloadFrame = scratch;
    }
    return scratch;
  }

  DecodedFrame _nv12ToYuv420p(_AVFrame frame, int width, int height) {
    final yStride = frame.linesize[0];
    final uvStride = frame.linesize[1];
    if (yStride <= 0 || uvStride <= 0) {
      throw const FfmpegException(
        'Downloaded NV12 frame has negative strides.',
      );
    }
    final chromaWidth = (width + 1) >> 1;
    final chromaHeight = (height + 1) >> 1;
    final ySource = frame.data[0];
    final uvSource = frame.data[1];
    if (ySource == nullptr || uvSource == nullptr) {
      throw const FfmpegException('Downloaded NV12 frame has null planes.');
    }

    final y = Uint8List.fromList(ySource.asTypedList(yStride * height));
    final uv = uvSource.asTypedList(uvStride * chromaHeight);
    final u = Uint8List(chromaWidth * chromaHeight);
    final v = Uint8List(chromaWidth * chromaHeight);
    for (var row = 0; row < chromaHeight; row++) {
      final rowOffset = row * uvStride;
      final targetOffset = row * chromaWidth;
      for (var column = 0; column < chromaWidth; column++) {
        u[targetOffset + column] = uv[rowOffset + column * 2];
        v[targetOffset + column] = uv[rowOffset + column * 2 + 1];
      }
    }

    return DecodedFrame(
      width: width,
      height: height,
      pixelFormat: FfmpegAbi.pixFmtYuv420p,
      y: y,
      u: u,
      v: v,
      yStride: yStride,
      uStride: chromaWidth,
      vStride: chromaWidth,
    );
  }

  DecodedFrame _copySoftwareFrame(_AVFrame frame) {
    final width = frame.width;
    final height = frame.height;
    final format = frame.format;

    if (width <= 0 || height <= 0) {
      throw FfmpegException(
        'Decoder returned invalid dimensions ${width}x$height.',
      );
    }
    if (format != 0 && format != 12) {
      throw FfmpegException(
        'Unsupported decoded pixel format $format; expected yuv420p.',
      );
    }

    final yStride = frame.linesize[0];
    final uStride = frame.linesize[1];
    final vStride = frame.linesize[2];
    if (yStride <= 0 || uStride <= 0 || vStride <= 0) {
      throw const FfmpegException(
        'Negative image strides are not supported by this minimal decoder.',
      );
    }

    final chromaHeight = (height + 1) >> 1;
    final y = _copyPlane(frame.data[0], yStride, height);
    final u = _copyPlane(frame.data[1], uStride, chromaHeight);
    final v = _copyPlane(frame.data[2], vStride, chromaHeight);

    return DecodedFrame(
      width: width,
      height: height,
      pixelFormat: format,
      y: y,
      u: u,
      v: v,
      yStride: yStride,
      uStride: uStride,
      vStride: vStride,
      contentRect: _maybeDetectContentRect(
        y: y,
        stride: yStride,
        width: width,
        height: height,
      ),
    );
  }

  Uint8List _copyPlane(Pointer<Uint8> data, int stride, int rows) {
    if (data == nullptr) {
      throw const FfmpegException('AVFrame returned a null plane.');
    }
    return Uint8List.fromList(data.asTypedList(stride * rows));
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('FfmpegDecoder has been disposed.');
    }
  }

  void dispose() {
    if (_closed) {
      return;
    }
    _closed = true;

    if (_frame != nullptr) {
      _freePointer(_frame.cast<Void>(), _libraries.frameFree);
      _frame = nullptr;
    }
    if (_downloadFrame != nullptr) {
      _freePointer(_downloadFrame.cast<Void>(), _libraries.frameFree);
      _downloadFrame = nullptr;
    }
    if (_packet != nullptr) {
      _freePointer(_packet, _libraries.packetFree);
      _packet = nullptr;
    }
    if (_context != nullptr) {
      _freePointer(_context, _libraries.freeContext);
      _context = nullptr;
    }
  }

  void _freePointer(
    Pointer<Void> pointer,
    void Function(Pointer<Pointer<Void>>) free,
  ) {
    final cell = calloc<Pointer<Void>>();
    try {
      cell.value = pointer;
      free(cell);
    } finally {
      calloc.free(cell);
    }
  }
}

final class _AVFrame extends Struct {
  @Array(8)
  external Array<Pointer<Uint8>> data;

  @Array(8)
  external Array<Int32> linesize;

  external Pointer<Pointer<Uint8>> extendedData;

  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int nbSamples;

  @Int32()
  external int format;
}
