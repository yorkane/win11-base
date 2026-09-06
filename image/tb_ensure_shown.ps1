# Make the Win11 taskbar persistently VISIBLE and keep it that way; run at every logon.
# Mirror image of tb_ensure_hidden.ps1 (same measurements, opposite target):
#   - Registry route is dead on this build; the switch that works is
#     SHAppBarMessage(ABM_SETSTATE=10, lParam=0) on Shell_TrayWnd, called from inside
#     the console session. SYSTEM tasks and sshd children sit in session 0 where
#     FindWindow('Shell_TrayWnd') returns 0 and the call silently no-ops.
#   - API reads lie on this build (GetWindowRect reported the bar off-screen while the
#     VNC frame clearly showed it). Pixels are the only trustworthy judge: on a
#     solid-black wallpaper a hidden bottom strip is uniformly black, a visible bar
#     yields thousands of nonblack samples.
# Calibration proves the capture sees BOTH states (shown -> nonblack, hidden -> black)
# before any verdict, so "visible" can never be an all-black false positive.
# PS 5.1 gotcha: diagnostics inside these functions must use [Console]::WriteLine,
# not Write-Output -- everything on the success stream becomes the return value.
$ErrorActionPreference = 'Continue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$code = @'
using System;
using System.Runtime.InteropServices;
public class TrayShow {
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
  public static extern bool SetCursorPos(int x, int y);
}
'@
Add-Type -TypeDefinition $code
$size = [Runtime.InteropServices.Marshal]::SizeOf((New-Object TrayShow+APPBARDATA))
$bounds = ([Windows.Forms.Screen]::PrimaryScreen).Bounds
$strip = 60
function PixelsShown([string]$tag) {
  # Park the cursor mid-screen first: while auto-hide is still armed, a pointer on the
  # bottom edge keeps the bar revealed by design and would fake a shown verdict.
  [void][TrayShow]::SetCursorPos(640, 300)
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
  [Console]::WriteLine('PIX ' + $tag + ' nonblack=' + $bad)
  return ($bad -ge 30)
}
function SetShow([int]$on) {
  $h = [TrayShow]::FindWindow('Shell_TrayWnd', $null)
  if ($h -eq [IntPtr]::Zero) { return $false }
  $p = New-Object TrayShow+APPBARDATA
  $p.cbSize = $size
  $p.hWnd = $h
  $p.lParam = [IntPtr]$on
  [void][TrayShow]::SHAppBarMessage(10, [ref]$p)
  return $true
}
# Step 0: let the shell finish building the tray before touching it. Progman is NOT a
# readiness signal (returns 0 on a healthy desktop); Shell_TrayWnd + live explorer is.
$settled = $false
for ($i = 1; $i -le 12; $i++) {
  Start-Sleep -Seconds 10
  $h = [TrayShow]::FindWindow('Shell_TrayWnd', $null)
  if ($h -ne [IntPtr]::Zero -and (Get-Process explorer -ErrorAction SilentlyContinue)) {
    Write-Output ('SETTLED after ' + ($i * 10) + 's hwnd=' + $h)
    $settled = $true
    break
  }
  Write-Output ('WAIT' + $i + ' tray=' + $h)
}
if (-not $settled) { Write-Output 'WARN_shell_not_settled' }
# Calibration: the capture must notice the bar deliberately shown AND deliberately
# hidden. Otherwise an all-black capture (wrong window station) makes "shown" either
# unreachable or a false positive.
SetShow 0 | Out-Null
Start-Sleep -Seconds 5
if (-not (PixelsShown 'CAL_shown')) { Write-Output 'CALIBRATION_FAILED_capture_all_black'; Write-Output 'ENSURE_SHOWN_DONE'; exit 2 }
SetShow 1 | Out-Null
Start-Sleep -Seconds 6
if (PixelsShown 'CAL_hidden') { Write-Output 'CALIBRATION_FAILED_bar_always_shown'; Write-Output 'ENSURE_SHOWN_DONE'; exit 2 }
# Target state: always visible.
SetShow 0 | Out-Null
Start-Sleep -Seconds 6
if (PixelsShown 'S1_set_after_settle') { Write-Output 'VERDICT=S1_set_after_settle'; Write-Output 'ENSURE_SHOWN_DONE'; exit 0 }
# Rung 2: re-assert 1 -> 0 to push explorer into a real appbar relayout.
SetShow 1 | Out-Null
Start-Sleep -Seconds 3
SetShow 0 | Out-Null
Start-Sleep -Seconds 6
if (PixelsShown 'S2_reassert') { Write-Output 'VERDICT=S2_reassert'; Write-Output 'ENSURE_SHOWN_DONE'; exit 0 }
# Rung 3: restart explorer (only ever from the console session), then apply.
taskkill /f /im explorer.exe 2>&1 | Out-Null
Start-Sleep -Seconds 4
Start-Process 'C:\Windows\explorer.exe'
Start-Sleep -Seconds 25
SetShow 0 | Out-Null
Start-Sleep -Seconds 6
if (PixelsShown 'S3_explorer_restart') { Write-Output 'VERDICT=S3_explorer_restart'; Write-Output 'ENSURE_SHOWN_DONE'; exit 0 }
Write-Output 'VERDICT=none_worked'
Write-Output 'ENSURE_SHOWN_DONE'
