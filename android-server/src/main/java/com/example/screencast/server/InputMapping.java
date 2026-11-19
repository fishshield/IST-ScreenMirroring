package com.example.screencast.server;

/**
 * Thread-safe holder for the current input mapping.
 *
 * <p>The control listener injects input on per-connection threads while the
 * capture backend owns the display lifecycle on the session thread, so the
 * geometry is published through a volatile field.
 *
 * <p>The capture backend recomputes the mapping every time it creates a virtual
 * display. That covers rotation and resolution changes between viewer sessions
 * without restarting the server: the letterbox depends on the source display
 * aspect ratio, which is exactly what changes when the phone rotates.
 *
 * <p>Plain Java so {@code CaptureCoreCheck} can unit-check the update path.
 */
final class InputMapping {
    private volatile LetterboxGeometry geometry;

    InputMapping(int videoWidth, int videoHeight, int displayWidth, int displayHeight) {
        this.geometry = LetterboxGeometry.fit(
            videoWidth,
            videoHeight,
            displayWidth,
            displayHeight
        );
    }

    LetterboxGeometry geometry() {
        return geometry;
    }

    /** Encoder output width; the video coordinate space for injected input. */
    int videoWidth() {
        return geometry.videoWidth();
    }

    /** Encoder output height; the video coordinate space for injected input. */
    int videoHeight() {
        return geometry.videoHeight();
    }

    /**
     * Recomputes the letterbox for the sizes observed when a virtual display was
     * created.
     *
     * @return true when the stored geometry changed, so the caller can log an
     *     actual remap instead of repeating the same line for every viewer.
     */
    boolean update(int videoWidth, int videoHeight, int displayWidth, int displayHeight) {
        final LetterboxGeometry next = LetterboxGeometry.fit(
            videoWidth,
            videoHeight,
            displayWidth,
            displayHeight
        );
        final boolean changed = !next.equals(geometry);
        geometry = next;
        return changed;
    }
}
