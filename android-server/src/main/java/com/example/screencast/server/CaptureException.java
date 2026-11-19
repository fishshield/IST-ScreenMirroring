package com.example.screencast.server;

/** A capture/encoder/display setup failure with a user-readable message. */
public final class CaptureException extends Exception {
    public CaptureException(String message) {
        super(message);
    }

    public CaptureException(String message, Throwable cause) {
        super(message, cause);
    }
}
