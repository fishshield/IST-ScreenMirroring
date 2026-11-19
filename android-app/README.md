# Screen Cast Controller (Android)

Unprivileged Android companion app that uses **Shizuku** to run the existing
`screencast-server.jar` as shell (UID 2000). It does not contain an ADB client,
root helper, or self-elevation code.

## Privilege model

- The app is a normal Android application.
- The user activates **Shizuku** through Android 11+ wireless debugging.
- `MainActivity` requests Shizuku permission; `ServerLauncher` uses the
  user-authorized shell binder to launch/stop the existing server.
- Capture remains the existing `app_process` server using hidden display APIs;
  this app does **not** use MediaProjection.
- No USB is needed after the APK is installed and Shizuku is active.

## Implemented

- `MainActivity`:
  - checks `Shizuku.pingBinder()` on create/resume;
  - shows an activation guide when Shizuku is unavailable;
  - requests Shizuku permission and handles the async result;
  - handles binder death and binder receipt;
  - start/stop buttons now drive `ScreenCastForegroundService` instead of
    calling `ServerLauncher` directly;
  - requests `POST_NOTIFICATIONS` on Android 13+ before starting the service
    (a denial does not block the service, it only hides the notification);
  - bottom card for ColorOS/OPPO users with "自启动管理" and "电池优化" jumps.
- `ServerLauncher.kt`: unchanged by the foreground-service work — same jar
  install, same `app_process` command line, same start/stop semantics:
  - checks and installs `screencast-server.jar` from app assets into
    `/data/local/tmp/` through the shell identity;
  - starts `app_process` with the existing server class, port and
    `--bind-address=0.0.0.0`;
  - redirects server output to `/data/local/tmp/screencast-server.log`;
  - stops by `destroy()` and a best-effort `pkill`;
  - registers a Shizuku binder-death listener;
  - uses `withTimeout` around operations and `IRemoteProcess.waitForTimeout`
    for finite shell commands.
- `ScreenCastForegroundService`:
  - wraps the launcher's lifetime: `onStartCommand(ACTION_START)` calls
    `ServerLauncher.start()`, `onDestroy()` calls `ServerLauncher.stop()`, and
    the stop is guarded so a normal stop does not run twice;
  - declared with `android:foregroundServiceType="specialUse"` plus the
    required `PROPERTY_SPECIAL_USE_FGS_SUBTYPE` reason; Android 14+ also needs
    `FOREGROUND_SERVICE_SPECIAL_USE`, and `startForeground` passes
    `FOREGROUND_SERVICE_TYPE_SPECIAL_USE` there;
  - posts a low-importance, ongoing notification ("投屏服务运行中") with a
    "停止" action; the text follows `CastStateStore` (starting / running /
    stopping / error / unauthorized);
  - maps the lifecycle onto `CastStateStore`: request → `STARTING`, launcher
    success → `RUNNING`, stop → `STOPPED`, failure → `ERROR`;
  - `start()` returns false when the platform refuses a background
    foreground-service start (Quick Settings tiles on Android 12+); callers
    then fall back to the plain launcher path.
- `DiscoveryBroadcaster` (LAN one-tap casting):
  - after a successful start it sends a secret-free JSON offer
    (`{"type":"screencast-offer","ip":...,"videoPort":27183,
    "controlPort":27184,"pskRequired":false}`) to UDP/27185, once per second for
    five seconds;
  - it iterates every up, non-loopback, non-link-local IPv4 interface and sends
    through that interface's own broadcast address, so a multi-homed phone
    advertises the correct address per network;
  - the tile announces immediately after a tap and the foreground service
    announces once the server is really running; `announce()` is coalesced by an
    atomic flag and runs on `Dispatchers.IO`, so a missing desktop cannot block
    or fail the capture start;
  - `pskRequired` describes the running server: `ServerLauncher` never passes
    `--psk-hex`, so the shipped configuration advertises `false`;
  - requires the `INTERNET` permission (added to the manifest); the PSK itself
    never travels over UDP.
- `CastStateStore` is a **process-wide singleton** (`getInstance`): the Activity,
  the Quick Settings tile, the foreground service and the launcher share one
  instance and therefore one listener list. Using one instance per component
  made the Activity UI update only after backgrounding (it never received the
  service's changes) and left the tile stuck on “启动中/停止中” without the
  active colour. Shizuku's manager package is `moe.shizuku.privileged.api`
  (declared in `<queries>`); the old `moe.shizuku.manager` value made
  “打开 Shizuku” report “未找到 App”.
- `ServerProbe` + state self-healing:
  - `CastStateStore` is only a cache; after the `app_process` capture server is
    killed externally it could keep claiming RUNNING, the tile would say
    “投屏 · 运行中”, and the next tap could take the wrong branch;
  - a tap waits up to ~1.5 s for the Shizuku binder when the process was just
    re-created (ColorOS kills the app aggressively); previously the first tap
    after a kill was always reported as “未授权”;
  - before acting, the tile probes `127.0.0.1:27184` (400 ms) and repairs the
    cached state, so a tap starts a server whenever nothing is listening and
    stops it whenever something is (the control port is probed, not 27183,
    because connecting to the video port makes the server create a virtual
    display);
  - `ServerLauncher` reconciles the persisted state against that probe on
    process start, under the same mutex as start/stop, so the reconciliation
    cannot race a tap;
  - after a stop the final state comes from “is the port closed” (waits up to
    ~2.4 s), not from the Shizuku call's return value: a failed `pkill` no
    longer paints “异常” for a server that is actually gone;
  - `ScreenCastForegroundService` runs a 2 s watchdog while it owns the process
    (process gone + port closed → ERROR, notification removed) and no longer
    auto-starts a second server when Android recreates it after a kill
    (`START_STICKY` restart without a request now just stops itself);
  - `MainActivity.onResume` performs the same probe so the main screen cannot
    stay stuck at “运行中”.
- `ScreenCastTileService`:
  - `onStartListening()` renders the current controller state, then
    re-checks Shizuku authorization and the live `app_process` handle on
    `Dispatchers.IO` and repaints;
  - the tile icon, label and subtitle follow the state: running / starting
    (`ic_tile_running`, `投屏 · 运行中`), stopped (`ic_tile`, `投屏 · 已停止`),
    unauthorized (`ic_tile_unauthorized`, `投屏 · 未授权`), plus stopping and
    error variants;
  - `onClick()` never blocks: it only flips an atomic gate and hands the work
    to a process-wide `Dispatchers.IO` scope, because every Shizuku call is a
    binder round-trip and the system unbinds the service as soon as the panel
    collapses;
  - an authorized click starts the capture through
    `ScreenCastForegroundService` and stops it the same way; if the platform
    refuses a background foreground-service start, the tile falls back to
    `ServerLauncher` directly; `STARTING`/`STOPPING` clicks are ignored instead
    of fighting the launcher mutex;
  - an unauthorized click shows a Toast and expands `MainActivity` through
    `startActivityAndCollapse`, so the permission flow is never skipped
    silently;
  - long-press is handled by the framework: `TileService` has no long-press
    callback, so `MainActivity` declares `QS_TILE_PREFERENCES` and the system
    launches it with the tile component in the intent;
  - `requestAddTile()` uses `StatusBarManager.requestAddTileService`
    (Android 13+) to show the system "add tile" dialog, and returns `false` on
    Android 7.0-12 where only the manual QS-edit flow exists. The
    `MainActivity` button explains that fallback.
  - API 34+: activity launches from the tile use the `PendingIntent` overload
    of `startActivityAndCollapse` (the `Intent` overload throws for apps
    targeting 34+); API 24-33 uses the legacy overload behind a suppression.
- `CastStateStore`:
  - shared `SharedPreferences` state with listener callbacks;
  - states: `UNAUTHORIZED`, `STOPPED`, `STARTING`, `RUNNING`, `STOPPING`,
    `ERROR`.
- The APK includes the server jar in `app/src/main/assets/`.

## Important API note

Shizuku 13.1.5 does **not** expose `libsu`'s `Shell.Result` (that type belongs
to libsu, not Shizuku). The available shell primitive is the Shizuku
`IShizukuService.newProcess` AIDL call. This implementation:

- runs all binder/process work on `Dispatchers.IO`;
- awaits finite commands with
  `IRemoteProcess.waitForTimeout(timeout, "MILLISECONDS")` and returns the exit
  code;
- starts the long-lived server process without waiting for its output;
- wraps operations in `withTimeout` and handles binder death.

There is no synchronous UI-thread wait and no invented `Shell.Result`.

## Build

```powershell
cd android-app
.\gradlew.bat :app:assembleDebug
```

APK: `app/build/outputs/apk/debug/app-debug.apk`
The local build uses Gradle 8.14, AGP 8.7.3, Kotlin 2.0.21, compileSdk 35,
minSdk 26.

## Verification

- Gradle build succeeded (also after the Quick Settings tile work).
- `:app:lintDebug`: 0 errors (3 pre-existing warnings: `OldTargetApi`,
  `DataExtractionRules`, one unused string).
- APK installed and MainActivity launched on OPPO Android 14.
- Quick Settings tile verified on OPPO Android 14 / API 34:
  - "添加到快捷设置" opened the system add-tile dialog
    (`StatusBarManager.requestAddTileService`); confirming it bound
    `ScreenCastTileService` from `com.android.systemui` and appended
    `custom(com.example.screencast.controller/.ScreenCastTileService)` to
    `sysui_qs_tiles`;
  - the tile rendered the runtime label `投屏 · 未授权`, the struck-through cast
    icon and the subtitle `点按打开授权`;
  - `cmd statusbar click-tile` (same `onClick()` path) showed the
    "请先打开 App 完成 Shizuku 授权" Toast and brought `MainActivity` up through
    the API 34 `PendingIntent` launch;
  - long-pressing the tile made SystemUI launch `MainActivity` with
    `act=android.service.quicksettings.action.QS_TILE_PREFERENCES`
    (`launchedFromPackage=com.android.systemui`), i.e. the manifest route
    works;
  - no `AndroidRuntime` crash and no exception in logcat during any of these
    interactions.
- Shizuku runtime path verified on OPPO Android 14 with an activated Shizuku:
  - launching the app raised the Shizuku permission dialog; "始终允许" switched
    the UI to `Shizuku 已连接并已授权` and enabled start/stop;
  - "启动服务" ran `IShizukuService.newProcess` as shell UID 2000, the UI turned
    `运行中`, and `/data/local/tmp/screencast-server.log` showed
    `Server UID=2000 SDK=34` plus
    `SCRC server listening on 0.0.0.0:27183`;
  - with the server running, the tile switched to `投屏 · 运行中`, the filled
    `ic_tile_running` icon and `Tile.STATE_ACTIVE`;
  - the Windows `direct` transport then connected to `192.168.1.134:27183`
    without any ADB command and decoded 1280x720 frames (counter passed 2205)
    while the phone screen kept changing.
- LAN discovery + tile (2026-11-17, OPPO Android 14, Shizuku active):
  - UI/state sharing: pressing “启动服务” in the Activity flips the screen to
    “状态：运行中” immediately (no need to background/foreground the app), and
    a tile tap performed while the Activity is open updates it in place as
    well — both directions were checked with screenshots;
  - tapping the tile from `投屏 · 已停止` started the server, logged
    `screencast offer round 1/5 … 5/5`, and the Windows host auto-connected in
    **1.36 s** (1.19 s when the app process had just been killed and had to
    wait for the Shizuku binder) and showed live frames;
  - the tile turned purple/active with “投屏 · 运行中” while the server ran and
    returned to the inactive colour on stop, matching the platform's other
    tiles;
  - tapping it again stopped the server (`STOPPED`, `app_process` gone, desktop
    session ended) and a following tap started it again and reconnected — two
    full start/stop cycles stayed stable;
  - killing `app_process` externally while the service owned it flipped the
    state to `ERROR` on the next watchdog poll;
  - a stale `RUNNING` left over after `am force-stop` is reconciled to
    `STOPPED` by the control-port probe (`reconciled persisted state RUNNING ->
    STOPPED (control port listening=false)`);
  - a cold tile process no longer renders “投屏 · 未授权” for an authorized
    app: the refresh path waits briefly for the Shizuku binder as well.
- Without Shizuku (earlier run) the app correctly showed the “Shizuku 未运行”
  activation guide and disabled start/stop.
- Foreground-service work: `:app:assembleDebug` and `:app:lintDebug` pass with
  0 errors and the same 3 pre-existing warnings. The service was later verified
  on the test phone (`isForeground=true`, `specialUse` type, ongoing notification
  with its action) and `dumpsys activity services` showed the foreground state.
- Still unverified at runtime: the notification "停止" action, task-card swipe
  survival, POST_NOTIFICATIONS denial path, the ColorOS intents, tile stop of a
  running server, Shizuku binder death, the launcher timeouts, and
  Android 7.0–12 (manual add-tile fallback and legacy
  `startActivityAndCollapse(Intent)`).

## Still to do

- Runtime verification of the notification "停止" action, task removal / screen
  lock survival, the ColorOS intents, Shizuku binder death, the launcher
  timeouts, and Android 7.0–12 (manual add-tile fallback and legacy
  `startActivityAndCollapse(Intent)`).
- Device-side authorization guide can open the Shizuku download page if the
  Shizuku package is not installed.
- Rotating/resolution-change and reconnect behavior.
- Runtime verification for the tile stop path, binder death and timeouts.

## Manifest notes

- `ShizukuProvider` is exported and protected by
  `android.permission.INTERACT_ACROSS_USERS_FULL`, as required by Shizuku.
- The tile service is protected by
  `android.permission.BIND_QUICK_SETTINGS_TILE` and declares
  `android.service.quicksettings.action.QS_TILE`.
- `ACTIVE_TILE` keeps the tile bound while the capture server runs;
  `TOGGLEABLE_TILE` (API 34+) lets a collapsed tap toggle it instead of opening
  the tile detail panel. Both are ignored on releases that predate them.
- `QS_TILE_PREFERENCES` is declared on `MainActivity` for system-managed
  long-press; `TileService` exposes no long-press callback, so this intent
  filter is the only supported route.
- `POST_NOTIFICATIONS` is used for the ongoing capture notification (requested
  from `MainActivity` on Android 13+).
- `FOREGROUND_SERVICE` and `FOREGROUND_SERVICE_SPECIAL_USE` cover
  `ScreenCastForegroundService`, which declares
  `android:foregroundServiceType="specialUse"` and carries a
  `android.app.PROPERTY_SPECIAL_USE_FGS_SUBTYPE` property explaining that the
  service mirrors the screen through a user-authorized Shizuku shell process.
  `specialUse` is required on Android 14+; older releases ignore both the type
  permission and the property.
