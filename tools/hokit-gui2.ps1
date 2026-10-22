# hokit-gui2.ps1 -- screenshot / click helper for driving the HoKit (Electron) window.
#
# HoKit rejects unknown Chromium switches (so no DevTools protocol) and does not
# expose its accessibility tree to a plain UIA client (only 1 descendant).  So we
# drive it visually: bring the window to the front, screenshot it, look at the
# PNG, then click window-relative coordinates and screenshot again to confirm.
#
# Coordinates are window-RELATIVE (0,0 = window's top-left, title bar included),
# which is exactly what the saved PNG shows -- no arithmetic with screen origins.
#
# Must run under Windows PowerShell 5.1 for System.Drawing + Add-Type interop.
param(
    [ValidateSet('shot','click','key','type','info')][string]$Mode = 'info',
    [int]$RX = 0,
    [int]$RY = 0,
    [string]$Text = '',
    [string]$Out = 'D:\hbohos\build\hokit.png'
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Drawing

Add-Type @'
using System;
using System.Runtime.InteropServices;
public class W {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int v);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
}
'@
try { [W]::SetProcessDpiAwareness(2) | Out-Null } catch { }

function Get-HoKit {
    $proc = Get-Process -Name HoKit -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
    if (-not $proc) { throw "HoKit 主窗口没找到" }
    [W]::ShowWindow($proc.MainWindowHandle, 9) | Out-Null     # SW_RESTORE
    [W]::SetForegroundWindow($proc.MainWindowHandle) | Out-Null
    Start-Sleep -Milliseconds 900
    $r = New-Object W+RECT
    [W]::GetWindowRect($proc.MainWindowHandle, [ref]$r) | Out-Null
    return @{ Proc = $proc; Hwnd = $proc.MainWindowHandle; Rect = $r }
}

$h = Get-HoKit
$r = $h.Rect
$w = $r.Right - $r.Left; $ht = $r.Bottom - $r.Top

switch ($Mode) {
    'info' {
        Write-Host "PID=$($h.Proc.Id) HWND=$($h.Hwnd)"
        Write-Host "窗口: L=$($r.Left) T=$($r.Top) 尺寸=${w}x${ht}"
        Write-Host "前景=HoKit? $([W]::GetForegroundWindow() -eq $h.Hwnd)"
    }
    'shot' {
        Start-Sleep -Milliseconds 500
        $bmp = New-Object System.Drawing.Bitmap($w, $ht)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($r.Left, $r.Top, 0, 0, (New-Object System.Drawing.Size($w, $ht)))
        $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
        $g.Dispose(); $bmp.Dispose()
        Write-Host "已保存 $Out (${w}x${ht})"
    }
    'click' {
        $sx = $r.Left + $RX; $sy = $r.Top + $RY
        [W]::SetCursorPos($sx, $sy) | Out-Null
        Start-Sleep -Milliseconds 250
        [W]::mouse_event(0x0002, 0, 0, 0, [IntPtr]::Zero)
        Start-Sleep -Milliseconds 90
        [W]::mouse_event(0x0004, 0, 0, 0, [IntPtr]::Zero)
        Write-Host "点击 窗口相对($RX,$RY) -> 屏幕($sx,$sy)"
    }
}
