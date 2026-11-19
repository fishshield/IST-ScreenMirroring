package com.example.screencast.server;

import java.io.BufferedInputStream;
import java.io.DataInputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.SocketException;

/**
 * Control-channel listener on its own port (default 27184).
 *
 * <p>Runs beside the SCRC video listener and is completely independent of it:
 * each accepted control connection gets its own thread, and a control
 * disconnect only stops input injection — the video session keeps running.
 *
 * <p>Inbound frames follow {@link ControlProtocol}: a type byte, a 4-byte
 * big-endian payload length, then the payload.
 */
final class ControlServer implements Runnable, AutoCloseable {
    private final ServerOptions options;
    private final ServerSocket listener;
    private final InputInjector injector;
    private final PskCipher psk;

    /** Invoked when the controller app asks the server to exit. */
    private volatile Runnable shutdownCallback;

    ControlServer(ServerOptions options, PskCipher psk, InputMapping mapping)
        throws IOException {
        this.options = options;
        this.psk = psk;
        this.listener = new ServerSocket();
        this.listener.setReuseAddress(true);
        this.listener.bind(
            new InetSocketAddress(
                InetAddress.getByName(options.bindAddress()),
                options.controlPort()
            )
        );
        // The injector shares the mapping with the capture backend, which
        // recomputes the letterbox for every virtual display it creates.
        this.injector = new InputInjector(mapping);
    }

    void setShutdownCallback(Runnable callback) {
        this.shutdownCallback = callback;
    }

    @Override
    public void run() {
        System.out.println(
            "Control server listening on " + options.bindAddress() + ":"
                + options.controlPort() + " (video "
                + options.width() + "x" + options.height() + ")"
        );
        while (!listener.isClosed()) {
            try {
                final Socket client = listener.accept();
                client.setTcpNoDelay(true);
                System.out.println(
                    "control connected: " + client.getRemoteSocketAddress()
                );
                final Thread worker = new Thread(
                    () -> handleClient(client),
                    "scrc-control-client"
                );
                worker.setDaemon(true);
                worker.start();
            } catch (SocketException error) {
                if (listener.isClosed()) {
                    return;
                }
                CaptureLog.warn("Control accept failed: " + error.getMessage());
            } catch (IOException error) {
                if (listener.isClosed()) {
                    return;
                }
                CaptureLog.warn("Control accept failed: " + error.getMessage());
            }
        }
    }

    private void handleClient(Socket client) {
        try (Socket socket = client) {
            final InputStream raw = socket.getInputStream();
            // Record layer sits below the control framing; the parser above it
            // sees the same bytes as an unencrypted connection.
            final InputStream input = psk == null
                ? new BufferedInputStream(raw)
                : new BufferedInputStream(new SecureRecordInputStream(raw, psk));
            while (!socket.isClosed()) {
                final int type = input.read();
                if (type < 0) {
                    System.out.println(
                        "control disconnected: peer closed the connection"
                    );
                    return;
                }
                final int length = readInt(input);
                if (length < 0 || length > ControlProtocol.MAX_PAYLOAD_BYTES) {
                    CaptureLog.warn(
                        "control: invalid payload length " + length
                            + " for type 0x" + Integer.toHexString(type)
                    );
                    return;
                }
                final byte[] payload = new byte[length];
                readFully(input, payload);
                if (type == ControlProtocol.TYPE_SHUTDOWN
                    && length == ControlProtocol.SHUTDOWN_PAYLOAD_BYTES) {
                    // One-way request: stop serving and exit. The reply is the
                    // closed port, which the app verifies.
                    System.out.println("shutdown requested over the control channel");
                    final Runnable callback = shutdownCallback;
                    if (callback != null) {
                        callback.run();
                    }
                    return;
                }
                injector.handle(type, payload);
            }
        } catch (EOFException closed) {
            System.out.println("control disconnected: peer closed the connection");
        } catch (IOException error) {
            // A dead control socket must not end the video session.
            System.out.println(
                "control disconnected: " + error.getClass().getSimpleName()
                    + ": " + error.getMessage()
            );
        } catch (RuntimeException error) {
            CaptureLog.error(
                "Control session failed: " + error.getClass().getSimpleName()
                    + ": " + error.getMessage(),
                error
            );
        }
    }

    private static int readInt(InputStream input) throws IOException {
        final int b0 = input.read();
        final int b1 = input.read();
        final int b2 = input.read();
        final int b3 = input.read();
        if ((b0 | b1 | b2 | b3) < 0) {
            throw new EOFException("truncated control header");
        }
        return ((b0 & 0xFF) << 24)
            | ((b1 & 0xFF) << 16)
            | ((b2 & 0xFF) << 8)
            | (b3 & 0xFF);
    }

    private static void readFully(InputStream input, byte[] destination)
        throws IOException {
        final DataInputStream stream = new DataInputStream(input);
        stream.readFully(destination);
    }

    @Override
    public void close() {
        try {
            listener.close();
        } catch (IOException ignored) {
            // Listener already unusable.
        }
    }
}
