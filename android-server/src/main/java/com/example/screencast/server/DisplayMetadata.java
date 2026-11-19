package com.example.screencast.server;

import android.graphics.Point;
import android.view.Display;

import java.lang.reflect.Field;
import java.lang.reflect.Method;

/**
 * Best-effort metadata for the default display.
 *
 * <p>Two consumers need it:
 * <ul>
 *   <li>the SurfaceControl fallback sets the display projection and layer stack
 *       from the logical display size,</li>
 *   <li>input injection needs the real (physical) display size to recompute the
 *       video letterbox every time a virtual display is created, which is what
 *       makes rotation map correctly.</li>
 * </ul>
 *
 * <p>Everything is reflective because app_process has no Context; every lookup
 * degrades to a logged fallback instead of failing the session.
 */
final class DisplayMetadata {
    final int width;
    final int height;
    final int layerStack;
    final int rotation;

    private DisplayMetadata(int width, int height, int layerStack, int rotation) {
        this.width = width;
        this.height = height;
        this.layerStack = layerStack;
        this.rotation = rotation;
    }

    static DisplayMetadata load(ServerOptions options) {
        try {
            final Object info = defaultDisplayInfo();
            final int width = readInt(info, "logicalWidth");
            final int height = readInt(info, "logicalHeight");
            final int layerStack = readInt(info, "layerStack");
            final int rotation = readInt(info, "rotation");
            if (width <= 0 || height <= 0) {
                throw new IllegalStateException(
                    "Invalid display size " + width + "x" + height
                );
            }
            return new DisplayMetadata(width, height, layerStack, rotation);
        } catch (Exception error) {
            CaptureLog.warn(
                "Could not read DisplayInfo via DisplayManagerGlobal: "
                    + describe(error)
            );
            return new DisplayMetadata(
                options.width(),
                options.height(),
                0,
                0
            );
        }
    }

    /**
     * Real (physical) source display size, the same numbers
     * {@code Display.getRealSize(Point)} reports.
     *
     * <p>This is what the encoder letterboxes: the source aspect ratio, not the
     * encoder size, decides where the video content sits.
     *
     * <p>Fallback order, newest to oldest shape of the hidden API:
     * {@code DisplayInfo.getRealSize(Point)} (what {@code Display.getRealSize}
     * delegates to) → {@code getNaturalWidth/getNaturalHeight} (physical mode
     * size) → {@code mode.getPhysicalWidth/Height} → logical size → encoder
     * size. Each step is logged so a wrong aspect ratio on some OEM build can be
     * diagnosed from the server log.
     */
    static int[] realSize(ServerOptions options) {
        try {
            final Object info = defaultDisplayInfo();
            final int[] real = readRealSize(info, true);
            if (real != null) {
                return orientToLogicalDisplay(info, real);
            }
        } catch (Exception error) {
            CaptureLog.warn(
                "Could not read the real display size: " + describe(error)
            );
        }
        final DisplayMetadata logical = load(options);
        CaptureLog.warn(
            "Falling back to the logical display size " + logical.width + "x"
                + logical.height + " for the input letterbox"
        );
        return new int[] {logical.width, logical.height};
    }

    /**
     * Real display size plus rotation sampled at one instant.
     *
     * <p>Cheap and silent on purpose: {@code InputInjector} polls this before
     * every injected event so a mid-session rotation is noticed without
     * reconnecting, and a failing hidden API must not flood the log.
     */
    static final class DisplayState {
        final int width;
        final int height;
        final int rotation;

        DisplayState(int width, int height, int rotation) {
            this.width = width;
            this.height = height;
            this.rotation = rotation;
        }

        boolean sameAs(DisplayState other) {
            return other != null
                && other.width == width
                && other.height == height
                && other.rotation == rotation;
        }

        String describe() {
            return "display=" + width + "x" + height
                + " rotation=" + rotation;
        }
    }

    /**
     * Reads the current real display size and rotation, oriented to the logical
     * display, without logging.
     *
     * @return null when the hidden display API is unavailable on this build
     */
    static DisplayState currentState() {
        try {
            final Object info = defaultDisplayInfo();
            final int[] real = readRealSize(info, false);
            if (real == null) {
                return null;
            }
            final int rotation = readInt(info, "rotation");
            int logicalWidth = 0;
            int logicalHeight = 0;
            try {
                logicalWidth = readInt(info, "logicalWidth");
                logicalHeight = readInt(info, "logicalHeight");
            } catch (Exception ignored) {
                // Orientation alignment is best-effort; the raw size still
                // changes with rotation on most builds.
            }
            final int[] oriented = LetterboxGeometry.orient(
                real[0],
                real[1],
                logicalWidth,
                logicalHeight
            );
            return new DisplayState(oriented[0], oriented[1], rotation);
        } catch (Exception error) {
            return null;
        }
    }

    /**
     * Aligns the real panel size with the mirrored (logical) orientation.
     *
     * <p>{@code Display.getRealSize()} is reported in the panel's natural
     * orientation, while the mirrored frame follows the current logical
     * orientation. Without this the letterbox would be computed for the wrong
     * axis after a rotation (or even on the unrotated reference device, whose
     * panel is portrait while the mirrored logical display is landscape).
     */
    private static int[] orientToLogicalDisplay(Object info, int[] real) {
        int logicalWidth = 0;
        int logicalHeight = 0;
        try {
            logicalWidth = readInt(info, "logicalWidth");
            logicalHeight = readInt(info, "logicalHeight");
        } catch (Exception error) {
            CaptureLog.warn(
                "Could not read the logical display size for orientation: "
                    + describe(error)
            );
        }
        final int[] oriented = LetterboxGeometry.orient(
            real[0],
            real[1],
            logicalWidth,
            logicalHeight
        );
        if (oriented[0] != real[0] || oriented[1] != real[1]) {
            CaptureLog.info(
                "Real display size " + real[0] + "x" + real[1]
                    + " rotated to logical orientation " + oriented[0] + "x"
                    + oriented[1] + " (logical " + logicalWidth + "x"
                    + logicalHeight + ")"
            );
        } else {
            CaptureLog.info(
                "Real display size " + oriented[0] + "x" + oriented[1]
                    + " already matches logical orientation"
            );
        }
        return oriented;
    }

    private static Object defaultDisplayInfo() throws Exception {
        final Class<?> globalClass = Class.forName(
            "android.hardware.display.DisplayManagerGlobal"
        );
        final Method getInstance = globalClass.getDeclaredMethod("getInstance");
        getInstance.setAccessible(true);
        final Object global = getInstance.invoke(null);
        if (global == null) {
            throw new IllegalStateException(
                "DisplayManagerGlobal.getInstance() returned null"
            );
        }

        final Method getDisplayInfo = globalClass.getMethod(
            "getDisplayInfo",
            int.class
        );
        final Object info = getDisplayInfo.invoke(global, Display.DEFAULT_DISPLAY);
        if (info == null) {
            throw new IllegalStateException("No DisplayInfo for default display");
        }
        return info;
    }

    private static int[] readRealSize(Object info, boolean verbose) {
        // Display.getRealSize(Point) is a thin wrapper around this call.
        try {
            final Point point = new Point();
            info.getClass().getMethod("getRealSize", Point.class).invoke(info, point);
            if (point.x > 0 && point.y > 0) {
                if (verbose) {
                    CaptureLog.info(
                        "Source display real size (Display.getRealSize): "
                            + point.x + "x" + point.y
                    );
                }
                return new int[] {point.x, point.y};
            }
        } catch (Exception error) {
            if (verbose) {
                CaptureLog.warn(
                    "DisplayInfo.getRealSize(Point) unavailable: " + describe(error)
                );
            }
        }

        // Physical mode size; equals getRealSize() at rotation 0.
        try {
            final int width = (Integer) info.getClass()
                .getMethod("getNaturalWidth")
                .invoke(info);
            final int height = (Integer) info.getClass()
                .getMethod("getNaturalHeight")
                .invoke(info);
            if (width > 0 && height > 0) {
                if (verbose) {
                    CaptureLog.info(
                        "Source display real size (natural mode): "
                            + width + "x" + height
                    );
                }
                return new int[] {width, height};
            }
        } catch (Exception error) {
            if (verbose) {
                CaptureLog.warn(
                    "DisplayInfo.getNaturalWidth/Height unavailable: "
                        + describe(error)
                );
            }
        }

        // Older shapes expose the active mode object instead.
        try {
            final Field modeField = info.getClass().getDeclaredField("mode");
            modeField.setAccessible(true);
            final Object mode = modeField.get(info);
            if (mode != null) {
                final int width = (Integer) mode.getClass()
                    .getMethod("getPhysicalWidth")
                    .invoke(mode);
                final int height = (Integer) mode.getClass()
                    .getMethod("getPhysicalHeight")
                    .invoke(mode);
                if (width > 0 && height > 0) {
                    if (verbose) {
                        CaptureLog.info(
                            "Source display real size (mode): " + width + "x"
                                + height
                        );
                    }
                    return new int[] {width, height};
                }
            }
        } catch (Exception error) {
            if (verbose) {
                CaptureLog.warn(
                    "DisplayInfo.mode physical size unavailable: " + describe(error)
                );
            }
        }
        return null;
    }

    private static int readInt(Object target, String fieldName) throws Exception {
        final Field field = target.getClass().getDeclaredField(fieldName);
        field.setAccessible(true);
        return field.getInt(target);
    }

    private static String describe(Exception error) {
        final Throwable cause = error.getCause() == null ? error : error.getCause();
        return cause.getClass().getSimpleName() + ": " + cause.getMessage();
    }

    @Override
    public String toString() {
        return width + "x" + height + " layerStack=" + layerStack + " rotation=" + rotation;
    }
}
