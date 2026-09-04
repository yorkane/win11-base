# Make the Win11 taskbar auto-hidden AND visually gone; run it at every logon.
#
# Measured on win11-wx (Win11 under dockurr/windows, 1280x800, 2026-09-04):
#   - Registry route does not work on this build. StuckRects3\Settings byte 12 is the byte
#     the community points at, but writing 0x02 while explorer is dead and then starting
#     explorer leaves the bar visible with api_state=0, and explorer restores 0x03 the next
#     time the tray state changes.
#   - The switch that works is SHAppBarMessage(ABM_SETSTATE=10, lParam=1) on Shell_TrayWnd,
#     called from inside the console session: SYSTEM tasks and sshd children sit in session
#     0 where FindWindow('Shell_TrayWnd') returns 0.
#   - Timing matters. Fired by an AtLogOn trigger while the shell is still starting, the
#     call is accepted (state=1, GetWindowRect even reports 0,798,1280,846 = off screen) and
#     explorer then repaints the bar. Geometry lies.
#   - Pixels do not. On a solid-black wallpaper a hidden bottom strip is uniformly black;
#     a visible bar gives thousands of non-black samples. Both API reads said "hidden" while
#     the VNC frame clearly showed the bar; only pixels caught it.
#   - Restarting explorer and then applying the switch reliably gives the hidden look
#     (reproduced twice: bottom strip goes fully black in the capture and in VNC).
#
# Design: wait for the shell to settle, calibrate the capture (prove it can see a bar that
# is deliberately shown), then walk cheap -> expensive fixes and stop at the first rung the
# pixels approve. The winning rung is logged so the ladder can be trimmed later.
#
# PS 5.1 gotcha: a function's diagnostics must not use Write-Output, because everything on
# the success stream becomes the return value -- 'if (PixelsHidden ...)' would receive a
# 2-element array and always be true. Use [Console]::WriteLine inside such functions.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$code = @'
using System;
using System.Runtime.InteropServices;
public class TrayHide2 {
  [StructLayout(LayoutKind.Sequential)]
  public struct APPBARDATA {
    public uint cbSize; public IntPtr hWnd; public uint uCallbackMessage;
    public uint uEdge; public int left; public int top; public int right; public int bottom;
    public IntPtr lParam;
  }
  [DllImport("shell32.dll")]
  public static extern IntPtr SHAppBarMessage(uint msg, ref APPBARDATA data);
  [DllImport("user32.dll", SetLastError=true)]
  public static extern IntPtr FindWindow(string cls, string name);
  [DllImport("user32.dll")]
  public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")]
  public static extern bool SetCursorPos(int x, int y);
  [StructLayout(LayoutKind.Sequential)]
  public struct RECT { public int left, top; public int right; public int bottom; }
}
'@
Add-Type -TypeDefinition $code
$size = [Runtime.InteropServices.Marshal]::SizeOf((New-Object TrayHide2+APPBARDATA))
$bounds = ([Windows.Forms.Screen]::PrimaryScreen).Bounds
$strip = 60
function PixelsHidden([string]$tag) {
  # Park the cursor away from the reveal strip first: with auto-hide on, a pointer sitting
  # on the bottom edge keeps the bar revealed by design.
  [void][TrayHide2]::SetCursorPos(640, 300)
  Start-Sleep -Milliseconds 800
  $bmp = New-Object Drawing.Bitmap($bounds.Width, $strip)
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($bounds.Left, $bounds.Bottom - $strip, 0, 0, (New-Object Drawing.Size($bounds.Width, $strip)))
  $bad = 0
  for ($y = 0; $y -lt $strip; $y += 2) {
    for ($x = 0; $x -lt $bounds.Width; $x += 4) {
      $c = $bmp.GetPixel($x, $y)
      if (($c.R + $c.G + $c.B) -gt 40) { $bad += 1 }
    }
  }
  $g.Dispose(); $bmp.Dispose()
  $h = [TrayHide2]::FindWindow('Shell_TrayWnd', $null)
  $r = New-Object TrayHide2+RECT
  [void][TrayHide2]::GetWindowRect($h, [ref]$r)
  [Console]::WriteLine('PIX ' + $tag + ' nonblack=' + $bad + ' api_rect=' + $r.top + ',' + $r.bottom)
  return ($bad -lt 30)
}
function SetHide([int]$on) {
  $h = [TrayHide2]::FindWindow('Shell_TrayWnd', $null)
  if ($h -eq [IntPtr]::Zero) { return $false }
  $p = New-Object TrayHide2+APPBARDATA
  $p.cbSize = $size
  $p.hWnd = $h
  $p.lParam = [IntPtr]$on
  [void][TrayHide2]::SHAppBarMessage(10, [ref]$p)
  return $true
}
# Step 0: let the shell finish building the tray before touching it.
# Do NOT use Progman as a readiness signal: it returns 0 even on a healthy desktop, which
# made the loop burn the whole budget (measured: WAIT9..12 tray=65742 progman=0) and then
# still warn. Shell_TrayWnd plus a live explorer process is the reliable pair.
$settled = $false
for ($i = 1; $i -le 12; $i++) {
  Start-Sleep -Seconds 10
  $h = [TrayHide2]::FindWindow('Shell_TrayWnd', $null)
  if ($h -ne [IntPtr]::Zero -and (Get-Process explorer -ErrorAction SilentlyContinue)) {
    Write-Output ('SETTLED after ' + ($i * 10) + 's hwnd=' + $h)
    $settled = $true
    break
  }
  Write-Output ('WAIT' + $i + ' tray=' + $h)
}
if (-not $settled) { Write-Output 'WARN_shell_not_settled' }
# Calibration: force the bar visible and require the capture to notice it. Otherwise an
# all-black capture (wrong window station) would make every rung below a false positive.
SetHide 0 | Out-Null
Start-Sleep -Seconds 5
if (PixelsHidden 'CAL_shown') { Write-Output 'CALIBRATION_FAILED_capture_all_black'; Write-Output 'ENSURE_HIDDEN_DONE'; exit 2 }
SetHide 1 | Out-Null
Start-Sleep -Seconds 6
if (PixelsHidden 'S1_set_after_settle') { Write-Output 'VERDICT=S1_set_after_settle'; Write-Output 'ENSURE_HIDDEN_DONE'; exit 0 }
# Rung 2: re-assert 0 -> 1 to push explorer into a real appbar relayout.
SetHide 0 | Out-Null
Start-Sleep -Seconds 3
SetHide 1 | Out-Null
Start-Sleep -Seconds 6
if (PixelsHidden 'S2_reassert') { Write-Output 'VERDICT=S2_reassert'; Write-Output 'ENSURE_HIDDEN_DONE'; exit 0 }
# Rung 3: restart explorer (only ever from the console session), then apply.
taskkill /f /im explorer.exe 2>&1 | Out-Null
Start-Sleep -Seconds 4
Start-Process 'C:\Windows\explorer.exe'
Start-Sleep -Seconds 25
SetHide 1 | Out-Null
Start-Sleep -Seconds 6
if (PixelsHidden 'S3_explorer_restart') { Write-Output 'VERDICT=S3_explorer_restart'; Write-Output 'ENSURE_HIDDEN_DONE'; exit 0 }
Write-Output 'VERDICT=none_worked'
Write-Output 'ENSURE_HIDDEN_DONE'
