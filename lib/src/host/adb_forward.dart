import 'package:flutter/foundation.dart';

import '../transport/cast_transport.dart';

/// One `adb forward tcp:<local> tcp:<remote>` tunnel owned by a session.
@immutable
class AdbForward {
  const AdbForward(this.localPort, this.remotePort);

  /// Loopback tunnel where the host and the device use the same port.
  const AdbForward.samePort(int port)
      : localPort = port,
        remotePort = port;

  final int localPort;
  final int remotePort;

  String get localSpec => 'tcp:$localPort';
  String get remoteSpec => 'tcp:$remotePort';

  /// Human-readable tunnel description, e.g. `tcp:27184 -> tcp:27184`.
  String get label => '$localSpec -> $remoteSpec';

  @override
  bool operator ==(Object other) =>
      other is AdbForward &&
      other.localPort == localPort &&
      other.remotePort == remotePort;

  @override
  int get hashCode => Object.hash(localPort, remotePort);

  @override
  String toString() => 'AdbForward($label)';
}

/// A tunnel that failed to install or remove.
@immutable
class AdbForwardFailure {
  const AdbForwardFailure(this.forward, this.error);

  final AdbForward forward;
  final Object error;

  @override
  String toString() => '${forward.label}: $error';
}

/// Outcome of one [AdbForwards.install] or [AdbForwards.remove] pass.
///
/// Both directions are best-effort per tunnel: the loop never stops at the
/// first failure, so one broken tunnel cannot leave the other one behind.
@immutable
class AdbForwardResult {
  const AdbForwardResult({required this.done, required this.failures});

  /// Tunnels the command succeeded for.
  final List<AdbForward> done;

  /// Tunnels that failed, with the original error for diagnostics.
  final List<AdbForwardFailure> failures;

  bool get isComplete => failures.isEmpty;

  bool contains(AdbForward forward) => done.contains(forward);

  @override
  String toString() => 'AdbForwardResult(done: ${done.length}, '
      'failures: ${failures.length})';
}

/// Runs one adb invocation and throws when it fails.
typedef AdbForwardRunner = Future<void> Function(List<String> arguments);

/// The `adb forward` tunnels a wired session owns.
///
/// Wired mode needs two independent tunnels: [CastTransportConfig.port] for the
/// SCRC video stream and [CastTransportConfig.controlPort] for input injection.
/// They are handled through one list so:
///
///   * installing a later tunnel never skips an earlier one,
///   * cleanup is idempotent — every tunnel is attempted even when one
///     `--remove` fails (a already-removed tunnel is a normal no-op), so a
///     failure on 27184 can never leave 27183 behind.
@immutable
class AdbForwards {
  AdbForwards({required this.serial, required List<AdbForward> tunnels})
      : tunnels = List<AdbForward>.unmodifiable(tunnels);

  /// Plan for a transport mode: two tunnels for wired, none otherwise.
  factory AdbForwards.forConfig({
    required String serial,
    required CastTransportConfig transport,
  }) {
    if (!transport.usesAdbForward) {
      return AdbForwards(serial: serial, tunnels: const <AdbForward>[]);
    }
    return AdbForwards(
      serial: serial,
      tunnels: <AdbForward>[
        AdbForward.samePort(transport.port),
        AdbForward.samePort(transport.controlPort),
      ],
    );
  }

  final String serial;
  final List<AdbForward> tunnels;

  bool get isEmpty => tunnels.isEmpty;

  bool get isNotEmpty => tunnels.isNotEmpty;

  /// The SCRC video tunnel; the session is unusable without it.
  AdbForward? get videoTunnel => tunnels.isEmpty ? null : tunnels.first;

  /// The input-injection tunnel; best-effort, video keeps working without it.
  AdbForward? get controlTunnel => tunnels.length < 2 ? null : tunnels[1];

  List<String> installArguments(AdbForward forward) => <String>[
        '-s',
        serial,
        'forward',
        forward.localSpec,
        forward.remoteSpec,
      ];

  List<String> removeArguments(AdbForward forward) => <String>[
        '-s',
        serial,
        'forward',
        '--remove',
        forward.localSpec,
      ];

  /// Installs every tunnel, collecting failures instead of aborting.
  Future<AdbForwardResult> install(AdbForwardRunner run) =>
      _runEach(run, installArguments);

  /// Removes every tunnel. Safe to call twice; a missing tunnel only shows up
  /// as a failure entry while the remaining tunnels are still removed.
  Future<AdbForwardResult> remove(AdbForwardRunner run) =>
      _runEach(run, removeArguments);

  Future<AdbForwardResult> _runEach(
    AdbForwardRunner run,
    List<String> Function(AdbForward forward) arguments,
  ) async {
    final done = <AdbForward>[];
    final failures = <AdbForwardFailure>[];
    for (final forward in tunnels) {
      try {
        await run(arguments(forward));
        done.add(forward);
      } catch (error) {
        // Keep iterating: a single failure must not skip the other tunnel.
        failures.add(AdbForwardFailure(forward, error));
      }
    }
    return AdbForwardResult(
      done: List<AdbForward>.unmodifiable(done),
      failures: List<AdbForwardFailure>.unmodifiable(failures),
    );
  }
}
