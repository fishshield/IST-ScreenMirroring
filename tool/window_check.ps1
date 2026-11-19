[CmdletBinding()]
param(
    [string]$OutDir = '$env:TEMP'
)

# Runtime probe for the independent video window + tray behaviour.
# Run against a live `screen_cast_demo` instance; prints window state and saves
# screenshots of the video window and the notification area.

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class WinProbe {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  delegate bool Proc(IntPtr h, IntPtr l);

  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] static extern bool EnumWindows(Proc p, IntPtr l);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int m);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint p);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();

  static List<IntPtr> found = new List<IntPtr>();
  static string targetClass = "";
  static bool Callback(IntPtr h, IntPtr l) {
    var c = new StringBuilder(256); GetClassName(h, c, 256);
    if (c.ToString() == targetClass) found.Add(h);
    return true;
  }

  public static IntPtr[] Find(string className) {
    targetClass = className; found.Clear();
    EnumWindows(Callback, IntPtr.Zero);
    return found.ToArray();
  }

  public static string Describe(IntPtr h) {
    RECT r; GetWindowRect(h, out r);
    long style = GetWindowLongPtr(h, -16).ToInt64();
    uint pid; GetWindowThreadProcessId(h, out pid);
    var title = new StringBuilder(128); GetWindowTextW(h, title, 128);
    return string.Format("hwnd={0} title='{1}' rect=({2},{3})-({4},{5}) {6}x{7} thickframe={8} visible={9} iconic={10} pid={11}",
      h, title, r.L, r.T, r.R, r.B, r.R - r.L, r.B - r.T,
      (style & 0x40000L) != 0 ? "yes" : "no", IsWindowVisible(h), IsIconic(h), pid);
  }
}
'@

[void][WinProbe]::SetProcessDPIAware()

function Save-Region {
    param([int]$Left, [int]$Top, [int]$Width, [int]$Height, [string]$Path)
    $bitmap = New-Object System.Drawing.Bitmap($Width, $Height)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($Left, $Top, 0, 0, (New-Object System.Drawing.Size($Width, $Height)))
    $graphics.Dispose()
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
}

$video = [WinProbe]::Find('ScreenCastVideoWindow')
$flutter = [WinProbe]::Find('FLUTTER_RUNNER_WIN32_WINDOW')
if ($video.Length -eq 0) { throw 'video window not found' }
$videoHwnd = $video[0]
$rootHwnd = $null
foreach ($h in $flutter) {
    $text = [WinProbe]::Describe($h)
    if ($text -match "title='screen_cast_demo'") { $rootHwnd = $h }
}
if ($null -eq $rootHwnd) { throw 'Flutter main window not found' }

Write-Host "video: $([WinProbe]::Describe($videoHwnd))"
Write-Host "main : $([WinProbe]::Describe($rootHwnd))"

# 1. Bring the video window to the front and capture it.
[void][WinProbe]::ShowWindow($videoHwnd, 9)
[void][WinProbe]::SetForegroundWindow($videoHwnd)
Start-Sleep -Milliseconds 500
$r = New-Object WinProbe+RECT
[void][WinProbe]::GetWindowRect($videoHwnd, [ref]$r)
Save-Region -Left $r.L -Top $r.T -Width ($r.R - $r.L) -Height ($r.B - $r.T) `
    -Path (Join-Path $OutDir 'video_window_normal.png')
Write-Host "step1 normal visible=$([WinProbe]::IsWindowVisible($videoHwnd))"

# 2. F11 -> fullscreen.
[void][WinProbe]::PostMessage($videoHwnd, 0x0100, [IntPtr]0x7A, [IntPtr]::Zero)
Start-Sleep -Milliseconds 700
Write-Host "step2 after F11: $([WinProbe]::Describe($videoHwnd))"
[void][WinProbe]::GetWindowRect($videoHwnd, [ref]$r)
Save-Region -Left $r.L -Top $r.T -Width ($r.R - $r.L) -Height ($r.B - $r.T) `
    -Path (Join-Path $OutDir 'video_window_fullscreen.png')

# 3. Esc -> back to windowed.
[void][WinProbe]::PostMessage($videoHwnd, 0x0100, [IntPtr]0x1B, [IntPtr]::Zero)
Start-Sleep -Milliseconds 700
Write-Host "step3 after Esc: $([WinProbe]::Describe($videoHwnd))"

# 4. Closing the video window hides it and keeps the process alive.
[void][WinProbe]::PostMessage($videoHwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 500
$alive = Get-Process screen_cast_demo -ErrorAction SilentlyContinue
Write-Host "step4 video WM_CLOSE: visible=$([WinProbe]::IsWindowVisible($videoHwnd)) processAlive=$([bool]$alive)"

# 5. Closing the Flutter window minimizes to the tray; the video window and the
#    capture session stay alive.
[void][WinProbe]::ShowWindow($videoHwnd, 5)
[void][WinProbe]::PostMessage($rootHwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
Start-Sleep -Milliseconds 700
$alive = Get-Process screen_cast_demo -ErrorAction SilentlyContinue
Write-Host "step5 main WM_CLOSE: mainVisible=$([WinProbe]::IsWindowVisible($rootHwnd)) videoVisible=$([WinProbe]::IsWindowVisible($videoHwnd)) processAlive=$([bool]$alive)"

# 6. Notification area, to confirm the tray icon exists.
$screen = [System.Windows.Forms.SystemInformation]::VirtualScreen
$trayLeft = $screen.Right - 420
$trayTop = $screen.Bottom - 48
Save-Region -Left $trayLeft -Top $trayTop -Width 420 -Height 48 `
    -Path (Join-Path $OutDir 'tray_area.png')
Write-Host "step6 tray capture saved"

# 7. Tray callback path: double click should re-show the main window.
[void][WinProbe]::PostMessage($rootHwnd, 0x8051, [IntPtr]::Zero, [IntPtr]0x0203)
Start-Sleep -Milliseconds 500
Write-Host "step7 after tray double-click: mainVisible=$([WinProbe]::IsWindowVisible($rootHwnd))"
