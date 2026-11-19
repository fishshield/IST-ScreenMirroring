package com.example.screencast.server;

/**
 * Wire constants for the control channel.
 *
 * <p>Kept in sync with {@code lib/src/control/control_message.dart}. The frame
 * is {@code 1 byte type + 4 byte big-endian payload length + payload}; the
 * video stream keeps using SCRC on the other port and is not touched.
 */
final class ControlProtocol {
    static final int TYPE_TOUCH_DOWN = 0x01;
    static final int TYPE_TOUCH_MOVE = 0x02;
    static final int TYPE_TOUCH_UP = 0x03;
    static final int TYPE_WHEEL = 0x04;
    static final int TYPE_KEY_DOWN = 0x05;
    static final int TYPE_KEY_UP = 0x06;

    /**
     * Controller-app → server only: asks the server to exit.
     *
     * <p>This is the stop path that does not need Shizuku. The capture process
     * runs as the shell user, so the app cannot kill it directly, but it can ask
     * it to shut down on the same control channel it already uses for input.
     * Older servers ignore unknown types, so the frame is backward compatible.
     */
    static final int TYPE_SHUTDOWN = 0x10;
    static final int SHUTDOWN_PAYLOAD_BYTES = 0;

    static final int HEADER_BYTES = 5;
    static final int MAX_PAYLOAD_BYTES = 64;
    static final int TOUCH_PAYLOAD_BYTES = 8;
    static final int KEY_PAYLOAD_BYTES = 4;
    static final int WHEEL_PAYLOAD_BYTES = 4;

    private ControlProtocol() {
    }
}
