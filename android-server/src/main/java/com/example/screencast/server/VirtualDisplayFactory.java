package com.example.screencast.server;

import android.graphics.Rect;
import android.hardware.display.VirtualDisplay;
import android.os.Build;
import android.os.IBinder;
import android.view.Display;
import android.view.Surface;

import java.lang.reflect.Method;

/**
 * Creates a virtual display whose output is the MediaCodec input Surface.
 *
 * <p>Order of attempts:
 * <ol>
 *   <li>Hidden static DisplayManager.createVirtualDisplay(name, w, h,
 *       displayIdToMirror, surface). This mirrors the default display without
 *       a Context and is the modern system path.</li>
 *   <li>SurfaceControl.createDisplay() plus the legacy display transaction
 *       (openTransaction/setDisplaySurface/setDisplayProjection/
 *       setDisplayLayerStack/closeTransaction). Android 14+ is handled with
 *       secure=false; Android 10/11 uses the secure-display behavior required
 *       by those releases.</li>
 * </ol>
 *
 * <p>If both fail, this factory throws. It never falls back to MediaProjection.
 */
final class VirtualDisplayFactory {
    private static final String DISPLAY_NAME = "screencast-demo";

    private VirtualDisplayFactory() {
    }

    interface Handle extends AutoCloseable {
        String backendName();

        @Override
        void close();
    }

    static Handle create(ServerOptions options, Surface outputSurface)
        throws CaptureException {
        final DisplayMetadata metadata = DisplayMetadata.load(options);
        final int sdk = Build.VERSION.SDK_INT;
        final String requestedBackend = options.displayBackend();
        CaptureLog.info(
            "Creating virtual display: API " + sdk
                + " requestedBackend=" + requestedBackend
                + " size=" + options.width() + "x" + options.height()
                + " displayMetadata=[" + metadata + "]"
        );

        Exception displayManagerFailure = null;
        if (!"surfacecontrol".equals(requestedBackend)) {
            try {
                final Handle handle = createWithDisplayManager(options, outputSurface);
                CaptureLog.info(
                    "Virtual display backend: DisplayManager (" + handle.backendName() + ")"
                );
                return handle;
            } catch (Exception error) {
                displayManagerFailure = error;
                CaptureLog.error(
                    "DisplayManager.createVirtualDisplay(String,int,int,int,Surface) failed "
                        + "on API " + sdk,
                    error
                );
            }
        }

        Exception surfaceControlFailure = null;
        if (!"displaymanager".equals(requestedBackend)) {
            try {
                final Handle handle = createWithSurfaceControl(options, metadata, outputSurface);
                CaptureLog.info(
                    "Virtual display backend: SurfaceControl (" + handle.backendName()
                        + "); API " + sdk
                );
                return handle;
            } catch (Exception error) {
                surfaceControlFailure = error;
                CaptureLog.error(
                    "SurfaceControl.createDisplay() + display transaction failed on API " + sdk,
                    error
                );
            }
        }

        final CaptureException failure = new CaptureException(
            "No virtual display backend succeeded on API " + sdk
                + " (requested=" + requestedBackend + "). "
                + "this server refuses to continue with any other capture path."
        );
        failure.addSuppressed(displayManagerFailure);
        failure.addSuppressed(surfaceControlFailure);
        throw failure;
    }

    private static Handle createWithDisplayManager(
        ServerOptions options,
        Surface outputSurface
    ) throws Exception {
        final Class<?> displayManagerClass = Class.forName(
            "android.hardware.display.DisplayManager"
        );
        final Method createVirtualDisplay = displayManagerClass.getMethod(
            "createVirtualDisplay",
            String.class,
            int.class,
            int.class,
            int.class,
            Surface.class
        );

        // This is a hidden system API. It mirrors displayIdToMirror directly
        // into the supplied Surface, so no SurfaceControl transaction is needed.
        final Object value = createVirtualDisplay.invoke(
            null,
            DISPLAY_NAME,
            options.width(),
            options.height(),
            Display.DEFAULT_DISPLAY,
            outputSurface
        );
        if (!(value instanceof VirtualDisplay)) {
            throw new CaptureException(
                "DisplayManager.createVirtualDisplay returned "
                    + (value == null ? "null" : value.getClass().getName())
            );
        }

        final VirtualDisplay virtualDisplay = (VirtualDisplay) value;
        String detail = "displayId=unknown";
        try {
            final Display display = virtualDisplay.getDisplay();
            if (display != null) {
                detail = "displayId=" + display.getDisplayId();
            }
        } catch (Exception error) {
            CaptureLog.warn(
                "VirtualDisplay created but getDisplay() failed: " + error.getMessage()
            );
        }
        return new DisplayManagerHandle(virtualDisplay, detail);
    }

    private static Handle createWithSurfaceControl(
        ServerOptions options,
        DisplayMetadata metadata,
        Surface outputSurface
    ) throws Exception {
        final Class<?> surfaceControlClass = Class.forName("android.view.SurfaceControl");
        final boolean secure = shouldUseSecureDisplay();
        final Method createDisplay = surfaceControlClass.getMethod(
            "createDisplay",
            String.class,
            boolean.class
        );
        final Method openTransaction = surfaceControlClass.getMethod("openTransaction");
        final Method closeTransaction = surfaceControlClass.getMethod("closeTransaction");
        final Method setDisplaySurface = surfaceControlClass.getMethod(
            "setDisplaySurface",
            IBinder.class,
            Surface.class
        );
        final Method setDisplayProjection = surfaceControlClass.getMethod(
            "setDisplayProjection",
            IBinder.class,
            int.class,
            Rect.class,
            Rect.class
        );
        final Method setDisplayLayerStack = surfaceControlClass.getMethod(
            "setDisplayLayerStack",
            IBinder.class,
            int.class
        );
        final Method destroyDisplay = surfaceControlClass.getMethod(
            "destroyDisplay",
            IBinder.class
        );

        final Object value = createDisplay.invoke(null, DISPLAY_NAME, secure);
        if (!(value instanceof IBinder)) {
            throw new CaptureException(
                "SurfaceControl.createDisplay returned "
                    + (value == null ? "null" : value.getClass().getName())
                    + "; expected IBinder"
            );
        }
        final IBinder token = (IBinder) value;

        // Android 14 changed the meaning of these legacy display helpers:
        // setDisplayProjection() now resizes the virtual display using the
        // layerStackRect size, and setDisplayLayerStack() forwards its int as
        // "displayIdToMirror". Android 13 and earlier expect the source
        // display rect plus the display layer stack.
        final boolean android14OrNewer = Build.VERSION.SDK_INT >= 34;
        final Rect projectionSource;
        final Rect projectionTarget;
        final int mirrorArgument;
        if (android14OrNewer) {
            projectionSource = new Rect(0, 0, options.width(), options.height());
            projectionTarget = new Rect(projectionSource);
            mirrorArgument = Display.DEFAULT_DISPLAY;
        } else {
            projectionSource = new Rect(0, 0, metadata.width, metadata.height);
            projectionTarget = new Rect(0, 0, options.width(), options.height());
            mirrorArgument = metadata.layerStack;
        }

        boolean transactionOpen = false;
        try {
            openTransaction.invoke(null);
            transactionOpen = true;
            setDisplaySurface.invoke(null, token, outputSurface);
            setDisplayProjection.invoke(
                null,
                token,
                Surface.ROTATION_0,
                projectionSource,
                projectionTarget
            );
            setDisplayLayerStack.invoke(null, token, mirrorArgument);
        } catch (Exception error) {
            try {
                destroyDisplay.invoke(null, token);
            } catch (Exception destroyError) {
                error.addSuppressed(destroyError);
            }
            throw error;
        } finally {
            if (transactionOpen) {
                try {
                    closeTransaction.invoke(null);
                } catch (Exception error) {
                    CaptureLog.warn(
                        "SurfaceControl.closeTransaction failed: " + error.getMessage()
                    );
                }
            }
        }

        CaptureLog.info(
            "SurfaceControl display configured: secure=" + secure
                + " android14OrNewer=" + android14OrNewer
                + " mirrorArgument=" + mirrorArgument
                + " projectionSource=" + projectionSource.width() + "x" + projectionSource.height()
                + " projectionTarget=" + projectionTarget.width() + "x" + projectionTarget.height()
                + " displayRotation=" + metadata.rotation
        );
        return new SurfaceControlHandle(surfaceControlClass, token);
    }

    private static boolean shouldUseSecureDisplay() {
        // Matches the shell-compatible behavior used by scrcpy: Android 10/11
        // need a secure display; Android 12+ rejects secure displays from shell
        // in many builds, including Android 14+.
        if (Build.VERSION.SDK_INT < 30) {
            return true;
        }
        if (Build.VERSION.SDK_INT == 30) {
            return !"S".equals(Build.VERSION.CODENAME);
        }
        return false;
    }

    private static final class DisplayManagerHandle implements Handle {
        private final VirtualDisplay virtualDisplay;
        private final String detail;

        DisplayManagerHandle(VirtualDisplay virtualDisplay, String detail) {
            this.virtualDisplay = virtualDisplay;
            this.detail = detail;
        }

        @Override
        public String backendName() {
            return "VirtualDisplay " + detail;
        }

        @Override
        public void close() {
            try {
                virtualDisplay.release();
            } catch (Exception error) {
                CaptureLog.warn(
                    "Failed to release VirtualDisplay: " + error.getMessage()
                );
            }
        }
    }

    private static final class SurfaceControlHandle implements Handle {
        private final Class<?> surfaceControlClass;
        private final IBinder token;

        SurfaceControlHandle(Class<?> surfaceControlClass, IBinder token) {
            this.surfaceControlClass = surfaceControlClass;
            this.token = token;
        }

        @Override
        public String backendName() {
            return "IBinder display token";
        }

        @Override
        public void close() {
            try {
                surfaceControlClass.getMethod("destroyDisplay", IBinder.class)
                    .invoke(null, token);
            } catch (Exception error) {
                CaptureLog.warn(
                    "Failed to destroy SurfaceControl display: " + error.getMessage()
                );
            }
        }
    }
}
