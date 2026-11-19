package com.example.screencast.server;

/**
 * Windows wheel delta to Android scroll axis conversion.
 *
 * <p>{@code WM_MOUSEWHEEL} reports {@code GET_WHEEL_DELTA_WPARAM} in multiples
 * of {@code WHEEL_DELTA} (120), positive when the wheel rotates away from the
 * user — the content should scroll up / backwards.
 *
 * <p>On the verified OPPO Android 14 device the axis value is passed through
 * unchanged: {@code AXIS_VSCROLL = +120} scrolls a list up and {@code -120}
 * scrolls it down, i.e. Android uses the same sign convention as Windows here.
 * This was measured by injecting both directions into the Settings network list
 * and comparing the visible items before/after (see README 验证状态); the earlier
 * negated mapping made the wheel scroll backwards.
 *
 * <p>Plain Java so {@code CaptureCoreCheck} can unit-check the conversion.
 */
final class WheelMapping {
    /** Windows delivers one wheel notch as this value. */
    static final int WHEEL_DELTA = 120;

    private WheelMapping() {
    }

    /**
     * @param windowsDelta raw {@code GET_WHEEL_DELTA_WPARAM} value, positive =
     *     wheel rotated away from the user (scroll up)
     * @return the value to pass to {@code PointerCoords.setAxisValue(
     *     MotionEvent.AXIS_VSCROLL, ...)}
     */
    static int axisVScrollForWindowsDelta(int windowsDelta) {
        // Measured on a real device: Android's AXIS_VSCROLL uses the same sign
        // as the Windows wheel delta, so no flip is applied. The value is kept
        // as-is (sub-notch precision included) instead of being rounded.
        return windowsDelta;
    }
}
