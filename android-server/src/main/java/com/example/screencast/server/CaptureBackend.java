package com.example.screencast.server;

/**
 * Capture/encode session boundary.
 *
 * <p>A real implementation creates a virtual display, routes its output
 * Surface into a MediaCodec H.264 encoder input Surface (zero-copy), and
 * pushes each encoder output NAL into the supplied sink.
 *
 * <p>{@link #run(NalUnitSink)} blocks for the duration of the session and must
 * release codec/display resources in {@link #close()}.
 */
public interface CaptureBackend extends AutoCloseable {
    void run(NalUnitSink sink) throws Exception;

    @Override
    void close() throws Exception;
}
