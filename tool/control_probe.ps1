[CmdletBinding()]
param(
    [ValidateSet('rect', 'move', 'click', 'wheel', 'state', 'activate', 'hit',
                 'postmove', 'postclick', 'postwheel', 'capture', 'captureactive',
                 'captureprint', 'capturescreen', 'overlays')]
    [string]$Action = 'rect',
    [int]$X = 0,
    [int]$Y = 0,
    [int]$Delta = 120,
    [int]$Count = 1,
    [int]$DelayMs = 120,
    [double]$NormX = 0.5,
    [double]$NormY = 0.5,
    [string]$Out = '',
    [string]$WindowTitle = 'Screen Cast'
)

# Drives the native overlay for manual control-channel verification:
#   rect      -> print the video window rect (class ScreenCastVideoWindow)
#   move      -> park the physical cursor at (X, Y)
#   click     -> left click at (X, Y) with the physical cursor
#   wheel     -> move the cursor to (X, Y) and send Count * Delta wheels
#   postmove  -> post WM_MOUSEMOVE at the normalized client point (NormX, NormY)
#   postclick -> post WM_MOUSEMOVE + WM_LBUTTONDOWN/UP at (NormX, NormY)
#   postwheel -> post WM_MOUSEMOVE + WM_MOUSEWHEEL at (NormX, NormY)
#   state     -> print cursor position and the overlay rect
#   activate  -> bring the app's top-level window to the foreground
#   hit       -> print the window class at (X, Y)
#
# The post* actions deliver the same window messages as a physical mouse, but
# with exact coordinates, so the verification does not depend on the physical
# cursor staying where it was placed.

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class CastProbe {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder name, int maxCount);

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT point);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int command);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);

    // The DSH tools run at the default (unaware) DPI context, which makes
    // GetWindowRect/CopyFromScreen return virtualized 96-DPI coordinates. The
    // Flutter window and its overlay are per-monitor DPI aware, so the capture
    // has to be too or it grabs the wrong screen region.
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();

    [DllImport("user32.dll")]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdc, uint flags);

    public const uint PW_RENDERFULLCONTENT = 0x00000002;

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT rect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT point);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint message, IntPtr wParam, IntPtr lParam);

    public const uint GA_ROOT = 2;

    // Windows message ids and flags used by the overlay handler.
    public const uint WM_MOUSEMOVE = 0x0200;
    public const uint WM_LBUTTONDOWN = 0x0201;
    public const uint WM_LBUTTONUP = 0x0202;
    public const uint WM_MOUSEWHEEL = 0x020A;
    public const int MK_LBUTTON = 0x0001;

    public static IntPtr MakeLParam(int x, int y) {
        return (IntPtr)((y << 16) | (x & 0xFFFF));
    }

    public static void PostMove(IntPtr hwnd, int cx, int cy) {
        PostMessage(hwnd, WM_MOUSEMOVE, IntPtr.Zero, MakeLParam(cx, cy));
    }

    public static void PostClick(IntPtr hwnd, int cx, int cy) {
        PostMessage(hwnd, WM_MOUSEMOVE, IntPtr.Zero, MakeLParam(cx, cy));
        System.Threading.Thread.Sleep(40);
        PostMessage(hwnd, WM_LBUTTONDOWN, (IntPtr)MK_LBUTTON, MakeLParam(cx, cy));
        System.Threading.Thread.Sleep(80);
        PostMessage(hwnd, WM_LBUTTONUP, IntPtr.Zero, MakeLParam(cx, cy));
    }

    public static void PostWheel(IntPtr hwnd, int screenX, int screenY, int delta) {
        IntPtr wParam = (IntPtr)((delta << 16) & unchecked((int)0xFFFF0000));
        IntPtr lParam = MakeLParam(screenX, screenY);
        PostMessage(hwnd, WM_MOUSEWHEEL, wParam, lParam);
    }

    public const uint LEFTDOWN = 0x0002;
    public const uint LEFTUP = 0x0004;
    public const uint WHEEL = 0x0800;

    public static IntPtr FindByClass(string className) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr hWnd, IntPtr lParam) {
            StringBuilder name = new StringBuilder(256);
            GetClassName(hWnd, name, name.Capacity);
            if (name.ToString() == className) {
                found = hWnd;
                return false;
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@

[void][CastProbe]::SetProcessDPIAware()

$overlay = [CastProbe]::FindByClass('ScreenCastVideoWindow')
if ($overlay -eq [IntPtr]::Zero) {
    throw 'Independent video window (ScreenCastVideoWindow) not found.'
}

$rect = New-Object CastProbe+RECT
if (-not [CastProbe]::GetWindowRect($overlay, [ref]$rect)) {
    throw 'GetWindowRect failed for the overlay window.'
}
$width = $rect.Right - $rect.Left
$height = $rect.Bottom - $rect.Top

function Invoke-OverlayCapture {
    param([string]$Path)
    Add-Type -AssemblyName System.Drawing
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    $bitmap = New-Object System.Drawing.Bitmap($w, $h)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $before = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0,
        (New-Object System.Drawing.Size($w, $h)))
    $after = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $graphics.Dispose()
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    [pscustomobject]@{
        path = $Path
        beforeMs = $before
        afterMs = $after
        left = $rect.Left
        top = $rect.Top
        width = $w
        height = $h
    } | ConvertTo-Json -Compress
}

function Set-AppForeground {
    $target = Get-Process -Name 'screen_cast_demo' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Select-Object -First 1
    if ($null -eq $target) {
        throw 'No screen_cast_demo top-level window found.'
    }
    [void][CastProbe]::ShowWindow($target.MainWindowHandle, 9)
    [void][CastProbe]::SetForegroundWindow($target.MainWindowHandle)
    return $target
}

switch ($Action) {
    'rect' {
        [pscustomobject]@{
            hwnd = $overlay
            left = $rect.Left
            top = $rect.Top
            right = $rect.Right
            bottom = $rect.Bottom
            width = $width
            height = $height
            visible = [CastProbe]::IsWindowVisible($overlay)
        } | ConvertTo-Json -Compress
    }
    'state' {
        $cursor = New-Object CastProbe+POINT
        [void][CastProbe]::GetCursorPos([ref]$cursor)
        [pscustomobject]@{
            cursorX = $cursor.X
            cursorY = $cursor.Y
            left = $rect.Left
            top = $rect.Top
            width = $width
            height = $height
        } | ConvertTo-Json -Compress
    }
    'move' {
        [void][CastProbe]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds $DelayMs
        "moved to $X,$Y"
    }
    'click' {
        [void][CastProbe]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds $DelayMs
        [CastProbe]::mouse_event([CastProbe]::LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 60
        [CastProbe]::mouse_event([CastProbe]::LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
        "clicked at $X,$Y"
    }
    'wheel' {
        [void][CastProbe]::SetCursorPos($X, $Y)
        Start-Sleep -Milliseconds $DelayMs
        for ($i = 0; $i -lt $Count; $i++) {
            [CastProbe]::mouse_event([CastProbe]::WHEEL, 0, 0, $Delta, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 60
        }
        "wheel delta=$Delta count=$Count at $X,$Y"
    }
    'hit' {
        $point = New-Object CastProbe+POINT
        $point.X = $X
        $point.Y = $Y
        $hit = [CastProbe]::WindowFromPoint($point)
        $name = New-Object System.Text.StringBuilder 256
        [void][CastProbe]::GetClassName($hit, $name, $name.Capacity)
        $ownerPid = 0
        [void][CastProbe]::GetWindowThreadProcessId($hit, [ref]$ownerPid)
        $root = [CastProbe]::GetAncestor($hit, [CastProbe]::GA_ROOT)
        $rootName = New-Object System.Text.StringBuilder 256
        [void][CastProbe]::GetClassName($root, $rootName, $rootName.Capacity)
        [pscustomobject]@{
            class = $name.ToString()
            rootClass = $rootName.ToString()
            isOverlay = ($hit -eq $overlay)
            overlayIsRoot = ($overlay -eq $root)
            processId = $ownerPid
        } | ConvertTo-Json -Compress
    }
    'activate' {
        $target = Get-Process -Name 'screen_cast_demo' -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } |
            Select-Object -First 1
        if ($null -eq $target) {
            throw 'No screen_cast_demo top-level window found.'
        }
        $hwnd = $target.MainWindowHandle
        [void][CastProbe]::ShowWindow($hwnd, 9)  # SW_RESTORE
        [void][CastProbe]::SetForegroundWindow($hwnd)
        Start-Sleep -Milliseconds 500
        [pscustomobject]@{
            pid = $target.Id
            hwnd = $hwnd
            title = $target.MainWindowTitle
        } | ConvertTo-Json -Compress
    }
    'postmove' {
        $client = New-Object CastProbe+RECT
        [void][CastProbe]::GetClientRect($overlay, [ref]$client)
        $cx = [int][Math]::Round($NormX * ($client.Right - $client.Left))
        $cy = [int][Math]::Round($NormY * ($client.Bottom - $client.Top))
        [CastProbe]::PostMove($overlay, $cx, $cy)
        Start-Sleep -Milliseconds $DelayMs
        "postmove client=$cx,$cy norm=$NormX,$NormY"
    }
    'postclick' {
        $client = New-Object CastProbe+RECT
        [void][CastProbe]::GetClientRect($overlay, [ref]$client)
        $cx = [int][Math]::Round($NormX * ($client.Right - $client.Left))
        $cy = [int][Math]::Round($NormY * ($client.Bottom - $client.Top))
        [CastProbe]::PostClick($overlay, $cx, $cy)
        Start-Sleep -Milliseconds $DelayMs
        "postclick client=$cx,$cy norm=$NormX,$NormY"
    }
    'postwheel' {
        $client = New-Object CastProbe+RECT
        [void][CastProbe]::GetClientRect($overlay, [ref]$client)
        $cx = [int][Math]::Round($NormX * ($client.Right - $client.Left))
        $cy = [int][Math]::Round($NormY * ($client.Bottom - $client.Top))
        $origin = New-Object CastProbe+POINT
        $origin.X = $cx
        $origin.Y = $cy
        [void][CastProbe]::ClientToScreen($overlay, [ref]$origin)
        [CastProbe]::PostMove($overlay, $cx, $cy)
        Start-Sleep -Milliseconds 80
        for ($i = 0; $i -lt $Count; $i++) {
            [CastProbe]::PostWheel($overlay, $origin.X, $origin.Y, $Delta)
            Start-Sleep -Milliseconds 80
        }
        "postwheel client=$cx,$cy screen=$($origin.X),$($origin.Y) delta=$Delta count=$Count"
    }
    'capture' {
        if ([string]::IsNullOrWhiteSpace($Out)) {
            throw '-Out is required for the capture action.'
        }
        Invoke-OverlayCapture -Path $Out
    }
    'captureactive' {
        if ([string]::IsNullOrWhiteSpace($Out)) {
            throw '-Out is required for the captureactive action.'
        }
        $target = Set-AppForeground
        Start-Sleep -Milliseconds 700
        Invoke-OverlayCapture -Path $Out
    }
    'captureprint' {
        # Renders the overlay window into a bitmap with PrintWindow instead of
        # reading screen pixels, so a foreground window covering the overlay (or
        # a DPI mismatch) cannot corrupt the latency sample.
        if ([string]::IsNullOrWhiteSpace($Out)) {
            throw '-Out is required for the captureprint action.'
        }
        Add-Type -AssemblyName System.Drawing
        $w = $rect.Right - $rect.Left
        $h = $rect.Bottom - $rect.Top
        $bitmap = New-Object System.Drawing.Bitmap($w, $h)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $hdc = $graphics.GetHdc()
        $before = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $ok = [CastProbe]::PrintWindow($overlay, $hdc,
            [CastProbe]::PW_RENDERFULLCONTENT)
        $after = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $graphics.ReleaseHdc($hdc)
        $graphics.Dispose()
        $bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        [pscustomobject]@{
            path = $Out
            beforeMs = $before
            afterMs = $after
            printWindow = $ok
            width = $w
            height = $h
        } | ConvertTo-Json -Compress
    }
    'capturescreen' {
        if ([string]::IsNullOrWhiteSpace($Out)) {
            throw '-Out is required for the capturescreen action.'
        }
        Add-Type -AssemblyName System.Drawing
        Add-Type -AssemblyName System.Windows.Forms
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $before = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0,
            (New-Object System.Drawing.Size($bounds.Width, $bounds.Height)))
        $after = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        $graphics.Dispose()
        $bitmap.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        [pscustomobject]@{
            path = $Out
            beforeMs = $before
            afterMs = $after
            width = $bounds.Width
            height = $bounds.Height
        } | ConvertTo-Json -Compress
    }
    'overlays' {
        $found = New-Object System.Collections.ArrayList
        [CastProbe]::EnumWindows({
            param($h, $l)
            $name = New-Object System.Text.StringBuilder 256
            [void][CastProbe]::GetClassName($h, $name, $name.Capacity)
            if ($name.ToString() -eq 'ScreenCastVideoWindow') {
                $r = New-Object CastProbe+RECT
                [void][CastProbe]::GetWindowRect($h, [ref]$r)
                $ownerPid = 0
                [void][CastProbe]::GetWindowThreadProcessId($h, [ref]$ownerPid)
                [void]$found.Add([pscustomobject]@{
                    hwnd = [int64]$h
                    processId = $ownerPid
                    left = $r.Left
                    top = $r.Top
                    width = $r.Right - $r.Left
                    height = $r.Bottom - $r.Top
                    visible = [CastProbe]::IsWindowVisible($h)
                })
            }
            return $true
        }, [IntPtr]::Zero) | Out-Null
        $found | ConvertTo-Json -Compress
    }
}
