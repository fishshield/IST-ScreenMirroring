package com.example.screencast.server;

/**
 * Logs to both the adb shell stdout/stderr and logcat.
 *
 * <p>The adb shell stream is the primary developer-visible channel for this
 * app_process server. The android.util.Log calls are best-effort so the class
 * remains loadable in plain JVM unit checks.
 */
final class CaptureLog {
    private static final String TAG = "ScreenCastServer";

    private CaptureLog() {
    }

    static void info(String message) {
        System.out.println("[capture] " + message);
        try {
            android.util.Log.i(TAG, message);
        } catch (Throwable ignored) {
            // Not running under Android (for example a JVM syntax check).
        }
    }

    static void warn(String message) {
        System.out.println("[capture] WARN " + message);
        try {
            android.util.Log.w(TAG, message);
        } catch (Throwable ignored) {
            // ignore
        }
    }

    static void error(String message, Throwable error) {
        System.err.println("[capture] ERROR " + message);
        if (error != null) {
            error.printStackTrace(System.err);
        }
        try {
            android.util.Log.e(TAG, message, error);
        } catch (Throwable ignored) {
            // ignore
        }
    }
}
