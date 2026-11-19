import 'dart:async';

import 'package:flutter/foundation.dart';

import '../control/control_message.dart';
import '../discovery/auto_connect.dart';
import '../discovery/cast_offer.dart';
import '../ffmpeg/decoded_frame.dart';
import '../pipeline/cast_session.dart';
import '../pipeline/decoded_frame_sink.dart';
import '../transport/cast_transport.dart';
import 'cast_frame_stats.dart';
import 'cast_session_state.dart';

class CastController extends ChangeNotifier implements AutoConnectTarget {
  CastController({
    int port = 27183,
    CastTransportMode transportMode = CastTransportMode.wired,
    String host = '',
    String pskHex = '',
    bool autoConnect = false,
    CastSession Function()? sessionFactory,
    DecodedFrameSink? frameSink,
  })  : _state = const CastSessionState.initial().copyWith(
          port: port,
          transportMode: transportMode,
          host: host,
          pskHex: pskHex,
          autoConnect: autoConnect,
        ),
        _sessionFactory = sessionFactory,
        _frameSink = frameSink;

  final CastSession Function()? _sessionFactory;
  final DecodedFrameSink? _frameSink;

  CastSessionState _state;
  CastSession? _session;

  /// Transport actually used by the current session. Auto-connect resolves the
  /// PSK from the offer, so this can differ from [CastSessionState.transport].
  CastTransportConfig? _activeConfig;
  bool _disposed = false;
  bool _stopping = false;
  bool _recovering = false;
  int _generation = 0;
  String? _wirelessTcpSerial;

  /// Decode/upload counters; sampled once per second for the debug log.
  final CastFrameStats _stats = CastFrameStats();
  Timer? _statsTimer;

  CastSessionState get state => _state;

  /// Cumulative pipeline counters, also mirrored into [state].
  CastFrameStats get frameStats => _stats;

  @override
  bool get autoConnectEnabled => _state.autoConnect;

  @override
  CastStatus get castStatus => _state.status;

  @override
  String get pskHex => _state.pskHex;

  @override
  String get statusMessage => _state.message;

  /// Turns the LAN discovery auto-connect switch on/off.
  ///
  /// Allowed while a session runs: the setting only affects the next offer.
  void setAutoConnect(bool enabled) {
    if (_disposed || _state.autoConnect == enabled || _state.status.isBusy) {
      return;
    }
    _update(_state.copyWith(autoConnect: enabled));
  }

  @override
  void reportDiscovery(String message, {bool error = false}) {
    if (_disposed) {
      return;
    }
    if (_state.discoveryStatus == message && _state.discoveryError == error) {
      return;
    }
    _update(
      _state.copyWith(discoveryStatus: message, discoveryError: error),
    );
    debugPrint('[discovery] $message');
  }

  /// Connects to a phone that announced itself over LAN discovery.
  ///
  /// Switches the UI to [CastTransportMode.direct] with the advertised ports.
  /// The PSK follows the offer: a plaintext server (`pskRequired=false`) is
  /// reached without a key even when one is configured for manual sessions.
  @override
  Future<bool> connectToOffer(CastOffer offer) async {
    if (_disposed) {
      return false;
    }
    _update(
      _state.copyWith(
        transportMode: CastTransportMode.direct,
        host: offer.ip,
        port: offer.videoPort,
        controlPort: offer.controlPort,
        message: '已发现 ${offer.ip}，正在以直连模式自动连接……',
        discoveryError: false,
        clearFrameCounters: true,
        frameWidth: 0,
        frameHeight: 0,
      ),
    );
    final config = _state.transport.copyWith(
      pskHex: pskForOffer(offer: offer, configuredPsk: _state.pskHex),
    );
    return _startWith(config);
  }

  void setTransportMode(CastTransportMode mode) {
    if (_disposed || !_state.canConfigureTransport) {
      return;
    }
    _update(_state.copyWith(transportMode: mode));
  }

  void setHost(String host) {
    if (_disposed || !_state.canConfigureTransport) {
      return;
    }
    _update(_state.copyWith(host: host));
  }

  /// Sets the hex PSK used by the record layer; empty means plaintext.
  void setPskHex(String pskHex) {
    if (_disposed || !_state.canConfigureTransport) {
      return;
    }
    _update(_state.copyWith(pskHex: pskHex));
  }

  /// Starts a session with the transport currently shown in the UI.
  Future<void> start() async {
    await _startWith(_state.transport);
  }

  /// Shared start path for the button and LAN auto-connect.
  /// Returns true only when the session reached [CastStatus.running].
  Future<bool> _startWith(CastTransportConfig config) async {
    if (_disposed || _state.status.isBusy) {
      return _state.status == CastStatus.running;
    }
    if (_state.status == CastStatus.running) {
      return true;
    }

    try {
      config.validate();
    } catch (error) {
      _update(
        _state.copyWith(
          status: CastStatus.error,
          message: _describeError(error),
          clearFrameCounters: true,
          frameWidth: 0,
          frameHeight: 0,
        ),
      );
      return false;
    }

    _activeConfig = config;
    _wirelessTcpSerial = null;
    final previous = _session;
    _session = null;
    if (previous != null) {
      await previous.stop();
    }

    final generation = ++_generation;
    _stats.reset();
    _update(
      _state.copyWith(
        status: CastStatus.starting,
        message: _startingMessage(config),
        clearFrameCounters: true,
        frameWidth: 0,
        frameHeight: 0,
        controlLink: ControlLinkState.connecting,
        clearAdbSerial: true,
      ),
    );

    final session = _sessionFactory?.call() ?? CastSession(transport: config);
    _session = session;

    try {
      final info = await session.start(
        onFrame: (DecodedFrame frame) => _handleFrame(generation, frame),
        onError: (Object error, StackTrace stackTrace) =>
            _handleSessionError(generation, error),
        onClosed: () => _handleSessionClosed(generation),
        onControlState: (bool connected) =>
            _handleControlState(generation, connected),
      );

      if (_disposed || generation != _generation) {
        await session.stop();
        return false;
      }
      if (_state.status == CastStatus.starting) {
        _wirelessTcpSerial = info.transportMode == CastTransportMode.wireless
            ? info.serial
            : null;
        final direct = info.transportMode == CastTransportMode.direct;
        _update(
          _state.copyWith(
            status: CastStatus.running,
            message: direct
                ? '已连接手机 App 启动的服务端 ${info.endpoint}，'
                    '${info.decoderBackend} 已就绪，等待 SCRC NAL。'
                : '服务端已在 ${info.serial} 上启动，SCRC 目标 ${info.endpoint}，'
                    '${info.decoderBackend} 已就绪，等待 SCRC NAL。',
            adbSerial: info.serial,
          ),
        );
      }
      return _state.status == CastStatus.running;
    } catch (error) {
      if (!_disposed && generation == _generation) {
        _session = null;
        _stopStatsTimer();
        _update(
          _state.copyWith(
            status: CastStatus.error,
            message: _describeError(error),
            clearFrameCounters: true,
            frameWidth: 0,
            frameHeight: 0,
            controlLink: ControlLinkState.disconnected,
          ),
        );
      }
      return false;
    }
  }

  /// Connects to a device picked in the merged device list.
  ///
  /// USB entries run wired mode with the selected ADB serial; LAN entries run
  /// direct mode against the phone address.
  Future<bool> connectToDevice({
    required CastTransportMode mode,
    String? host,
    String? serial,
    bool clearHost = false,
    bool clearSerial = false,
  }) async {
    if (_disposed) {
      return false;
    }
    if (_state.status == CastStatus.running) {
      return true;
    }
    if (_state.status.isBusy) {
      return false;
    }
    final label = mode == CastTransportMode.wired
        ? (serial ?? 'USB 设备')
        : (host ?? '');
    _update(
      _state.copyWith(
        transportMode: mode,
        host: clearHost ? '' : (host ?? _state.host),
        serial: clearSerial ? null : serial,
        message: '正在连接 $label ……',
        discoveryError: false,
        clearFrameCounters: true,
        frameWidth: 0,
        frameHeight: 0,
      ),
    );
    return _startWith(_state.transport);
  }

  /// "限制 60 帧" switch (persisted by the page into AppConfig).
  ///
  /// Only affects sessions this host starts itself (wired/wireless); `direct`
  /// connects to a server that someone else launched.
  void setLimit60Fps(bool enabled) {
    if (_disposed || _state.limit60Fps == enabled) {
      return;
    }
    _update(_state.copyWith(limit60Fps: enabled));
  }

  /// Updates the native present rate (sampled from the renderer's swap chain).
  void setPresentFps(int fps) {
    if (_disposed || _state.presentFps == fps) {
      return;
    }
    _update(_state.copyWith(presentFps: fps));
  }

  /// Asks the running session's decoder to re-measure the letterbox content
  /// rect (video-window resize, or a manual refresh).
  void requestContentProbe() {
    if (_disposed) {
      return;
    }
    _session?.requestContentProbe();
  }

  /// Forwards one input frame to the control socket. A dead control channel is
  /// not an error: the video session keeps running.
  bool sendControl(ControlMessage message) {
    if (_disposed) {
      return false;
    }
    return _session?.sendControl(message) ?? false;
  }

  void _handleControlState(int generation, bool connected) {
    if (_disposed || generation != _generation) {
      return;
    }
    _update(
      _state.copyWith(
        controlLink: connected
            ? ControlLinkState.connected
            : ControlLinkState.disconnected,
      ),
    );
  }

  Future<void> stop() async {
    if (_disposed || _stopping || _state.status == CastStatus.idle) {
      return;
    }
    _stopping = true;
    _generation++;
    _stopStatsTimer();
    _update(
      _state.copyWith(
        status: CastStatus.stopping,
        message: switch (_state.transport.mode) {
          CastTransportMode.wired =>
            '正在停止 app_process、移除端口转发并释放解码器……',
          CastTransportMode.wireless =>
            '正在停止 app_process、释放解码器并清理局域网直连会话……',
          CastTransportMode.direct => '正在断开与手机 App 服务端的连接并释放解码器……',
        },
      ),
    );

    final session = _session;
    _session = null;
    try {
      await session?.stop();
      if (!_disposed) {
        _update(
          _state.copyWith(
            status: CastStatus.idle,
            message: '会话已停止。',
            clearFrameCounters: true,
            frameWidth: 0,
            frameHeight: 0,
            controlLink: ControlLinkState.idle,
            clearAdbSerial: true,
          ),
        );
      }
    } catch (error) {
      if (!_disposed) {
        _update(
          _state.copyWith(
            status: CastStatus.error,
            message: '停止失败：${_describeError(error)}',
          ),
        );
      }
    } finally {
      _stopping = false;
      _wirelessTcpSerial = null;
      _activeConfig = null;
    }
  }

  Future<void> _handleFrame(int generation, DecodedFrame frame) async {
    if (_disposed || generation != _generation) {
      return;
    }
    _ensureStatsTimer();
    _stats.recordDecoded();

    var status = FrameUploadStatus.unavailable;
    Object? uploadError;
    try {
      status = await _frameSink?.presentFrame(frame) ??
          FrameUploadStatus.unavailable;
    } catch (error) {
      uploadError = error;
      _stats.recordFailed();
    }

    if (_disposed || generation != _generation) {
      return;
    }

    switch (status) {
      case FrameUploadStatus.uploaded:
        if (uploadError == null) {
          _stats.recordUploaded();
        }
      case FrameUploadStatus.dropped:
        if (uploadError == null) {
          _stats.recordDropped();
        }
      case FrameUploadStatus.unavailable:
        if (uploadError == null) {
          _stats.recordUnavailable();
        }
    }

    final decoded = _stats.decoded;
    final String format = frame.hardwarePresented ? 'D3D11VA' : 'YUV420p';
    final String message;
    if (uploadError != null) {
      message = '已解码 $decoded 帧，${frame.width}x${frame.height} $format；'
          'D3D11 NV12 上传失败：${_describeError(uploadError)}';
      if (decoded == 1 || decoded % 60 == 0) {
        debugPrint(message);
      }
    } else if (frame.hardwarePresented) {
      message = '已解码 $decoded 帧，${frame.width}x${frame.height} D3D11VA；'
          '硬解纹理已直接拷入 video texture（已上传 ${_stats.uploaded}，'
          '丢弃 ${_stats.dropped}）。';
      if (decoded == 1 || decoded % 60 == 0) {
        debugPrint(message);
      }
    } else if (status == FrameUploadStatus.uploaded) {
      message = '已解码 $decoded 帧，${frame.width}x${frame.height} $format；'
          '已写入双缓冲 NV12 纹理（已上传 ${_stats.uploaded}，'
          '丢弃 ${_stats.dropped}）。';
      if (decoded == 1 || decoded % 60 == 0) {
        debugPrint(message);
      }
    } else if (status == FrameUploadStatus.dropped) {
      message = '已解码 $decoded 帧，${frame.width}x${frame.height} $format；'
          '丢弃 ${_stats.dropped} 帧（上一帧仍在呈现，不排队等待）。';
    } else {
      message = '已解码 $decoded 帧，${frame.width}x${frame.height} $format；'
          '原生 D3D11 帧上传不可用（可能是 GDI fallback 或非 Windows 宿主）。';
    }

    _update(
      _state.copyWith(
        framesDecoded: _stats.decoded,
        framesUploaded: _stats.uploaded,
        framesDropped: _stats.dropped,
        frameWidth: frame.width,
        frameHeight: frame.height,
        status: CastStatus.running,
        message: message,
      ),
    );
  }

  /// Reports an asynchronous native present failure; the presenter recovers on
  /// the next frame, so this only refreshes the status message.
  void reportFrameSinkError(Object error) {
    if (_disposed) {
      return;
    }
    _stats.recordFailed();
    _update(
      _state.copyWith(
        message: '原生帧呈现失败：${_describeError(error)}'
            '（下一次上传会重新配置纹理）。',
      ),
    );
  }

  void _ensureStatsTimer() {
    if (_statsTimer != null || _disposed) {
      return;
    }
    _statsTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _sampleFrameStats(),
    );
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  /// Prints one line per second: decoded, uploaded and dropped frames in that
  /// window, plus the cumulative totals.
  void _sampleFrameStats() {
    if (_disposed) {
      _stopStatsTimer();
      return;
    }
    final window = _stats.sampleWindow();
    debugPrint(
      '[cast] 1s decoded=${window.decoded} uploaded=${window.uploaded} '
      'dropped=${window.dropped} | total decoded=${_stats.decoded} '
      'uploaded=${_stats.uploaded} dropped=${_stats.dropped} '
      'unavailable=${_stats.unavailable} failed=${_stats.failed}',
    );
    if (_state.status == CastStatus.running) {
      _update(
        _state.copyWith(
          framesDecoded: _stats.decoded,
          framesUploaded: _stats.uploaded,
          framesDropped: _stats.dropped,
          framesPerSecond: window.decoded,
        ),
      );
    }
  }

  void _handleSessionError(int generation, Object error) {
    if (_disposed || generation != _generation) {
      return;
    }
    _stopStatsTimer();
    _update(
      _state.copyWith(
        status: CastStatus.error,
        message: 'SCRC 数据链路异常：${_describeError(error)}$_pskHint',
      ),
    );
  }

  void _handleSessionClosed(int generation) {
    if (_disposed || _stopping || generation != _generation) {
      return;
    }
    _stopStatsTimer();
    if (_state.transportMode == CastTransportMode.wireless &&
        _wirelessTcpSerial != null) {
      unawaited(_recoverWireless(generation));
      return;
    }
    final direct = _state.transportMode == CastTransportMode.direct;
    _update(
      _state.copyWith(
        status: CastStatus.error,
        message: (direct
                ? '手机端服务端关闭了 SCRC 连接。请确认控制 App 状态仍为“运行中”，'
                    '并检查 /data/local/tmp/screencast-server.log 中的捕获错误；'
                    '桌面端链路本身已经建立。'
                : '服务端关闭了 SCRC 连接。'
                    '请检查 adb shell 日志中 DisplayManager / SurfaceControl / '
                    'MediaCodec 的捕获错误；桌面端链路本身已经建立。') +
            _pskHint,
      ),
    );
  }

  /// Extra hint appended to session errors while the record layer is active.
  /// A PSK mismatch shows up as a closed connection (GCM tag failure), so the
  /// message has to point at the key even though the socket error looks generic.
  String get _pskHint {
    final config = _activeConfig;
    if (config == null || config.pskHex.isEmpty) {
      return '';
    }
    return '（若手机端 --psk-hex 与桌面 PSK 不一致，会在此处断开；请核对两端密钥。）';
  }

  String _startingMessage(CastTransportConfig config) {
    switch (config.mode) {
      case CastTransportMode.wired:
        return '正在定位 ADB、推送 classes.dex、建立端口转发并启动 app_process……';
      case CastTransportMode.wireless:
        return '正在定位 ADB、推送 classes.dex，并以 0.0.0.0 启动 app_process……';
      case CastTransportMode.direct:
        return '正在连接 ${config.endpoint}（服务端由手机上的控制 App 启动）……';
    }
  }

  Future<void> _recoverWireless(int generation) async {
    if (_disposed || _stopping || _recovering || generation != _generation) {
      return;
    }
    final tcpSerial = _wirelessTcpSerial;
    if (tcpSerial == null) {
      return;
    }

    _recovering = true;
    final recoveryGeneration = ++_generation;
    _update(
      _state.copyWith(
        status: CastStatus.starting,
        message: 'USB 已断开或服务端连接中断，正在通过 ADB/TCP $tcpSerial '
            '重新启动局域网服务端……',
        controlLink: ControlLinkState.connecting,
      ),
    );

    final previous = _session;
    _session = null;
    try {
      await previous?.stop(restoreUsb: false);
    } catch (error) {
      debugPrint('Wireless recovery cleanup failed: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (_disposed || _stopping || recoveryGeneration != _generation) {
      _recovering = false;
      return;
    }

    final session = _sessionFactory?.call() ??
        CastSession(
          transport: _state.transport,
          existingTcpSerial: tcpSerial,
        );
    _session = session;
    try {
      final info = await session.start(
        onFrame: (DecodedFrame frame) =>
            _handleFrame(recoveryGeneration, frame),
        onError: (Object error, StackTrace stackTrace) =>
            _handleSessionError(recoveryGeneration, error),
        onClosed: () => _handleSessionClosed(recoveryGeneration),
        onControlState: (bool connected) =>
            _handleControlState(recoveryGeneration, connected),
      );
      if (_disposed || _stopping || recoveryGeneration != _generation) {
        await session.stop(restoreUsb: false);
        return;
      }
      _wirelessTcpSerial =
          info.transportMode == CastTransportMode.wireless ? info.serial : null;
      _update(
        _state.copyWith(
          status: CastStatus.running,
          message: '无线恢复成功：服务端已通过 ADB/TCP 重启，'
              'SCRC 目标 ${info.endpoint}，继续接收画面。',
          adbSerial: info.serial,
        ),
      );
    } catch (error) {
      if (!_disposed && recoveryGeneration == _generation) {
        _session = null;
        _update(
          _state.copyWith(
            status: CastStatus.error,
            message: '无线自动恢复失败：${_describeError(error)} '
                '请确认手机 Wi‑Fi 和 ADB/TCP $tcpSerial 仍可达。',
          ),
        );
      }
    } finally {
      _recovering = false;
    }
  }

  void _update(CastSessionState next) {
    if (_disposed) {
      return;
    }
    _state = next;
    notifyListeners();
  }

  String _describeError(Object error) {
    final text = error.toString();
    return text.length > 600 ? '${text.substring(0, 600)}…' : text;
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _stopStatsTimer();
    final session = _session;
    _session = null;
    if (session != null) {
      unawaited(session.stop());
    }
    super.dispose();
  }
}
