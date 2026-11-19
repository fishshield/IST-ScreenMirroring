import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

/// H.264 NAL unit types used to resynchronise after packet loss.
abstract final class H264NalType {
  static const int idrSlice = 5;
  static const int sps = 7;
  static const int pps = 8;

  /// NAL type of a raw SCRC payload (no Annex-B start code).
  static int typeOf(Uint8List nal) => nal.isEmpty ? -1 : nal[0] & 0x1F;
}

/// Bounded handoff between the SCRC socket reader and the FFmpeg worker.
///
/// A slow decoder or a lossy network must not grow an unbounded backlog, but
/// dropping individual NALs corrupts every following P frame until the next
/// keyframe. Overflow therefore clears the whole queue and waits for an IDR:
///
/// ```text
/// [decode] queue overflow, dropped N NALs, waiting for IDR
/// [decode] IDR received, resumed decoding
/// ```
///
/// While waiting, everything except SPS/PPS/IDR is discarded (the next IDR is
/// replayed with the cached SPS/PPS in front of it). Nothing is cleared on the
/// presentation side: the renderer keeps showing its last frame, so the visible
/// result is a frozen picture instead of a corrupted one.
class NalDecodeQueue {
  NalDecodeQueue({
    this.capacity = 180,
    this.idrWaitTimeout = const Duration(seconds: 3),
  }) {
    if (capacity <= 0) {
      throw ArgumentError.value(capacity, 'capacity', 'Must be positive.');
    }
  }

  final int capacity;

  /// How long a wait for IDR runs before a diagnostic line is printed. Waiting
  /// continues after that: the server emits a keyframe every second, so a
  /// timeout means the server is unhealthy and a frozen picture is still better
  /// than corruption.
  final Duration idrWaitTimeout;

  final Queue<Uint8List> _items = Queue<Uint8List>();

  Completer<void>? _waiter;
  bool _closed = false;
  bool _waitingForIdr = false;
  Timer? _idrWaitTimer;
  int _dropped = 0;
  int _overflowEvents = 0;
  Uint8List? _pendingSps;
  Uint8List? _pendingPps;

  int get length => _items.length;

  /// NALs discarded because they belonged to the overflowed backlog.
  int get dropped => _dropped;

  /// How many overflow → wait-for-IDR episodes happened.
  int get overflowEvents => _overflowEvents;

  bool get waitingForIdr => _waitingForIdr;
  bool get isClosed => _closed;

  void add(Uint8List nal) {
    if (_closed || nal.isEmpty) {
      return;
    }
    final type = H264NalType.typeOf(nal);
    if (_waitingForIdr) {
      _absorbWhileWaiting(type, nal);
      return;
    }
    if (_items.length >= capacity) {
      _enterIdrWait();
      // The NAL that hit the limit belongs to the new stream as well.
      _absorbWhileWaiting(type, nal);
      return;
    }
    _items.add(nal);
    _wakeWaiter();
  }

  Future<Uint8List?> take() async {
    while (_items.isEmpty && !_closed) {
      final waiter = Completer<void>();
      _waiter = waiter;
      await waiter.future;
    }
    if (_items.isNotEmpty) {
      return _items.removeFirst();
    }
    return null;
  }

  void close() {
    if (_closed) {
      return;
    }
    _closed = true;
    _idrWaitTimer?.cancel();
    _idrWaitTimer = null;
    _wakeWaiter();
  }

  /// Discards the backlog and starts dropping until an IDR shows up.
  void _enterIdrWait() {
    final discarded = _items.length;
    _items.clear();
    _pendingSps = null;
    _pendingPps = null;
    _waitingForIdr = true;
    _overflowEvents++;
    _dropped += discarded;
    debugPrint(
      '[decode] queue overflow, dropped $discarded NALs, waiting for IDR',
    );
    _idrWaitTimer?.cancel();
    _idrWaitTimer = Timer(idrWaitTimeout, () {
      if (_waitingForIdr && !_closed) {
        debugPrint(
          '[decode] IDR wait timeout (${idrWaitTimeout.inSeconds}s), '
          'still waiting',
        );
      }
    });
  }

  /// Keeps SPS/PPS, resumes on the first IDR slice, drops everything else.
  void _absorbWhileWaiting(int type, Uint8List nal) {
    if (type == H264NalType.sps) {
      _pendingSps = nal;
      return;
    }
    if (type == H264NalType.pps) {
      _pendingPps = nal;
      return;
    }
    if (type != H264NalType.idrSlice) {
      return;
    }

    final sps = _pendingSps;
    final pps = _pendingPps;
    _pendingSps = null;
    _pendingPps = null;
    _waitingForIdr = false;
    _idrWaitTimer?.cancel();
    _idrWaitTimer = null;
    if (sps != null) {
      _items.add(sps);
    }
    if (pps != null) {
      _items.add(pps);
    }
    _items.add(nal);
    debugPrint('[decode] IDR received, resumed decoding');
    _wakeWaiter();
  }

  void _wakeWaiter() {
    final waiter = _waiter;
    _waiter = null;
    if (waiter != null && !waiter.isCompleted) {
      waiter.complete();
    }
  }
}
