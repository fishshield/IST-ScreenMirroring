import 'dart:async';

import 'package:flutter/material.dart';

import '../cast/cast_controller.dart';
import '../cast/cast_session_state.dart';
import '../config/app_config.dart';
import '../control/control_message.dart';
import '../discovery/auto_connect.dart';
import '../discovery/cast_offer.dart';
import '../discovery/cast_offer_listener.dart';
import '../discovery/device_scanner.dart';
import '../transport/cast_transport.dart';
import '../windows/native_video_surface.dart';
import 'about_page.dart';
import 'widgets/control_panel.dart';
import 'widgets/status_badge.dart';

class CastHomePage extends StatefulWidget {
  const CastHomePage({super.key});

  @override
  State<CastHomePage> createState() => _CastHomePageState();
}

class _CastHomePageState extends State<CastHomePage> {
  static const bool _autoStart = bool.fromEnvironment('SCREEN_CAST_AUTOSTART');
  static const bool _autoWireless =
      bool.fromEnvironment('SCREEN_CAST_WIRELESS');
  static const bool _autoDirect = bool.fromEnvironment('SCREEN_CAST_DIRECT');
  static const String _autoHost = String.fromEnvironment('SCREEN_CAST_HOST');
  static const bool _autoConnect =
      bool.fromEnvironment('SCREEN_CAST_AUTOCONNECT');

  late final CastController _controller;
  final NativeVideoSurfaceController _nativeVideoController =
      NativeVideoSurfaceController();
  final GlobalKey _scrollViewportKey = GlobalKey();
  final GlobalKey _previewKey = GlobalKey();
  final ValueNotifier<int> _viewportRevision = ValueNotifier<int>(0);

  late final CastOfferListener _offerListener;
  late final AutoConnectPolicy _autoConnectPolicy;
  final AppConfigStore _configStore = AppConfigStore();
  final DeviceScanner _scanner = DeviceScanner();

  StreamSubscription<CastOfferEvent>? _offerSubscription;
  StreamSubscription<NativeInputEvent>? _inputSubscription;
  bool _discoveryStarted = false;
  bool _autoConnectSession = false;

  List<DiscoveredDevice> _devices = const [];
  bool _scanning = false;
  Timer? _autoScanTimer;
  DateTime _lastAutoConnectAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool _nativeInputEnabled = false;
  bool _trayConnected = false;
  DateTime _lastTrayPushAt = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    _controller = CastController(
      transportMode: _autoDirect
          ? CastTransportMode.direct
          : (_autoWireless
              ? CastTransportMode.wireless
              : CastTransportMode.wired),
      host: _autoHost,
      autoConnect: _autoConnect,
      frameSink: _nativeVideoController,
    );
    _controller.addListener(_syncNativeInput);
    _controller.addListener(_syncTrayStatus);
    _controller.addListener(_syncAutoConnectFailure);
    _nativeVideoController.onUploadError = _controller.reportFrameSinkError;
    // A finished interactive resize asks the decoder to re-measure the
    // letterbox rect; content probing is otherwise trigger driven.
    _nativeVideoController.onWindowResize = _controller.requestContentProbe;
    // The video window's close button hides it and keeps the session alive;
    // bring the controller UI back so it can be reopened from there.
    _nativeVideoController.onVideoVisibilityChanged = _handleVideoVisibility;
    _inputSubscription = _nativeVideoController.inputEvents.listen(
      _handleNativeInput,
    );

    _offerListener = CastOfferListener();
    _autoConnectPolicy = AutoConnectPolicy(
      target: _controller,
      onConnected: _handleAutoConnected,
      onFailed: (CastOffer offer, String message) => _showMainWindow(),
    );
    _offerSubscription = _offerListener.offers.listen(
      (CastOfferEvent event) =>
          unawaited(_autoConnectPolicy.handleOffer(event.offer)),
    );
    if (_autoConnect) {
      unawaited(_startDiscovery());
      _startAutoScan();
    }

    unawaited(_loadConfig());

    if (_autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_startAfterFirstFrame());
      });
    }
  }

  /// Native overlay -> control socket. The overlay only captures input while
  /// the control channel is connected.
  void _handleNativeInput(NativeInputEvent event) {
    final type = ControlMessageType.fromCode(event.type);
    if (type == null) {
      return;
    }
    final ControlMessage message;
    if (type.isTouch) {
      message = ControlMessage.touch(type, event.normalizedX, event.normalizedY);
    } else if (type == ControlMessageType.wheel) {
      message = ControlMessage.wheel(event.wheelDelta);
    } else {
      message = ControlMessage.key(type, event.keyCode);
    }
    _controller.sendControl(message);
  }

  void _syncNativeInput() {
    final enabled = _controller.state.controlLink.isConnected;
    if (enabled == _nativeInputEnabled) {
      return;
    }
    _nativeInputEnabled = enabled;
    unawaited(_nativeVideoController.setInputEnabled(enabled));
  }

  /// Mirrors the session state into the tray icon/tooltip.
  void _syncTrayStatus() {
    final state = _controller.state;
    final connected = state.status == CastStatus.running ||
        state.status == CastStatus.starting;
    final now = DateTime.now();
    final bool stateChanged = connected != _trayConnected;
    if (!stateChanged &&
        now.difference(_lastTrayPushAt) < const Duration(seconds: 1)) {
      return;
    }
    _trayConnected = connected;
    _lastTrayPushAt = now;
    unawaited(
      _nativeVideoController.updateStatus(
        connected: connected,
        width: state.frameWidth,
        height: state.frameHeight,
        fps: state.framesPerSecond,
      ),
    );
    unawaited(_refreshPresentFps());
  }

  Future<void> _refreshPresentFps() async {
    final fps = await _nativeVideoController.getPresentFps();
    if (fps != null && mounted) {
      _controller.setPresentFps(fps);
    }
  }

  /// Binds UDP/27185 the first time auto-connect is enabled (or at startup via
  /// `SCREEN_CAST_AUTOCONNECT=true`).
  Future<void> _startDiscovery() async {
    if (_discoveryStarted) {
      return;
    }
    _discoveryStarted = true;
    final listening = await _offerListener.start();
    if (!mounted) {
      return;
    }
    if (!listening) {
      _discoveryStarted = false;
      _controller.reportDiscovery(
        '无法监听 UDP ${CastOffer.discoveryPort}（端口被占用？）：自动连接不可用。',
        error: true,
      );
      return;
    }
    final subnets = _offerListener.subnets.subnets;
    _controller.reportDiscovery(
      '已监听 UDP ${CastOffer.discoveryPort}（${subnets.length} 个本地 IPv4 子网），'
      '等待手机广播…',
    );
  }

  Future<void> _loadConfig() async {
    final config = await _configStore.load();
    if (mounted) {
      _controller.setLimit60Fps(config.limit60Fps);
    }
  }

  void _handleLimit60FpsChanged(bool enabled) {
    _controller.setLimit60Fps(enabled);
    unawaited(_configStore.save(AppConfig(limit60Fps: enabled)));
  }

  void _handleAutoConnectChanged(bool enabled) {
    _controller.setAutoConnect(enabled);
    if (enabled) {
      unawaited(_startDiscovery());
      _startAutoScan();
      unawaited(_scan());
    } else {
      _autoScanTimer?.cancel();
      _autoScanTimer = null;
      _controller.reportDiscovery('自动连接已关闭。');
    }
  }

  /// Periodic scan while auto-connect is on, so a phone plugged into USB is
  /// picked up without pressing the scan button.
  void _startAutoScan() {
    _autoScanTimer?.cancel();
    _autoScanTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      unawaited(_scan(automatic: true));
    });
  }

  Future<void> _scan({bool automatic = false}) async {
    if (_scanning) {
      return;
    }
    // A periodic scan is only for finding a phone to connect to. Running a /24
    // sweep while a session is live adds Wi-Fi airtime and jitter for nothing;
    // the manual button still works.
    if (automatic) {
      final status = _controller.state.status;
      if (status == CastStatus.running ||
          status == CastStatus.starting ||
          status == CastStatus.stopping) {
        return;
      }
    }
    setState(() => _scanning = true);
    final devices = await _scanner.scan();
    if (!mounted) {
      return;
    }
    setState(() {
      _devices = devices;
      _scanning = false;
    });
    _maybeAutoConnect();
  }

  void _maybeAutoConnect() {
    final state = _controller.state;
    if (!state.autoConnect || _devices.isEmpty) {
      return;
    }
    if (state.status == CastStatus.running || state.status.isBusy) {
      return;
    }
    final now = DateTime.now();
    if (now.difference(_lastAutoConnectAt) < const Duration(seconds: 15)) {
      return;
    }
    _lastAutoConnectAt = now;
    unawaited(_connectDevice(_devices.first, auto: true));
  }

  Future<void> _connectDevice(DiscoveredDevice device, {bool auto = false}) async {
    _lastAutoConnectAt = DateTime.now();
    if (!auto) {
      _controller.reportDiscovery('正在连接 ${device.label} ……');
    }
    final connected = device.kind == DiscoveredDeviceKind.usb
        ? await _controller.connectToDevice(
            mode: CastTransportMode.wired,
            serial: device.serial ?? device.id,
            clearHost: true,
          )
        : device.serial != null
            // Wireless ADB (adb reports host:5555): the desktop starts the
            // server over ADB/TCP and then talks to the phone address.
            ? await _controller.connectToDevice(
                mode: CastTransportMode.wireless,
                host: device.host ?? device.id,
                serial: device.serial,
              )
            // Pure LAN entry from the port sweep: direct mode only.
            : await _controller.connectToDevice(
                mode: CastTransportMode.direct,
                host: device.host ?? device.id,
                clearSerial: true,
              );
    if (!mounted) {
      return;
    }
    if (connected) {
      unawaited(_nativeVideoController.showVideoWindow());
    }
  }

  void _handleAutoConnected(CastOffer offer) {
    _autoConnectSession = true;
    debugPrint('[discovery] auto-connected to ${offer.ip}');
    unawaited(_nativeVideoController.showVideoWindow());
  }

  void _showMainWindow() {
    unawaited(_nativeVideoController.showMainWindow());
  }

  void _handleVideoVisibility(bool visible) {
    if (visible) {
      return;
    }
    _showMainWindow();
  }

  /// An auto-connected session that fails later must surface its error instead
  /// of staying in the tray.
  void _syncAutoConnectFailure() {
    final state = _controller.state;
    if (state.status == CastStatus.error && _autoConnectSession) {
      _autoConnectSession = false;
      _showMainWindow();
    } else if (state.status == CastStatus.idle) {
      _autoConnectSession = false;
    }
  }

  Future<void> _startAfterFirstFrame() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (mounted) {
      await _controller.start();
    }
  }

  Future<void> _openAbout() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) => AboutPage(
          onShowVideoWindow: () =>
              unawaited(_nativeVideoController.showVideoWindow()),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _autoScanTimer?.cancel();
    _autoScanTimer = null;
    _controller.removeListener(_syncNativeInput);
    _controller.removeListener(_syncTrayStatus);
    _controller.removeListener(_syncAutoConnectFailure);
    unawaited(_inputSubscription?.cancel());
    _inputSubscription = null;
    unawaited(_offerSubscription?.cancel());
    _offerSubscription = null;
    unawaited(_offerListener.dispose());
    _controller.dispose();
    _nativeVideoController.dispose();
    _viewportRevision.dispose();
    super.dispose();
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    _viewportRevision.value++;
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (BuildContext context, Widget? child) {
        final state = _controller.state;
        return Scaffold(
          appBar: AppBar(
            titleSpacing: 24,
            title: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _BrandMark(),
                SizedBox(width: 12),
                Text(
                  'Screen Cast',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
            actions: [
              CastStatusBadge(status: state.status),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('open-about'),
                tooltip: '关于 / 架构',
                onPressed: _openAbout,
                icon: const Icon(Icons.info_outline_rounded),
              ),
              const SizedBox(width: 16),
            ],
          ),
          body: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: NotificationListener<ScrollNotification>(
                  onNotification: _handleScrollNotification,
                  child: SingleChildScrollView(
                    key: _scrollViewportKey,
                    padding: const EdgeInsets.fromLTRB(24, 20, 24, 36),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // The video window is a native top-level window; this
                        // widget stays mounted offstage to create it and to keep
                        // the frame upload/content-rect channel alive. It is
                        // laid out at a normal size so its placeholder never
                        // overflows, but it is not painted and takes no space.
                        Offstage(
                          offstage: true,
                          child: SizedBox(
                            key: _previewKey,
                            width: 800,
                            height: 600,
                            child: NativeVideoSurface(
                              clipViewportKey: _scrollViewportKey,
                              controller: _nativeVideoController,
                              revision: _viewportRevision,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        ControlPanel(
                          state: state,
                          devices: _devices,
                          scanning: _scanning,
                          onScan: () => unawaited(_scan()),
                          onConnect: (DiscoveredDevice device) =>
                              unawaited(_connectDevice(device)),
                          onStop: () => _controller.stop(),
                          onShowVideoWindow: () =>
                              unawaited(_nativeVideoController.showVideoWindow()),
                          onAutoConnectChanged: _handleAutoConnectChanged,
                          onLimit60FpsChanged: _handleLimit60FpsChanged,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _BrandMark extends StatelessWidget {
  const _BrandMark();

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      width: 30,
      height: 30,
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: colorScheme.primary.withValues(alpha: 0.35)),
      ),
      child: Icon(
        Icons.cast_rounded,
        size: 17,
        color: colorScheme.primary,
      ),
    );
  }
}
