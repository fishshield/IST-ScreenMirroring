import '../cast/cast_session_state.dart';
import 'cast_offer.dart';

/// PSK the desktop must use for [offer].
///
/// An offer that says `pskRequired=false` describes a plaintext server, so a
/// key configured for manual sessions must not be sent (it would only make the
/// record layer fail to authenticate). A required key is used as configured;
/// the caller reports the "no key configured" case before connecting.
String pskForOffer({required CastOffer offer, required String configuredPsk}) {
  return offer.pskRequired ? configuredPsk : '';
}

/// The small surface [AutoConnectPolicy] needs from the session owner.
///
/// [CastController] implements it; tests use a fake so the policy (cooldown,
/// PSK rules, failed-connect reporting) can be verified without sockets or a
/// real decoder.
abstract interface class AutoConnectTarget {
  /// Whether the user enabled the "自动连接" switch.
  bool get autoConnectEnabled;

  /// Current session status; offers are ignored while running or busy.
  CastStatus get castStatus;

  /// Hex PSK currently configured in the UI.
  String get pskHex;

  /// Human readable last session message, used in failure reports.
  String get statusMessage;

  /// Switches to direct mode for [offer] and starts the session.
  /// Returns true only when the session reached [CastStatus.running].
  Future<bool> connectToOffer(CastOffer offer);

  /// Publishes a discovery line to the UI.
  void reportDiscovery(String message, {bool error = false});
}

/// Turns validated LAN offers into sessions.
///
/// Rules (see README "一键投送"):
///
/// * only when the "自动连接" switch is on and no session is running;
/// * per-address retry cooldown, so a 5-pack broadcast triggers one attempt;
/// * `pskRequired=true` without a configured key is reported as an error
///   instead of being tried and failing cryptically;
/// * `pskRequired=false` connects without a PSK even if the UI has one, which
///   is what the phone's plaintext server expects.
class AutoConnectPolicy {
  AutoConnectPolicy({
    required this.target,
    this.onConnected,
    this.onFailed,
    this.retryCooldown = const Duration(seconds: 8),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final AutoConnectTarget target;

  /// Called after the session reached "running"; the host window shows itself.
  final void Function(CastOffer offer)? onConnected;

  /// Called with the user-visible reason on every failed attempt.
  final void Function(CastOffer offer, String message)? onFailed;

  /// Minimum gap between two attempts for the same phone address. The phone
  /// repeats its offer every second for five seconds; all five land here.
  final Duration retryCooldown;

  final DateTime Function() _clock;
  final Map<String, DateTime> _lastAttempt = <String, DateTime>{};

  /// Offers seen while the switch is off; only used to explain the UI state.
  CastOffer? get lastSeenOffer => _lastSeen;
  CastOffer? _lastSeen;

  Future<void> handleOffer(CastOffer offer) async {
    _lastSeen = offer;
    final status = target.castStatus;
    if (status == CastStatus.running) {
      // Already mirroring; a repeated broadcast must not disturb the session.
      return;
    }
    if (!target.autoConnectEnabled) {
      target.reportDiscovery('已发现 ${offer.ip}（自动连接未开启）');
      return;
    }
    if (status.isBusy) {
      return;
    }

    final now = _clock();
    final last = _lastAttempt[offer.ip];
    if (last != null && now.difference(last) < retryCooldown) {
      return;
    }

    if (offer.pskRequired && target.pskHex.trim().isEmpty) {
      _lastAttempt[offer.ip] = now;
      final message = '${offer.ip} 要求 PSK，但桌面端没有配置预共享密钥。'
          '请在“预共享密钥 PSK”填入与手机服务端 --psk-hex 一致的 hex。';
      target.reportDiscovery(message, error: true);
      onFailed?.call(offer, message);
      return;
    }

    _lastAttempt[offer.ip] = now;
    target.reportDiscovery('正在自动连接 ${offer.ip}:${offer.videoPort} …');
    final connected = await target.connectToOffer(offer);
    if (connected) {
      target.reportDiscovery('已自动连接 ${offer.ip}:${offer.videoPort}');
      onConnected?.call(offer);
      return;
    }

    final message = '自动连接 ${offer.ip} 失败：${target.statusMessage}';
    target.reportDiscovery(message, error: true);
    onFailed?.call(offer, message);
  }
}
