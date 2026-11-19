package com.example.screencast.server;

import android.os.SystemClock;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyEvent;
import android.view.MotionEvent;

import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.util.Locale;

/**
 * Turns control frames into Android input events.
 *
 * <p>Coordinate mapping has three stages, all logged before injection so the
 * mapping can be verified from the server log:
 *
 * <ol>
 *   <li>normalized (0.0-1.0) from the overlay window,</li>
 *   <li>video pixels: normalized multiplied by the encoder size, exactly the
 *       frame the desktop is looking at,</li>
 *   <li>display pixels: the video frame is a letterboxed fit of the mirrored
 *       display, so the bar padding is removed before scaling back to the
 *       display size. Injecting video pixels directly would land touches in the
 *       wrong part of the display.</li>
 * </ol>
 *
 * <p>The letterbox is not fixed: {@link InputMapping} is recomputed by the
 * capture backend every time it creates a virtual display, which covers
 * rotation and resolution changes.
 *
 * <p>Injection goes through the hidden {@code InputManager.injectInputEvent},
 * which needs the shell UID (INJECT_EVENTS) that this app_process already has.
 */
final class InputInjector {
    /** InputManager.INJECT_INPUT_EVENT_MODE_ASYNC. */
    private static final int INJECT_MODE_ASYNC = 0;

    private final InputMapping mapping;

    private final Object inputManager;
    private final Method injectMethod;

    private long downTime;

    /**
     * Pointer position for wheel injection. Android routes scroll events to the
     * window under the pointer, so the last touch-move coordinate is reused; the
     * display center is the fallback when no move arrived yet.
     */
    private float lastMoveDisplayX;
    private float lastMoveDisplayY;
    private boolean hasMoveSample;

    /**
     * Last display size/rotation seen before injecting. The capture backend only
     * refreshes the mapping when it creates a virtual display, which never
     * happens mid-session; polling here is what makes a rotation take effect
     * without reconnecting.
     */
    private DisplayMetadata.DisplayState lastDisplayState;

    InputInjector(InputMapping mapping) {
        this.mapping = mapping;

        final LetterboxGeometry initial = mapping.geometry();
        lastMoveDisplayX = initial.displayWidth() / 2f;
        lastMoveDisplayY = initial.displayHeight() / 2f;
        lastDisplayState = DisplayMetadata.currentState();

        Object manager = null;
        Method method = null;
        Throwable failure = null;
        try {
            final Class<?> managerClass =
                Class.forName("android.hardware.input.InputManager");
            final Method getInstance =
                managerClass.getDeclaredMethod("getInstance");
            getInstance.setAccessible(true);
            manager = getInstance.invoke(null);
            method = managerClass.getMethod(
                "injectInputEvent",
                InputEvent.class,
                int.class
            );
            method.setAccessible(true);
        } catch (Throwable error) {
            failure = unwrap(error);
        }
        if (method == null) {
            CaptureLog.warn(
                "InputManager.getInstance failed: " + describe(failure)
                    + "; trying the input service binder"
            );
            try {
                final Class<?> serviceManager =
                    Class.forName("android.os.ServiceManager");
                final Object binder = serviceManager
                    .getMethod("getService", String.class)
                    .invoke(null, "input");
                if (binder == null) {
                    throw new IllegalStateException("no input service binder");
                }
                final Class<?> binderClass =
                    Class.forName("android.os.IBinder");
                final Class<?> stub = Class.forName(
                    "android.hardware.input.IInputManager$Stub"
                );
                final Object remote = stub
                    .getMethod("asInterface", binderClass)
                    .invoke(null, binder);
                final Class<?> iface =
                    Class.forName("android.hardware.input.IInputManager");
                method = iface.getMethod(
                    "injectInputEvent",
                    InputEvent.class,
                    int.class
                );
                manager = remote;
            } catch (Throwable error) {
                CaptureLog.warn(
                    "IInputManager binder fallback failed: "
                        + describe(unwrap(error))
                );
            }
        }
        inputManager = manager;
        injectMethod = method;

        CaptureLog.info(
            "Input mapping: " + initial.describe()
                + " injection=" + (injectMethod == null ? "DISABLED" : "ready")
        );
    }

    void handle(int type, byte[] payload) {
        refreshLetterboxIfDisplayChanged();
        switch (type) {
            case ControlProtocol.TYPE_TOUCH_DOWN:
                handleTouch(MotionEvent.ACTION_DOWN, payload, "down");
                break;
            case ControlProtocol.TYPE_TOUCH_MOVE:
                handleTouch(MotionEvent.ACTION_MOVE, payload, "move");
                break;
            case ControlProtocol.TYPE_TOUCH_UP:
                handleTouch(MotionEvent.ACTION_UP, payload, "up");
                break;
            case ControlProtocol.TYPE_WHEEL:
                handleWheel(payload);
                break;
            case ControlProtocol.TYPE_KEY_DOWN:
                handleKey(KeyEvent.ACTION_DOWN, payload, "down");
                break;
            case ControlProtocol.TYPE_KEY_UP:
                handleKey(KeyEvent.ACTION_UP, payload, "up");
                break;
            default:
                CaptureLog.warn(
                    "control: unknown message type 0x"
                        + Integer.toHexString(type)
                );
                break;
        }
    }

    /**
     * Recomputes the letterbox when the display size or rotation changed since
     * the previous injected event.
     *
     * <p>{@code VirtualDisplayCaptureBackend} writes the mapping once per
     * virtual display, so a rotation performed inside a running session would
     * otherwise leave the touch mapping on the old aspect ratio until the viewer
     * reconnects. This poll runs before every injected frame.
     *
     * <p>The hover anchor is a display coordinate from the previous orientation,
     * so it is reset to the new display center when the geometry changes.
     */
    private void refreshLetterboxIfDisplayChanged() {
        final DisplayMetadata.DisplayState state = DisplayMetadata.currentState();
        if (state == null) {
            return;
        }
        if (state.sameAs(lastDisplayState)) {
            return;
        }
        final boolean firstSample = lastDisplayState == null;
        lastDisplayState = state;

        final boolean changed = mapping.update(
            mapping.videoWidth(),
            mapping.videoHeight(),
            state.width,
            state.height
        );
        final LetterboxGeometry box = mapping.geometry();
        CaptureLog.info(
            "Input letterbox updated (rotation): " + box.describe() + " "
                + state.describe()
                + (changed ? " (content box recomputed)" : " (same content box)")
                + (firstSample ? " [first sample]" : "")
        );

        lastMoveDisplayX = box.displayWidth() / 2f;
        lastMoveDisplayY = box.displayHeight() / 2f;
        hasMoveSample = false;
    }

    private void handleTouch(int action, byte[] payload, String label) {
        if (payload.length != ControlProtocol.TOUCH_PAYLOAD_BYTES) {
            CaptureLog.warn(
                "control: touch payload must be 8 bytes, got " + payload.length
            );
            return;
        }
        final ByteBuffer buffer = ByteBuffer.wrap(payload)
            .order(ByteOrder.BIG_ENDIAN);
        final float normalizedX = clamp01(buffer.getFloat());
        final float normalizedY = clamp01(buffer.getFloat());

        final LetterboxGeometry box = mapping.geometry();
        final double videoX = normalizedX * box.videoWidth();
        final double videoY = normalizedY * box.videoHeight();
        final int displayX = box.displayXForVideo(videoX);
        final int displayY = box.displayYForVideo(videoY);

        CaptureLog.info(
            String.format(
                Locale.ROOT,
                "[control] touch %s norm=(%.4f,%.4f) video=(%.1f,%.1f) "
                    + "display=(%d,%d) content=%dx%d offset=(%d,%d)",
                label,
                normalizedX,
                normalizedY,
                videoX,
                videoY,
                displayX,
                displayY,
                box.contentWidth(),
                box.contentHeight(),
                box.offsetX(),
                box.offsetY()
            )
        );

        final long now = SystemClock.uptimeMillis();
        if (action == MotionEvent.ACTION_DOWN || downTime == 0) {
            downTime = now;
        }

        // Wheel injection reuses the last 0x02 move sample, so only ACTION_MOVE
        // updates it; down/up would otherwise drag the scroll anchor to a stale
        // position.
        if (action == MotionEvent.ACTION_MOVE) {
            lastMoveDisplayX = displayX;
            lastMoveDisplayY = displayY;
            hasMoveSample = true;
        }

        final MotionEvent event = MotionEvent.obtain(
            action == MotionEvent.ACTION_DOWN ? now : downTime,
            now,
            action,
            displayX,
            displayY,
            0
        );
        event.setSource(InputDevice.SOURCE_TOUCHSCREEN);
        inject(event);
        event.recycle();
    }

    /**
     * Wheel injection.
     *
     * <p>Android does not deliver {@code ACTION_SCROLL} to an arbitrary window:
     * the event is routed by pointer position, and a mouse scroll without a
     * preceding hover has no position. The pointer is therefore positioned with
     * {@code ACTION_HOVER_MOVE} at the last touch-move coordinate first, then the
     * scroll is injected at the same point.
     */
    private void handleWheel(byte[] payload) {
        if (payload.length != ControlProtocol.WHEEL_PAYLOAD_BYTES) {
            CaptureLog.warn(
                "control: wheel payload must be 4 bytes, got " + payload.length
            );
            return;
        }
        final int windowsDelta = ByteBuffer.wrap(payload)
            .order(ByteOrder.BIG_ENDIAN)
            .getInt();
        final int axisVScroll = WheelMapping.axisVScrollForWindowsDelta(
            windowsDelta
        );

        CaptureLog.info(
            String.format(
                Locale.ROOT,
                "[control] wheel rawDelta=%d axisVScroll=%d hover=(%.0f,%.0f) "
                    + "hoverSource=%s",
                windowsDelta,
                axisVScroll,
                lastMoveDisplayX,
                lastMoveDisplayY,
                hasMoveSample ? "last-move" : "display-center"
            )
        );

        if (windowsDelta == 0) {
            CaptureLog.warn("control: wheel delta 0, nothing to inject");
            return;
        }

        // Position the mouse pointer, then scroll at the same coordinates.
        injectMouseEvent(
            MotionEvent.ACTION_HOVER_MOVE,
            lastMoveDisplayX,
            lastMoveDisplayY,
            0f,
            0f
        );
        injectMouseEvent(
            MotionEvent.ACTION_SCROLL,
            lastMoveDisplayX,
            lastMoveDisplayY,
            axisVScroll,
            0f
        );
    }

    private void handleKey(int action, byte[] payload, String label) {
        if (payload.length != ControlProtocol.KEY_PAYLOAD_BYTES) {
            CaptureLog.warn(
                "control: key payload must be 4 bytes, got " + payload.length
            );
            return;
        }
        final int keyCode = ByteBuffer.wrap(payload)
            .order(ByteOrder.BIG_ENDIAN)
            .getInt();
        CaptureLog.info(
            "[control] key " + label + " keycode=" + keyCode
        );
        final long now = SystemClock.uptimeMillis();
        final KeyEvent event = new KeyEvent(now, now, action, keyCode, 0);
        event.setSource(InputDevice.SOURCE_KEYBOARD);
        inject(event);
    }

    /**
     * Injects one mouse event at display coordinates with optional vertical and
     * horizontal scroll axes.
     *
     * <p>{@code MotionEvent} has no public {@code setAxisValue()}; axes are set
     * on {@link MotionEvent.PointerCoords} and passed through the multi-pointer
     * {@code obtain()} overload.
     */
    private void injectMouseEvent(
        int action,
        float displayX,
        float displayY,
        float verticalScroll,
        float horizontalScroll
    ) {
        final long now = SystemClock.uptimeMillis();

        final MotionEvent.PointerProperties properties =
            new MotionEvent.PointerProperties();
        properties.id = 0;
        properties.toolType = MotionEvent.TOOL_TYPE_MOUSE;

        final MotionEvent.PointerCoords coordinates =
            new MotionEvent.PointerCoords();
        coordinates.x = displayX;
        coordinates.y = displayY;
        // A hover has no button down, so it carries no pressure; a scroll is
        // delivered with the (virtual) button state of a wheel notch.
        coordinates.pressure = action == MotionEvent.ACTION_HOVER_MOVE ? 0f : 1f;
        coordinates.size = 1f;
        if (verticalScroll != 0f) {
            coordinates.setAxisValue(MotionEvent.AXIS_VSCROLL, verticalScroll);
        }
        if (horizontalScroll != 0f) {
            coordinates.setAxisValue(MotionEvent.AXIS_HSCROLL, horizontalScroll);
        }

        final MotionEvent event = MotionEvent.obtain(
            now,
            now,
            action,
            1,
            new MotionEvent.PointerProperties[] {properties},
            new MotionEvent.PointerCoords[] {coordinates},
            0,
            0,
            1f,
            1f,
            0,
            0,
            InputDevice.SOURCE_MOUSE,
            0
        );
        inject(event);
        event.recycle();
    }

    private void inject(InputEvent event) {
        if (injectMethod == null || inputManager == null) {
            return;
        }
        try {
            injectMethod.invoke(inputManager, event, INJECT_MODE_ASYNC);
        } catch (Throwable error) {
            final Throwable cause = error.getCause() == null ? error : error.getCause();
            CaptureLog.warn(
                "injectInputEvent failed: " + cause.getClass().getSimpleName()
                    + ": " + cause.getMessage()
            );
        }
    }

    private static Throwable unwrap(Throwable error) {
        if (error instanceof java.lang.reflect.InvocationTargetException
            && error.getCause() != null) {
            return error.getCause();
        }
        return error;
    }

    private static String describe(Throwable error) {
        if (error == null) {
            return "unknown";
        }
        final StringBuilder builder = new StringBuilder();
        Throwable current = error;
        for (int depth = 0; current != null && depth < 4; depth++) {
            if (depth > 0) {
                builder.append(" <- ");
            }
            builder.append(current.getClass().getSimpleName())
                .append(": ")
                .append(current.getMessage());
            current = current.getCause();
        }
        return builder.toString();
    }

    private static float clamp01(float value) {
        if (value < 0f) {
            return 0f;
        }
        if (value > 1f) {
            return 1f;
        }
        return value;
    }
}
