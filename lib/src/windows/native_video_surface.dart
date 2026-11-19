import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_cast_windows/screen_cast_windows.dart';

import '../ffmpeg/decoded_frame.dart';
import '../ffmpeg/frame_content_rect.dart';
import '../pipeline/decoded_frame_sink.dart';
import 'nv12_frame_buffer.dart';
import 'nv12_frame_writer.dart';

/// One input event captured by the native overlay.
///
/// [type] uses the control-channel numbering so it can be mapped straight to a
/// [ControlMessageType]: 1 touch down, 2 touch move, 3 touch up, 4 wheel,
/// 5 key down, 6 key up. Coordinates are normalized to the overlay window.
///
/// [wheelDelta] is the raw Windows `GET_WHEEL_DELTA_WPARAM` value (multiples of
/// 120, positive = scroll up) and is forwarded to the server unchanged.
@immutable
class NativeInputEvent {
  const NativeInputEvent({
    required this.type,
    this.normalizedX = 0,
    this.normalizedY = 0,
    this.keyCode = 0,
    this.wheelDelta = 0,
  });

  final int type;
  final double normalizedX;
  final double normalizedY;
  final int keyCode;
  final int wheelDelta;

  @override
  String toString() =>
      'NativeInputEvent(type: $type, x: $normalizedX, y: $normalizedY, '
      'key: $keyCode, wheel: $wheelDelta)';
}

/// Connects the decoder output to the native D3D11 overlay.
///
/// The native side maps a DXGI_FORMAT_NV12 staging texture and returns its CPU
/// pointer to Dart. Frames are written directly into that mapping; pixel bytes
/// never go through a MethodChannel or an intermediate serialization buffer.
class NativeVideoSurfaceController implements DecodedFrameSink {
  _NativeVideoSurfaceState? _surface;
  final StreamController<NativeInputEvent> _inputEvents =
      StreamController<NativeInputEvent>.broadcast();
  bool _inputEnabled = false;

  bool get isAttached => _surface != null;

  /// Input events captured on the overlay while input is enabled.
  Stream<NativeInputEvent> get inputEvents => _inputEvents.stream;

  bool get inputEnabled => _inputEnabled;

  /// Fired when an asynchronous `presentFrame` fails after the frame was
  /// already written into a staging texture. The surface reconfigures on the
  /// next frame; the caller only needs to surface the message.
  void Function(Object error)? onUploadError;

  /// Fired when the user finishes resizing the independent video window.
  ///
  /// Content-rect probing is trigger driven, so this is one of the few moments
  /// the decoder is asked to measure the letterbox bars again.
  void Function()? onWindowResize;

  /// Fired when the video window is shown or hidden by the user (the close
  /// button hides it; the session keeps running).
  void Function(bool visible)? onVideoVisibilityChanged;

  /// Toggles overlay pointer/keyboard capture. Disabled means the overlay stays
  /// click-through, so Flutter widgets under the preview keep their gestures.
  Future<void> setInputEnabled(bool enabled) async {
    _inputEnabled = enabled;
    await _surface?.setInputEnabled(enabled);
  }

  @override
  Future<FrameUploadStatus> presentFrame(DecodedFrame frame) {
    final surface = _surface;
    if (surface == null) {
      return Future<FrameUploadStatus>.value(FrameUploadStatus.unavailable);
    }
    return surface.uploadFrame(frame);
  }

  void _attach(_NativeVideoSurfaceState surface) {
    _surface = surface;
  }

  void _detach(_NativeVideoSurfaceState surface) {
    if (identical(_surface, surface)) {
      _surface = null;
    }
  }

  void _emitInput(NativeInputEvent event) {
    if (!_inputEvents.isClosed) {
      _inputEvents.add(event);
    }
  }

  void _emitUploadError(Object error) {
    onUploadError?.call(error);
  }

  void _emitWindowResize() {
    onWindowResize?.call();
  }

  void _emitVideoVisibility(bool visible) {
    onVideoVisibilityChanged?.call(visible);
  }

  /// Brings the independent video window to the front.
  Future<void> showVideoWindow() async {
    await _surface?.showVideoWindow();
  }

  /// Brings the Flutter main window back to the front.
  ///
  /// Auto-connect uses this to surface a failure when the window was closed to
  /// the tray, so a PSK mismatch is never silent.
  Future<void> showMainWindow() async {
    await _surface?.showMainWindow();
  }

  /// Pushes connection state to the tray icon; safe to call frequently.
  Future<void> updateStatus({
    required bool connected,
    int width = 0,
    int height = 0,
    int fps = 0,
  }) async {
    await _surface?.updateStatus(
      connected: connected,
      width: width,
      height: height,
      fps: fps,
    );
  }

  /// Frames actually presented per second, measured by the native renderer.
  Future<int?> getPresentFps() async => _surface?.presentFps();

  void dispose() {
    _inputEvents.close();
  }
}

/// Flutter-side handle for the independent native video window.
///
/// The video is no longer composited over this widget: [NativeVideoSurface]
/// creates a separate top-level Win32 window (D3D11) once and drives it through
/// the channel. This widget only provides a placeholder in the Flutter layout
/// plus the "show video window" affordance.
class NativeVideoSurface extends StatefulWidget {
  const NativeVideoSurface({
    super.key,
    required this.clipViewportKey,
    this.controller,
    this.revision,
    this.fallback,
    this.onBackendChanged,
  });

  final GlobalKey clipViewportKey;
  final NativeVideoSurfaceController? controller;
  final ValueListenable<int>? revision;
  final Widget? fallback;

  /// Reports `D3D11`, `GDI`, or `Unavailable` after the native view is created.
  final ValueChanged<String>? onBackendChanged;

  @override
  State<NativeVideoSurface> createState() => _NativeVideoSurfaceState();
}

class _NativeVideoSurfaceState extends State<NativeVideoSurface>
    with WidgetsBindingObserver {
  static const MethodChannel _channel = MethodChannel(
    screenCastWindowsChannelName,
  );

  final GlobalKey _surfaceKey = GlobalKey();
  bool _created = false;
  bool _d3d11 = false;
  bool _failed = false;
  bool _visible = false;
  bool _syncScheduled = false;
  bool _uploading = false;
  FrameContentRect? _sentContentRect;

  /// Two mapped staging textures plus the in-flight present bookkeeping.
  Nv12DoubleBuffer? _frameBuffer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.revision?.addListener(_requestSync);
    widget.controller?._attach(this);
    _channel.setMethodCallHandler(_handleNativeCall);
    _requestSync();
  }

  /// Native overlay pushes captured pointer/keyboard events here; they are
  /// forwarded to the control socket by [CastController], never by this widget.
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method == 'windowResized') {
      widget.controller?._emitWindowResize();
      return null;
    }
    if (call.method == 'videoVisibilityChanged') {
      final visible = call.arguments is bool ? call.arguments as bool : true;
      widget.controller?._emitVideoVisibility(visible);
      return null;
    }
    if (call.method != 'controlEvent') {
      return null;
    }
    final arguments = call.arguments;
    if (arguments is! Map) {
      return null;
    }
    final event = NativeInputEvent(
      type: (arguments['type'] as num?)?.toInt() ?? 0,
      normalizedX: (arguments['x'] as num?)?.toDouble() ?? 0,
      normalizedY: (arguments['y'] as num?)?.toDouble() ?? 0,
      keyCode: (arguments['keyCode'] as num?)?.toInt() ?? 0,
      wheelDelta: (arguments['wheelDelta'] as num?)?.toInt() ?? 0,
    );
    widget.controller?._emitInput(event);
    return null;
  }

  Future<void> setInputEnabled(bool enabled) async {
    if (!Platform.isWindows || _failed) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('setInputEnabled', <String, Object?>{
        'enabled': enabled,
      });
    } on MissingPluginException {
      // No native plugin (tests, non-Windows): nothing to capture.
    } catch (_) {
      // Keep the video path alive even if input toggling fails.
    }
  }

  @override
  void didUpdateWidget(covariant NativeVideoSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) {
      oldWidget.revision?.removeListener(_requestSync);
      widget.revision?.addListener(_requestSync);
    }
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
      _resetFrameBuffer();
    }
    _requestSync();
  }

  @override
  void didChangeMetrics() {
    _requestSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.revision?.removeListener(_requestSync);
    widget.controller?._detach(this);
    _channel.setMethodCallHandler(null);
    _resetFrameBuffer();
    if (_created && Platform.isWindows) {
      unawaited(
        _channel
            .invokeMethod<void>('setInputEnabled', <String, Object?>{
              'enabled': false,
            })
            .catchError((_) {}),
      );
      unawaited(_channel.invokeMethod<void>('dispose').catchError((_) {}));
    }
    super.dispose();
  }

  void _requestSync() {
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (mounted) {
        unawaited(_ensureVideoWindow());
      }
    });
  }

  /// Writes [frame] into one of the two staging textures and returns without
  /// waiting for the native present.
  ///
  /// This is what removes the old "decode loop waits for the upload" stall: the
  /// decode loop only pays the CPU copy, while the GPU copy and the draw happen
  /// asynchronously. Frames are written into the texture that is **not** being
  /// presented; when the rotation lands on a texture that is still in flight
  /// (or both are), the frame is dropped instead of queued and the caller
  /// counts it.
  Future<FrameUploadStatus> uploadFrame(DecodedFrame frame) async {
    await _syncContentRect(frame);
    if (frame.hardwarePresented) {
      // D3D11VA: the decoder already copied the texture into this overlay's
      // video texture inside the FFmpeg receive call. There is nothing to
      // upload and no present slot to arbitrate.
      return FrameUploadStatus.uploaded;
    }
    if (!Platform.isWindows ||
        _failed ||
        !_created ||
        !_d3d11 ||
        !frame.isYuv420p) {
      return FrameUploadStatus.unavailable;
    }
    if (frame.width <= 0 ||
        frame.height <= 0 ||
        (frame.width & 1) != 0 ||
        (frame.height & 1) != 0) {
      throw ArgumentError(
        'D3D11 NV12 requires positive even frame dimensions, '
        'got ${frame.width}x${frame.height}.',
      );
    }
    if (_uploading) {
      // Defensive: the decode loop awaits this call, so only a programming
      // error can re-enter it.
      throw StateError('A native video frame upload is already in progress.');
    }

    _uploading = true;
    try {
      final crop = _cropFor(frame);
      var buffer = _frameBuffer;
      if (buffer == null || !buffer.matches(crop.width, crop.height)) {
        // Reconfiguring unmaps/recreates native textures, which is only safe
        // while no present is in flight.
        if (buffer != null && buffer.presentInFlight) {
          return FrameUploadStatus.dropped;
        }
        await _configureFrameBuffer(crop.width, crop.height);
        buffer = _frameBuffer;
        if (buffer == null) {
          return FrameUploadStatus.unavailable;
        }
      }

      final Nv12UploadTarget? target;
      try {
        target = buffer.write(
          frame,
          left: crop.left,
          top: crop.top,
          width: crop.width,
          height: crop.height,
        );
      } catch (_) {
        // The mapping may be stale; rebuild it on the next frame.
        _resetFrameBuffer();
        rethrow;
      }
      if (target == null) {
        return FrameUploadStatus.dropped;
      }

      buffer.beginPresent(target.index);
      unawaited(_presentFrame(target.index));
      return FrameUploadStatus.uploaded;
    } on MissingPluginException {
      _markUnavailable();
      return FrameUploadStatus.unavailable;
    } finally {
      _uploading = false;
    }
  }

  /// Presents one staging texture and applies the remapped pointer it returns.
  Future<void> _presentFrame(int index) async {
    final buffer = _frameBuffer;
    if (buffer == null) {
      return;
    }
    try {
      final response = await _channel.invokeMapMethod<String, Object?>(
        'presentFrame',
        <String, Object?>{'index': index},
      );
      if (!identical(buffer, _frameBuffer)) {
        // Reconciled or disposed while the present was in flight.
        return;
      }
      final pointer = (response?['pointer'] as num?)?.toInt() ?? 0;
      final rowPitch = (response?['rowPitch'] as num?)?.toInt() ?? 0;
      if (pointer == 0 || rowPitch < buffer.width) {
        throw StateError(
          'Native NV12 remap is invalid: pointer=$pointer '
          'rowPitch=$rowPitch width=${buffer.width}.',
        );
      }
      buffer.completePresent(
        index,
        pointer: pointer,
        rowPitch: rowPitch,
        destination: _mappedView(pointer, buffer.width, buffer.height, rowPitch),
      );
    } on MissingPluginException {
      buffer.failPresent(index);
      _markUnavailable();
    } catch (error) {
      buffer.failPresent(index);
      // The native mapping is unknown now; force a fresh configure on the next
      // frame instead of writing through a stale pointer.
      _resetFrameBuffer();
      widget.controller?._emitUploadError(error);
    }
  }

  Uint8List _mappedView(
    int pointer,
    int width,
    int height,
    int rowPitch,
  ) {
    final byteCount = Nv12FrameWriter.requiredBytes(
      width: width,
      height: height,
      rowPitch: rowPitch,
    );
    return Pointer<Uint8>.fromAddress(pointer).asTypedList(byteCount);
  }

  /// Even-aligned pixel crop of [frame], or the full frame when no letterbox
  /// bars were detected.
  ({int left, int top, int width, int height}) _cropFor(DecodedFrame frame) {
    final rect = frame.contentRect;
    if (rect == null || rect.isFull) {
      return (left: 0, top: 0, width: frame.width, height: frame.height);
    }
    final left = ((rect.left * frame.width).round() & ~1)
        .clamp(0, frame.width - 2);
    final top = ((rect.top * frame.height).round() & ~1)
        .clamp(0, frame.height - 2);
    final width = ((rect.width * frame.width).round() & ~1)
        .clamp(2, frame.width - left);
    final height = ((rect.height * frame.height).round() & ~1)
        .clamp(2, frame.height - top);
    return (left: left, top: top, width: width, height: height);
  }

  Future<void> _configureFrameBuffer(int width, int height) async {
    final response = await _channel.invokeMapMethod<String, Object?>(
      'configureFrame',
      <String, Object?>{
        'width': width,
        'height': height,
      },
    );
    _readConfigureResponse(response, width, height);
  }

  void _readConfigureResponse(
    Map<String, Object?>? response,
    int width,
    int height,
  ) {
    final rawTargets = response?['targets'];
    if (rawTargets is! List ||
        rawTargets.length != Nv12DoubleBuffer.targetCount) {
      throw StateError(
        'configureFrame must return '
        '${Nv12DoubleBuffer.targetCount} upload targets, got $rawTargets.',
      );
    }

    final targets = <Nv12UploadTarget>[];
    for (final raw in rawTargets) {
      if (raw is! Map) {
        throw StateError('Invalid NV12 upload target: $raw.');
      }
      final index = (raw['index'] as num?)?.toInt() ?? -1;
      final pointer = (raw['pointer'] as num?)?.toInt() ?? 0;
      final rowPitch = (raw['rowPitch'] as num?)?.toInt() ?? 0;
      if (index < 0 || index >= Nv12DoubleBuffer.targetCount) {
        throw StateError('Invalid NV12 upload target index $index.');
      }
      if (pointer == 0 || rowPitch < width) {
        throw StateError(
          'Native NV12 upload mapping is invalid: '
          'index=$index pointer=$pointer rowPitch=$rowPitch width=$width.',
        );
      }
      targets.add(
        Nv12UploadTarget(
          index: index,
          pointer: pointer,
          rowPitch: rowPitch,
          width: width,
          height: height,
          destination: _mappedView(pointer, width, height, rowPitch),
        ),
      );
    }
    targets.sort(
      (Nv12UploadTarget a, Nv12UploadTarget b) => a.index.compareTo(b.index),
    );
    _frameBuffer = Nv12DoubleBuffer(targets: targets);
  }

  void _resetFrameBuffer() {
    _frameBuffer = null;
  }

  /// Creates the independent video window once and keeps it visible.
  ///
  /// The window is no longer glued to this widget: it is a free-floating
  /// top-level window with its own drag/resize/fullscreen handling, so layout
  /// changes here must not move it.
  Future<void> _ensureVideoWindow() async {
    if (!Platform.isWindows || _failed) {
      return;
    }
    try {
      if (!_created) {
        final response =
            await _channel.invokeMapMethod<String, Object?>('create');
        _created = true;
        _d3d11 = response?['d3d11'] == true;
        final backend = _d3d11 ? 'D3D11' : 'GDI';
        widget.onBackendChanged?.call(backend);
        // Input may have been enabled while the window did not exist yet.
        if (widget.controller?.inputEnabled == true) {
          await setInputEnabled(true);
        }
      }
      if (!_visible) {
        await _setVisible(true);
      }
    } on MissingPluginException {
      _markUnavailable();
    } on PlatformException {
      _markUnavailable();
    } catch (_) {
      _markUnavailable();
    }
  }

  /// Tells the native window which sub-rect of the frame holds the mirrored
  /// screen. Sent once per session: it crops the encoder's letterbox bars and
  /// fits the window to the phone's aspect ratio.
  Future<void> _syncContentRect(DecodedFrame frame) async {
    final rect = frame.contentRect;
    if (rect == null || rect.isFull || rect == _sentContentRect) {
      return;
    }
    _sentContentRect = rect;
    try {
      await _channel.invokeMethod<void>('setContentRect', <String, Object?>{
        'x': rect.left,
        'y': rect.top,
        'width': rect.width,
        'height': rect.height,
      });
    } on MissingPluginException {
      // Non-Windows host: nothing to crop.
    } catch (_) {
      // Presentation keeps working without the crop.
    }
  }

  void _markUnavailable() {
    if (!mounted || _failed) {
      return;
    }
    widget.onBackendChanged?.call('Unavailable');
    setState(() {
      _failed = true;
      _visible = false;
    });
  }

  Future<void> _setVisible(bool visible) async {
    if (_created) {
      await _channel.invokeMethod<void>('setVisible', <String, Object?>{
        'visible': visible,
      });
    }
    _visible = visible;
  }

  /// Brings the independent video window to the front.
  Future<void> showVideoWindow() async {
    if (!_created) {
      await _ensureVideoWindow();
      return;
    }
    await _channel.invokeMethod<void>('showVideoWindow');
  }

  /// Brings the Flutter main window back to the front.
  Future<void> showMainWindow() async {
    if (!Platform.isWindows) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('showMainWindow');
    } on MissingPluginException {
      // No native plugin (tests, non-Windows): nothing to restore.
    } catch (_) {
      // Restoring the window is cosmetic; never surface it as an error.
    }
  }

  /// Pushes connection state so the tray icon and tooltip stay current.
  Future<void> updateStatus({
    required bool connected,
    int width = 0,
    int height = 0,
    int fps = 0,
  }) async {
    if (!_created) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('updateStatus', <String, Object?>{
        'connected': connected,
        'width': width,
        'height': height,
        'fps': fps,
      });
    } on MissingPluginException {
      // No tray on non-Windows hosts.
    } on PlatformException {
      // Status is cosmetic; never surface it as a session error.
    }
  }

  /// Swap-chain presents per second, as counted by the native renderer.
  Future<int?> presentFps() async {
    if (!_created || _failed) {
      return null;
    }
    try {
      final response =
          await _channel.invokeMapMethod<String, Object?>('getStatus');
      return (response?['presentFps'] as num?)?.toInt();
    } on MissingPluginException {
      return null;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    _requestSync();
    return SizedBox.expand(
      key: _surfaceKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.fallback ??
              _FlutterPlaceholder(
                onShowWindow: Platform.isWindows && !_failed
                    ? () => unawaited(showVideoWindow())
                    : null,
              ),
          if (_failed || !Platform.isWindows)
            const _NativeUnavailableOverlay()
          else
            const SizedBox.shrink(),
        ],
      ),
    );
  }
}

class _FlutterPlaceholder extends StatelessWidget {
  const _FlutterPlaceholder({this.onShowWindow});

  /// Opens the independent video window; null on non-Windows hosts.
  final VoidCallback? onShowWindow;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF101A22), Color(0xFF070B10)],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.desktop_windows_outlined,
              size: 40,
              color: Color(0xFF35E0A1),
            ),
            const SizedBox(height: 10),
            const Text(
              '视频在独立窗口中播放',
              style: TextStyle(
                color: Color(0xFFA6B4C1),
                fontSize: 13,
              ),
            ),
            if (onShowWindow != null) ...[
              const SizedBox(height: 12),
              FilledButton.tonalIcon(
                key: const Key('show-video-window'),
                onPressed: onShowWindow,
                icon: const Icon(Icons.open_in_new, size: 16),
                label: const Text('显示视频窗口'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _NativeUnavailableOverlay extends StatelessWidget {
  const _NativeUnavailableOverlay();

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.25),
        ),
        child: Center(
          child: Container(
            margin: const EdgeInsets.all(18),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: const Color(0xFFFFA657).withValues(alpha: 0.4),
              ),
            ),
            child: const Text(
              '原生 D3D11 视图未加载，当前显示 Flutter 占位',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Color(0xFFFFC078),
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
