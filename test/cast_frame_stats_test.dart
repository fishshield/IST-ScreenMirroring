import 'package:flutter_test/flutter_test.dart';
import 'package:screen_cast_demo/src/cast/cast_frame_stats.dart';
import 'package:screen_cast_demo/src/cast/cast_session_state.dart';

void main() {
  test('tracks cumulative decode and upload counters', () {
    final stats = CastFrameStats();
    for (var i = 0; i < 3; i++) {
      stats.recordDecoded();
      stats.recordUploaded();
    }
    stats.recordDropped();
    stats.recordUnavailable();
    stats.recordFailed();

    expect(stats.decoded, 3);
    expect(stats.uploaded, 3);
    expect(stats.dropped, 1);
    expect(stats.unavailable, 1);
    expect(stats.failed, 1);
  });

  test('sampleWindow reports per-second deltas and keeps the totals', () {
    final stats = CastFrameStats();
    for (var i = 0; i < 60; i++) {
      stats.recordDecoded();
      stats.recordUploaded();
    }
    stats.recordDropped();

    final first = stats.sampleWindow();
    expect(first.decoded, 60);
    expect(first.uploaded, 60);
    expect(first.dropped, 1);

    // Nothing new: the next window is empty while the totals stay.
    final second = stats.sampleWindow();
    expect(second.decoded, 0);
    expect(second.uploaded, 0);
    expect(second.dropped, 0);
    expect(stats.decoded, 60);
    expect(stats.dropped, 1);

    for (var i = 0; i < 30; i++) {
      stats.recordDecoded();
      stats.recordUploaded();
    }
    stats.recordDropped();
    final third = stats.sampleWindow();
    expect(third.decoded, 30);
    expect(third.uploaded, 30);
    expect(third.dropped, 1);
    expect(stats.decoded, 90);
  });

  test('reset clears totals and the sampling window', () {
    final stats = CastFrameStats()
      ..recordDecoded()
      ..recordUploaded()
      ..recordDropped();
    stats.sampleWindow();

    stats.reset();

    expect(stats.decoded, 0);
    expect(stats.uploaded, 0);
    expect(stats.dropped, 0);
    final window = stats.sampleWindow();
    expect(window.decoded, 0);
    expect(window.uploaded, 0);
    expect(window.dropped, 0);
  });

  test('clearFrameCounters resets the state counters only', () {
    const state = CastSessionState(
      status: CastStatus.running,
      message: 'running',
      port: 27183,
      framesDecoded: 120,
      framesUploaded: 118,
      framesDropped: 2,
      framesPerSecond: 60,
      frameWidth: 1280,
      frameHeight: 720,
    );

    final cleared = state.copyWith(clearFrameCounters: true);
    expect(cleared.framesDecoded, 0);
    expect(cleared.framesUploaded, 0);
    expect(cleared.framesDropped, 0);
    expect(cleared.framesPerSecond, 0);
    // Size and status survive the reset.
    expect(cleared.frameWidth, 1280);
    expect(cleared.frameHeight, 720);
    expect(cleared.status, CastStatus.running);

    final updated = state.copyWith(framesDropped: 7);
    expect(updated.framesDropped, 7);
    expect(updated.framesDecoded, 120);
    expect(updated.framesUploaded, 118);
  });

  test('the initial state starts every frame counter at zero', () {
    const state = CastSessionState.initial();
    expect(state.framesDecoded, 0);
    expect(state.framesUploaded, 0);
    expect(state.framesDropped, 0);
    expect(state.framesPerSecond, 0);
  });
}
