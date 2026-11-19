package com.example.screencast.server;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;

/**
 * Entry point for the app_process capture server.
 *
 * <p>This process must be started by host ADB so that it runs as the shell user
 * (UID 2000). It owns the listening socket, accepts one viewer at a time, and
 * hands the encoded NAL sink to the virtual-display/MediaCodec capture backend.
 *
 * <p>The capture path uses hidden display APIs through reflection. It never
 * falls back to MediaProjection.
 */
public final class Server implements AutoCloseable {
    private final ServerOptions options;
    private final ServerSocket listener;
    private final ControlServer controlServer;
    private final PskCipher psk;

    /**
     * Input letterbox shared by the control server (reader) and every capture
     * backend (writer): the capture backend recomputes it for each virtual
     * display it creates.
     */
    private final InputMapping inputMapping;

    /** Guards a single shutdown request. */
    private volatile boolean shuttingDown;

    public static void main(String[] args) {
        final ServerOptions options;
        try {
            options = ServerOptions.parse(args);
        } catch (IllegalArgumentException error) {
            System.err.println("screencast-server: " + error.getMessage());
            System.err.println(ServerOptions.usage());
            System.exit(2);
            return;
        }

        try (Server server = new Server(options)) {
            Runtime.getRuntime().addShutdownHook(
                new Thread(server::close, "screencast-shutdown")
            );
            CaptureLog.info(
                "Server UID=" + android.os.Process.myUid()
                    + " SDK=" + android.os.Build.VERSION.SDK_INT
            );
            final boolean loopbackOnly = InetAddress
                .getByName(options.bindAddress())
                .isLoopbackAddress();
            System.out.println(
                "SCRC server listening on " + options.bindAddress() + ":"
                    + options.port() + " (max payload "
                    + options.maxPayloadBytes() + " bytes)"
            );
            if (!loopbackOnly) {
                System.err.println(
                    "WARNING: SCRC has no authentication and is listening on "
                        + options.bindAddress()
                        + "; use only on a trusted local network."
                );
            }
            if (server.encrypted()) {
                CaptureLog.info(
                    "Payload encryption enabled: AES-GCM record layer over "
                        + "SCRC and control channels"
                );
            } else {
                System.err.println(
                    "WARNING: no --psk-hex; SCRC video and control traffic is "
                        + "UNENCRYPTED."
                );
            }
            server.serve();
        } catch (IOException error) {
            System.err.println("screencast-server: " + error.getMessage());
            System.exit(1);
        }
    }

    public Server(ServerOptions options) throws IOException {
        this.options = options;
        this.psk = PskCipher.isConfigured(options.pskHex())
            ? PskCipher.fromHex(options.pskHex())
            : null;
        this.listener = new ServerSocket();
        this.listener.setReuseAddress(true);
        this.listener.bind(
            new InetSocketAddress(
                InetAddress.getByName(options.bindAddress()),
                options.port()
            )
        );
        // Best-effort bootstrap mapping from the current display size; the
        // capture backend replaces it per virtual display, which is what makes
        // a rotated phone map correctly.
        final int[] sourceSize = DisplayMetadata.realSize(options);
        this.inputMapping = new InputMapping(
            options.width(),
            options.height(),
            sourceSize[0] > 0 ? sourceSize[0] : options.width(),
            sourceSize[1] > 0 ? sourceSize[1] : options.height()
        );
        // Binds the control port up front so a conflicting port fails startup
        // instead of silently leaving the desktop without input.
        this.controlServer = new ControlServer(options, psk, inputMapping);
        this.controlServer.setShutdownCallback(this::shutdown);
    }

    /**
     * Exits on request from the controller app (control opcode 0x10).
     *
     * <p>This is the only stop path available to an unprivileged app once
     * Shizuku is gone: the capture process belongs to the shell user, so the app
     * cannot signal it, but it can ask it to shut down here.
     */
    void shutdown() {
        if (shuttingDown) {
            return;
        }
        shuttingDown = true;
        CaptureLog.info("shutdown requested by the controller app");
        close();
        System.exit(0);
    }

    boolean encrypted() {
        return psk != null;
    }

    public void serve() throws IOException {
        final Thread controlThread = new Thread(controlServer, "scrc-control");
        controlThread.setDaemon(true);
        controlThread.start();

        while (!listener.isClosed()) {
            try (Socket client = listener.accept()) {
                client.setTcpNoDelay(true);
                System.out.println("viewer connected: " + client.getRemoteSocketAddress());

                // Encryption is a record layer: SCRC writes the same bytes as
                // before, they are just sealed on the way out.
                final OutputStream output = psk == null
                    ? client.getOutputStream()
                    : new SecureRecordOutputStream(client.getOutputStream(), psk);

                try (
                    ScrcPacketWriter writer = new ScrcPacketWriter(
                        output,
                        options.maxPayloadBytes()
                    );
                    CaptureBackend capture =
                        new VirtualDisplayCaptureBackend(options, inputMapping)
                ) {
                    capture.run(writer);
                } catch (CaptureException error) {
                    CaptureLog.error("Capture setup failed", error);
                } catch (SocketException disconnected) {
                    System.out.println(
                        "viewer disconnected: " + disconnected.getMessage()
                    );
                } catch (Exception error) {
                    CaptureLog.error(
                        "Session failed: " + error.getClass().getSimpleName()
                            + ": " + error.getMessage(),
                        error
                    );
                }
            } catch (SocketException error) {
                if (listener.isClosed()) {
                    return;
                }
                throw error;
            }
        }
    }

    @Override
    public void close() {
        controlServer.close();
        try {
            listener.close();
        } catch (IOException ignored) {
            // The listener is already unusable; nothing else to release.
        }
    }
}
