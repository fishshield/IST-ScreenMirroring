package com.example.screencast.server;

/**
 * Transport (bind address/port) and video-encoder options supplied on the
 * app_process command line.
 */
public final class ServerOptions {
    public static final int DEFAULT_PORT = 27183;
    public static final int DEFAULT_CONTROL_PORT = 27184;
    public static final String DEFAULT_BIND_ADDRESS = "127.0.0.1";
    public static final int MAX_PAYLOAD_BYTES = 16 * 1024 * 1024;
    public static final int DEFAULT_WIDTH = 1280;
    public static final int DEFAULT_HEIGHT = 720;
    public static final int DEFAULT_BIT_RATE = 8_000_000;
    public static final int DEFAULT_FRAME_RATE = 60;
    public static final int DEFAULT_I_FRAME_INTERVAL = 1;
    public static final String DEFAULT_DISPLAY_BACKEND = "auto";

    /** 0 = no frame-rate hint; the encoder keeps producing at the panel rate. */
    public static final int DEFAULT_TARGET_FPS = 0;
    public static final int MAX_TARGET_FPS = 240;

    private final int port;
    private final int controlPort;
    private final String bindAddress;
    private final String pskHex;
    private final int maxPayloadBytes;
    private final int width;
    private final int height;
    private final int bitRate;
    private final int frameRate;
    private final int iFrameIntervalSeconds;
    private final String displayBackend;
    private final int targetFps;

    private ServerOptions(
        int port,
        int controlPort,
        String bindAddress,
        String pskHex,
        int maxPayloadBytes,
        int width,
        int height,
        int bitRate,
        int frameRate,
        int iFrameIntervalSeconds,
        String displayBackend,
        int targetFps
    ) {
        this.port = port;
        this.controlPort = controlPort;
        this.bindAddress = bindAddress;
        this.pskHex = pskHex;
        this.maxPayloadBytes = maxPayloadBytes;
        this.width = width;
        this.height = height;
        this.bitRate = bitRate;
        this.frameRate = frameRate;
        this.iFrameIntervalSeconds = iFrameIntervalSeconds;
        this.displayBackend = displayBackend;
        this.targetFps = targetFps;
    }

    public int port() {
        return port;
    }

    public int controlPort() {
        return controlPort;
    }

    /** Hex pre-shared key for the record layer; empty means plaintext. */
    public String pskHex() {
        return pskHex;
    }

    public String bindAddress() {
        return bindAddress;
    }

    public int maxPayloadBytes() {
        return maxPayloadBytes;
    }

    public int width() {
        return width;
    }

    public int height() {
        return height;
    }

    public int bitRate() {
        return bitRate;
    }

    public int frameRate() {
        return frameRate;
    }

    public int iFrameIntervalSeconds() {
        return iFrameIntervalSeconds;
    }

    public String displayBackend() {
        return displayBackend;
    }

    /**
     * Requested capture frame rate, or 0 for "no hint".
     *
     * <p>The server asks the display stack for this rate through
     * {@code Surface.setFrameRate}; it never drops frames itself (dropping P
     * frames corrupts the H.264 reference chain). A ROM may ignore the hint.
     */
    public int targetFps() {
        return targetFps;
    }

    public static ServerOptions parse(String[] args) {
        int port = DEFAULT_PORT;
        int controlPort = DEFAULT_CONTROL_PORT;
        String bindAddress = DEFAULT_BIND_ADDRESS;
        String pskHex = "";
        int maxPayloadBytes = MAX_PAYLOAD_BYTES;
        int width = DEFAULT_WIDTH;
        int height = DEFAULT_HEIGHT;
        int bitRate = DEFAULT_BIT_RATE;
        int frameRate = DEFAULT_FRAME_RATE;
        int iFrameInterval = DEFAULT_I_FRAME_INTERVAL;
        String displayBackend = DEFAULT_DISPLAY_BACKEND;
        int targetFps = DEFAULT_TARGET_FPS;

        for (String arg : args) {
            if (arg.startsWith("--port=")) {
                port = parsePositiveInt(arg, "--port=");
            } else if (arg.startsWith("--control-port=")) {
                controlPort = parsePositiveInt(arg, "--control-port=");
            } else if (arg.startsWith("--bind-address=")) {
                bindAddress = arg.substring("--bind-address=".length()).trim();
            } else if (arg.startsWith("--psk-hex=")) {
                pskHex = arg.substring("--psk-hex=".length()).trim();
            } else if (arg.startsWith("--max-payload-bytes=")) {
                maxPayloadBytes = parsePositiveInt(arg, "--max-payload-bytes=");
            } else if (arg.startsWith("--width=")) {
                width = parsePositiveInt(arg, "--width=");
            } else if (arg.startsWith("--height=")) {
                height = parsePositiveInt(arg, "--height=");
            } else if (arg.startsWith("--bit-rate=")) {
                bitRate = parsePositiveInt(arg, "--bit-rate=");
            } else if (arg.startsWith("--frame-rate=")) {
                frameRate = parsePositiveInt(arg, "--frame-rate=");
            } else if (arg.startsWith("--i-frame-interval=")) {
                iFrameInterval = parsePositiveInt(arg, "--i-frame-interval=");
            } else if (arg.startsWith("--display-backend=")) {
                displayBackend = arg.substring("--display-backend=".length());
            } else if (arg.startsWith("--target-fps=")) {
                targetFps = parseNonNegativeInt(arg, "--target-fps=");
            } else {
                throw new IllegalArgumentException("unknown option: " + arg);
            }
        }

        if (port < 1024 || port > 65535) {
            throw new IllegalArgumentException("port must be between 1024 and 65535");
        }
        if (controlPort < 1024 || controlPort > 65535) {
            throw new IllegalArgumentException(
                "control-port must be between 1024 and 65535"
            );
        }
        if (controlPort == port) {
            throw new IllegalArgumentException(
                "control-port must differ from port"
            );
        }
        final String pskProblem = PskCipher.validateHex(pskHex);
        if (pskProblem != null) {
            throw new IllegalArgumentException(pskProblem);
        }
        if (bindAddress.isEmpty()) {
            throw new IllegalArgumentException("bind-address must not be empty");
        }
        if (bindAddress.chars().anyMatch(Character::isWhitespace)) {
            throw new IllegalArgumentException(
                "bind-address must be a single address without whitespace"
            );
        }
        if (maxPayloadBytes < 1 || maxPayloadBytes > MAX_PAYLOAD_BYTES) {
            throw new IllegalArgumentException(
                "max-payload-bytes must be between 1 and " + MAX_PAYLOAD_BYTES
            );
        }
        if (width < 16 || width > 8192 || height < 16 || height > 8192) {
            throw new IllegalArgumentException(
                "width and height must be between 16 and 8192"
            );
        }
        if ((width & 1) != 0 || (height & 1) != 0) {
            throw new IllegalArgumentException(
                "width and height must be even for the H.264 encoder"
            );
        }
        if (bitRate < 100_000 || bitRate > 200_000_000) {
            throw new IllegalArgumentException(
                "bit-rate must be between 100000 and 200000000"
            );
        }
        if (frameRate < 1 || frameRate > 120) {
            throw new IllegalArgumentException(
                "frame-rate must be between 1 and 120"
            );
        }
        if (iFrameInterval < 1 || iFrameInterval > 60) {
            throw new IllegalArgumentException(
                "i-frame-interval must be between 1 and 60 seconds"
            );
        }
        if (!"auto".equals(displayBackend)
            && !"displaymanager".equals(displayBackend)
            && !"surfacecontrol".equals(displayBackend)) {
            throw new IllegalArgumentException(
                "display-backend must be auto, displaymanager, or surfacecontrol"
            );
        }
        if (targetFps < 0 || targetFps > MAX_TARGET_FPS) {
            throw new IllegalArgumentException(
                "target-fps must be between 0 (unlimited) and " + MAX_TARGET_FPS
            );
        }

        return new ServerOptions(
            port,
            controlPort,
            bindAddress,
            pskHex,
            maxPayloadBytes,
            width,
            height,
            bitRate,
            frameRate,
            iFrameInterval,
            displayBackend,
            targetFps
        );
    }

    public static String usage() {
        return "usage: Server [--port=" + DEFAULT_PORT
            + "] [--control-port=" + DEFAULT_CONTROL_PORT + "]"
            + " [--bind-address=" + DEFAULT_BIND_ADDRESS + "]"
            + " [--psk-hex=<32|48|64 hex chars>]"
            + " [--max-payload-bytes=" + MAX_PAYLOAD_BYTES + "]"
            + " [--width=" + DEFAULT_WIDTH + "] [--height=" + DEFAULT_HEIGHT + "]"
            + " [--bit-rate=" + DEFAULT_BIT_RATE + "]"
            + " [--frame-rate=" + DEFAULT_FRAME_RATE + "]"
            + " [--i-frame-interval=" + DEFAULT_I_FRAME_INTERVAL + "]"
            + " [--target-fps=" + DEFAULT_TARGET_FPS + "]"
            + " [--display-backend=auto|displaymanager|surfacecontrol]";
    }

    private static int parsePositiveInt(String arg, String prefix) {
        final String value = arg.substring(prefix.length());
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException error) {
            throw new IllegalArgumentException(
                "invalid integer for " + prefix + ": " + value
            );
        }
    }

    private static int parseNonNegativeInt(String arg, String prefix) {
        final int value = parsePositiveInt(arg, prefix);
        if (value < 0) {
            throw new IllegalArgumentException(
                "expected a non-negative integer for " + prefix + ": " + value
            );
        }
        return value;
    }
}
