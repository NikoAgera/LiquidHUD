# =====================================================================
#  LiquidHUD v16  -  game overlay system monitor for Windows
#  Pure PowerShell + WPF (built into Windows). Nothing to install.
#  https://github.com/NikoAgera/LiquidHUD
#
#  Lives in the system tray (taskbar > "Show hidden icons"):
#    right-click the tray icon = menu | double-click = Settings
#
#  HOTKEYS (work even inside games):
#    Ctrl+Alt+S  = open Settings
#    Ctrl+Alt+O  = overlay on/off
#    Ctrl+Alt+P  = cycle overlay position
#    Ctrl+Alt+M  = free move (drag it anywhere, press again to lock)
#
#  Lightweight by design:
#    - runs at BelowNormal priority (your game always wins)
#    - unticked metrics are not collected at all (GPU / top apps are the heaviest)
#    - software rendering, default refresh 2s (1s / 2s / 5s), memory trimmed every 60s
# =====================================================================

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, 'Global\LiquidHUD_Mutex', [ref]$createdNew)
if (-not $createdNew) { exit }

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class LhNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder sb, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // real on-screen rectangle (same coordinate space as Cursor.Position)
    public static int[] Rect(IntPtr h) { RECT r; GetWindowRect(h, out r); return new int[] { r.Left, r.Top, r.Right, r.Bottom }; }

    // is the foreground window a fullscreen / borderless-fullscreen app (game, video)?
    public static bool FullscreenForeground(uint ownPid) {
        IntPtr h = GetForegroundWindow(); if (h == IntPtr.Zero) return false;
        uint pid; GetWindowThreadProcessId(h, out pid); if (pid == ownPid) return false;
        StringBuilder sb = new StringBuilder(256); GetClassName(h, sb, 256); string c = sb.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd") return false;
        RECT r; if (!GetWindowRect(h, out r)) return false;
        MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
        return r.Left <= mi.rcMonitor.Left && r.Top <= mi.rcMonitor.Top && r.Right >= mi.rcMonitor.Right && r.Bottom >= mi.rcMonitor.Bottom;
    }

    // average brightness (0..1) of a small screen strip, -1 on failure
    public static double Luma(int x, int y, int w, int h) {
        if (w < 4 || h < 2) return -1;
        try {
            using (var bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb))
            using (var g = System.Drawing.Graphics.FromImage(bmp)) {
                g.CopyFromScreen(x, y, 0, 0, new System.Drawing.Size(w, h));
                var d = bmp.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                byte[] buf = new byte[d.Stride * h]; Marshal.Copy(d.Scan0, buf, 0, buf.Length); int stride = d.Stride; bmp.UnlockBits(d);
                long sum = 0; int n = 0;
                for (int yy = 0; yy < h; yy += 2) for (int xx = 0; xx < w; xx += 3) { int i = yy * stride + xx * 4; sum += buf[i + 2] * 299 + buf[i + 1] * 587 + buf[i] * 114; n++; }
                return n == 0 ? -1 : sum / (n * 255000.0);
            }
        } catch { return -1; }
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr p);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);

    public static void MakeOverlay(IntPtr h) {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        ex |= 0x20 | 0x80 | 0x08000000 | 0x80000;
        SetWindowLongPtr(h, -20, new IntPtr(ex));
    }
    public static void ClickThrough(IntPtr h, bool on) {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        if (on) ex |= 0x20; else ex &= ~0x20L;
        SetWindowLongPtr(h, -20, new IntPtr(ex));
    }
    public static void ToolWindow(IntPtr h) {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        SetWindowLongPtr(h, -20, new IntPtr(ex | 0x80));
    }
    public static void Top(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x1 | 0x2 | 0x10); }
    public static void HideConsole() { IntPtr c = GetConsoleWindow(); if (c != IntPtr.Zero) ShowWindow(c, 0); }
    public static void Trim() { GC.Collect(); GC.WaitForPendingFinalizers(); EmptyWorkingSet(GetCurrentProcess()); }
}

public class LhHotkeys : System.Windows.Forms.NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr h, int id, uint mod, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr h, int id);
    public event Action<int> Pressed;
    public LhHotkeys() { CreateHandle(new System.Windows.Forms.CreateParams()); }
    public bool Register(int id, uint mod, uint vk) { return RegisterHotKey(Handle, id, mod, vk); }
    protected override void WndProc(ref System.Windows.Forms.Message m) {
        if (m.Msg == 0x0312 && Pressed != null) Pressed(m.WParam.ToInt32());
        base.WndProc(ref m);
    }
    public void Dispose() { for (int i = 1; i <= 9; i++) UnregisterHotKey(Handle, i); DestroyHandle(); }
}
"@
[LhNative]::HideConsole()
# Small, mostly-static layered windows are cheaper to draw on the CPU than through Direct3D:
# no D3D device (~100+ MB), no GPU->CPU copy of every frame.
try { [Windows.Media.RenderOptions]::ProcessRenderMode = [Windows.Interop.RenderMode]::SoftwareOnly } catch {}
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch {}


# ---------- settings ----------
$cfgDir  = Join-Path $env:APPDATA 'LiquidHUD'
$cfgFile = Join-Path $cfgDir 'settings.json'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
$cfg = [pscustomobject]@{
    Look = 'Outline'; Overlay = $true; OverlayAll = $true; OverlayPos = 2; OverlayFree = $false; OverlayAutoHide = $true; GameMode = $true; AdaptiveInk = $true; OverlayX = 0.98; OverlayY = 0.01
    Interval = 2; Clock24 = $true; TrayTipShown = $false; Animations = $true; Icons = $true
    OsdShow = [pscustomobject][ordered]@{ Cpu = $true; Gpu = $true; Ram = $true; Net = $true; TopC = $true; TopR = $false; Batt = $false; Graph = $true; Clock = $true }
}
if (Test-Path $cfgFile) {
    try {
        $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties.Name) { if ($p -ne 'OsdShow' -and $null -ne $j.$p) { $cfg.$p = $j.$p } }
        if ($j.OsdShow) { foreach ($pp in $cfg.OsdShow.PSObject.Properties.Name) { if ($null -ne $j.OsdShow.$pp) { $cfg.OsdShow.$pp = [bool]$j.OsdShow.$pp } } }
    } catch {}
}
if (@(1, 2, 5) -notcontains [int]$cfg.Interval) { $cfg.Interval = 2 }
if ([int]$cfg.OverlayPos -lt 0 -or [int]$cfg.OverlayPos -gt 6) { $cfg.OverlayPos = 2 }
$cfg.OverlayFree = $false
if (@('Outline', 'Solid') -notcontains $cfg.Look) { $cfg.Look = 'Outline' }
function Save-Cfg { try { $cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $cfgFile -Encoding UTF8 } catch {} }
function Want-Table {
    $w = @{}
    foreach ($p in $cfg.OsdShow.PSObject.Properties) { $w[$p.Name] = [bool]($cfg.Overlay -and $p.Value) }
    if ($w.Graph) { $w.Cpu = $true; $w.Ram = $true }
    $w
}

# =====================================================================
#  BACKGROUND COLLECTOR (separate thread, low priority, only collects what is enabled)
# =====================================================================
$sync = [hashtable]::Synchronized(@{ Stop = $false; Data = $null; OwnPid = $PID; Want = (Want-Table); Interval = [int]$cfg.Interval })

$collector = {
    param($sync)
    Add-Type -AssemblyName System.Windows.Forms, Microsoft.VisualBasic
    try { [Threading.Thread]::CurrentThread.Priority = 'BelowNormal' } catch {}
    $cores = [Environment]::ProcessorCount
    $skip = @{ 'Idle' = 1; 'System' = 1; 'Registry' = 1; 'Memory Compression' = 1; 'Secure System' = 1 }

    $cpuC = $null
    try { $cpuC = New-Object Diagnostics.PerformanceCounter('Processor Information', '% Processor Utility', '_Total'); [void]$cpuC.NextValue() }
    catch { try { $cpuC = New-Object Diagnostics.PerformanceCounter('Processor', '% Processor Time', '_Total'); [void]$cpuC.NextValue() } catch {} }

    # GPU: read the whole 'GPU Engine' category ONCE per tick and compute utilisation from raw samples.
    # (Old way: ~100 PerformanceCounter objects, and every NextValue() re-read the whole category.)
    $gpuCat = $null; $gpuPrev = @{}

    $ci = New-Object Microsoft.VisualBasic.Devices.ComputerInfo
    function NetBytes {
        $rx = 0L; $tx = 0L
        foreach ($n in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($n.OperationalStatus -ne 'Up') { continue }
            if ($n.NetworkInterfaceType -eq 'Loopback' -or $n.NetworkInterfaceType -eq 'Tunnel') { continue }
            try { $s = $n.GetIPStatistics(); $rx += $s.BytesReceived; $tx += $s.BytesSent } catch {}
        }
        ,@($rx, $tx)
    }
    $netPrev = NetBytes
    $netSw = [Diagnostics.Stopwatch]::StartNew()
    $procSw = [Diagnostics.Stopwatch]::StartNew()
    $procPrev = @{}
    $diskSw = $null
    $trimSw = [Diagnostics.Stopwatch]::StartNew()
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $selfPrev = $self.TotalProcessorTime.TotalSeconds
    $selfSw = [Diagnostics.Stopwatch]::StartNew()
    $d = @{ TopC = ''; TopR = ''; TopRBytes = 0 }

    while (-not $sync.Stop) {
        $loop = [Diagnostics.Stopwatch]::StartNew()
        $w = $sync.Want
        try {
            $n = @{ Cores = $cores }
            $n.Cpu = if ($cpuC) { [Math]::Min(100, $cpuC.NextValue()) } else { 0 }

            # GPU (only when enabled): one ReadCategory() for all engines, 3D engines summed
            if ($w.Gpu) {
                if ($null -eq $gpuCat) { try { $gpuCat = New-Object Diagnostics.PerformanceCounterCategory('GPU Engine') } catch { $gpuCat = $false } }
                $n.Gpu = -1
                if ($gpuCat) {
                    try {
                        $col = $gpuCat.ReadCategory()['Utilization Percentage']
                        $g = 0.0; $seen = 0; $cur = @{}
                        foreach ($inst in $col.Values) {
                            $nm = $inst.InstanceName
                            if ($nm -notlike '*engtype_3D*') { continue }
                            $smp = $inst.Sample; $cur[$nm] = $smp; $seen++
                            if ($gpuPrev.ContainsKey($nm)) { $g += [Diagnostics.CounterSample]::Calculate($gpuPrev[$nm], $smp) }
                        }
                        $gpuPrev = $cur
                        if ($seen) { $n.Gpu = [Math]::Min(100, $g) }
                    } catch {}
                }
            } else { $gpuPrev = @{}; $n.Gpu = -1 }

            if ($w.Ram) { $n.RamTot = [double]$ci.TotalPhysicalMemory; $n.RamUsed = $n.RamTot - [double]$ci.AvailablePhysicalMemory }

            if ($w.Net) {
                $now = NetBytes; $dt = [Math]::Max(0.2, $netSw.Elapsed.TotalSeconds); $netSw.Restart()
                $n.Down = [Math]::Max(0, ($now[0] - $netPrev[0]) / $dt); $n.Up = [Math]::Max(0, ($now[1] - $netPrev[1]) / $dt)
                $netPrev = $now
            }

            if ($w.Batt) {
                $ps = [System.Windows.Forms.SystemInformation]::PowerStatus
                $n.NoBatt = [bool]($ps.BatteryChargeStatus -band [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery)
                $n.Batt = $ps.BatteryLifePercent * 100
                $n.Charging = ($ps.PowerLineStatus -eq 'Online')
            }

            # Top apps: scan processes every 5s, only when enabled
            if (($w.TopC -or $w.TopR) -and $procSw.Elapsed.TotalSeconds -ge 8) {
                $el = $procSw.Elapsed.TotalSeconds; $procSw.Restart()
                $cpuBy = @{}; $ramBy = @{}; $cur = @{}
                foreach ($p in [Diagnostics.Process]::GetProcesses()) {
                    $nm = $p.ProcessName
                    if ($p.Id -eq 0 -or $p.Id -eq $sync.OwnPid -or $skip.ContainsKey($nm)) { $p.Dispose(); continue }
                    if ($w.TopR) { try { $ramBy[$nm] = [double]$ramBy[$nm] + $p.WorkingSet64 } catch {} }
                    if ($w.TopC) {
                        try {
                            $t = $p.TotalProcessorTime.TotalSeconds; $cur[$p.Id] = $t
                            if ($procPrev.ContainsKey($p.Id)) { $cpuBy[$nm] = [double]$cpuBy[$nm] + ($t - $procPrev[$p.Id]) }
                        } catch {}
                    }
                    $p.Dispose()
                }
                $procPrev = $cur
                $bk = $null; $bv = -1.0
                foreach ($e in $cpuBy.GetEnumerator()) { if ($e.Value -gt $bv) { $bv = $e.Value; $bk = $e.Key } }
                if ($bk) { $pc = [Math]::Min(100, $bv / ($el * $cores) * 100); $d.TopC = '{0}  {1:N0}%' -f $bk, $pc; $d.TopCName = $bk; $d.TopCPct = $pc }
                $bk = $null; $bv = -1.0
                foreach ($e in $ramBy.GetEnumerator()) { if ($e.Value -gt $bv) { $bv = $e.Value; $bk = $e.Key } }
                if ($bk) { $d.TopR = $bk; $d.TopRBytes = $bv }
                $cpuBy = $null; $ramBy = $null
            }
            $n.TopC = $d.TopC; $n.TopCName = $d.TopCName; $n.TopCPct = $d.TopCPct; $n.TopR = $d.TopR; $n.TopRBytes = $d.TopRBytes

            # how much LiquidHUD itself is using
            $self.Refresh()
            $st = $self.TotalProcessorTime.TotalSeconds; $se = [Math]::Max(0.2, $selfSw.Elapsed.TotalSeconds); $selfSw.Restart()
            $n.SelfCpu = ($st - $selfPrev) / ($se * $cores) * 100; $selfPrev = $st
            $n.SelfRam = $self.WorkingSet64
            $n.SelfPriv = $self.PrivateMemorySize64
            $n.SelfWs = $self.WorkingSet64

            $sync.Data = $n

            if ($trimSw.Elapsed.TotalSeconds -ge 60) { [LhNative]::Trim(); $trimSw.Restart() }
        } catch {}
        $iv = [int]$sync.Interval * 1000
        while ($loop.ElapsedMilliseconds -lt $iv -and -not $sync.Stop) { Start-Sleep -Milliseconds 200 }
    }
}

$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$bg = [powershell]::Create(); $bg.Runspace = $rs
[void]$bg.AddScript($collector).AddArgument($sync)
$bgHandle = $bg.BeginInvoke()

# =====================================================================
#  SHARED HELPERS
# =====================================================================
$bc = New-Object Windows.Media.BrushConverter
function Brush($hex) { $b = $bc.ConvertFromString($hex); $b.Freeze(); $b }
# keep a window fully inside the work area of the monitor its centre is on
function Clamp-ToScreen($w) {
    $sc = [System.Windows.Forms.Screen]::FromHandle((Win-Handle $w)).WorkingArea
    $k = $script:dpi
    try { $k = [Windows.PresentationSource]::FromVisual($w).CompositionTarget.TransformToDevice.M11 } catch {}
    if (-not $k) { $k = 1 }
    $L = $sc.Left / $k; $T = $sc.Top / $k; $R = $sc.Right / $k; $B = $sc.Bottom / $k
    $ww = $w.ActualWidth; $hh = $w.ActualHeight
    $x = [Math]::Max($L, [Math]::Min($w.Left, $R - $ww)); $y = [Math]::Max($T, [Math]::Min($w.Top, $B - $hh))
    if ($x -ne $w.Left) { $w.Left = $x }
    if ($y -ne $w.Top) { $w.Top = $y }
}
function Win-Handle($w) { (New-Object Windows.Interop.WindowInteropHelper($w)).EnsureHandle() }

$textShadow = New-Object Windows.Media.Effects.DropShadowEffect
$textShadow.BlurRadius = 4; $textShadow.ShadowDepth = 0; $textShadow.Opacity = 1; $textShadow.Color = [Windows.Media.Colors]::Black
$textShadow.Freeze()
$textShadowW = New-Object Windows.Media.Effects.DropShadowEffect
$textShadowW.BlurRadius = 4; $textShadowW.ShadowDepth = 0; $textShadowW.Opacity = 1; $textShadowW.Color = [Windows.Media.Colors]::White; $textShadowW.Freeze()

# =====================================================================
#  GAME OVERLAY
# =====================================================================
$osdXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" Topmost="True"
        ShowInTaskbar="False" ShowActivated="False" Focusable="False" IsHitTestVisible="False"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize"
        FontFamily="Segoe UI Variable Display, Segoe UI" UseLayoutRounding="True">
  <Grid Margin="1">
  <Border x:Name="oHandle" Width="110" Height="5" CornerRadius="2.5" Background="#E6FFFFFF" BorderBrush="#73000000" BorderThickness="0.6" Visibility="Collapsed" Margin="6,3,6,3"/>
  <Grid x:Name="oFull" RenderTransformOrigin="0.5,0">
    <Grid.RenderTransform><ScaleTransform x:Name="oScale" ScaleX="1" ScaleY="1"/></Grid.RenderTransform>
  <Border x:Name="oHalo" CornerRadius="12" Margin="-1" BorderThickness="1" BorderBrush="#66000000"/>
  <Border x:Name="oBg" CornerRadius="11" Background="#F00C0E16" BorderBrush="#40FFFFFF" BorderThickness="1"/>
  <Border x:Name="oPad" Padding="9,4,10,5">
    <StackPanel x:Name="oContent" Orientation="Horizontal" TextBlock.FontSize="12.5" Typography.NumeralAlignment="Tabular" VerticalAlignment="Center">
      <StackPanel x:Name="sCpu" Orientation="Horizontal"><Border x:Name="dCpu" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iCpu" Width="14" Height="14" Stretch="Uniform" Stroke="#85B7EB" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M7 7h10v10H7z M10 10h4v4h-4z M10 3v4 M14 3v4 M10 17v4 M14 17v4 M3 10h4 M3 14h4 M17 10h4 M17 14h4"/><TextBlock x:Name="lCpu" Text="CPU" Foreground="#A6FFFFFF" FontWeight="SemiBold" Margin="0,0,3,0"/><TextBlock x:Name="oCpu" Text="--" Foreground="White" FontWeight="Bold"/></StackPanel>
      <StackPanel x:Name="sGpu" Orientation="Horizontal"><Border x:Name="dGpu" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iGpu" Width="14" Height="14" Stretch="Uniform" Stroke="#9FE1CB" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M6.5 8h11a4.5 4.5 0 0 1 4.3 5.8l-.7 2.3a2.5 2.5 0 0 1-4.3 .8L15 15h-6l-1.8 1.9a2.5 2.5 0 0 1-4.3 -.8l-.7 -2.3A4.5 4.5 0 0 1 6.5 8z M8 10.5v3 M6.5 12h3 M15.5 11.5h.01 M17.5 12.5h.01"/><TextBlock x:Name="lGpu" Text="GPU" Foreground="#A6FFFFFF" FontWeight="SemiBold" Margin="0,0,3,0"/><TextBlock x:Name="oGpu" Text="--" Foreground="#9FE1CB" FontWeight="Bold"/></StackPanel>
      <StackPanel x:Name="sRam" Orientation="Horizontal"><Border x:Name="dRam" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iRam" Width="14" Height="14" Stretch="Uniform" Stroke="#AFA9EC" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M3 7h18v9H3z M7 10h2v3H7z M11 10h2v3h-2z M15 10h2v3h-2z M6 16v3 M10 16v3 M14 16v3 M18 16v3"/><TextBlock x:Name="lRam" Text="RAM" Foreground="#A6FFFFFF" FontWeight="SemiBold" Margin="0,0,3,0"/><TextBlock x:Name="oRam" Text="--" Foreground="White" FontWeight="Bold"/></StackPanel>
      <StackPanel x:Name="sGraph" Orientation="Horizontal"><Border x:Name="dGraph" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/>
        <Border Width="56" Height="18" CornerRadius="4" Background="#1AFFFFFF" ClipToBounds="True" VerticalAlignment="Center">
          <Canvas><Polyline x:Name="oLineRam" Stroke="#AFA9EC" StrokeThickness="1.3" StrokeLineJoin="Round"/><Polyline x:Name="oLineCpu" Stroke="#85B7EB" StrokeThickness="1.3" StrokeLineJoin="Round"/></Canvas>
        </Border>
      </StackPanel>
      <StackPanel x:Name="sNet" Orientation="Horizontal"><Border x:Name="dNet" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iDown" Width="12" Height="12" Stretch="Uniform" Stroke="#5DCAA5" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,3,0" Data="M12 4v15 M6 13l6 6l6 -6"/><TextBlock x:Name="lDown" Text="&#x2193;" Foreground="#A6FFFFFF" Margin="0,0,3,0"/><TextBlock x:Name="oDown" Foreground="White"/><Border Width="7"/><Path x:Name="iUp" Width="12" Height="12" Stretch="Uniform" Stroke="#F0997B" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,3,0" Data="M12 20v-15 M6 11l6 -6l6 6"/><TextBlock x:Name="lUp" Text="&#x2191;" Foreground="#A6FFFFFF" Margin="0,0,3,0"/><TextBlock x:Name="oUp" Foreground="White"/></StackPanel>
      <StackPanel x:Name="sTopC" Orientation="Horizontal"><Border x:Name="dTopC" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iTopC" Width="14" Height="14" Stretch="Uniform" Stroke="#FAC775" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M4 5h16v14H4z M4 9h16 M7 7h.01 M10 7h.01"/><TextBlock x:Name="oTopCName" Foreground="#CCFFFFFF" MaxWidth="110" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="oTopCVal" Foreground="White" FontWeight="SemiBold" Margin="5,0,0,0"/></StackPanel>
      <StackPanel x:Name="sTopR" Orientation="Horizontal"><Border x:Name="dTopR" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iTopR" Width="14" Height="14" Stretch="Uniform" Stroke="#AFA9EC" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M3 7h18v9H3z M7 10h2v3H7z M11 10h2v3h-2z M15 10h2v3h-2z M6 16v3 M10 16v3 M14 16v3 M18 16v3"/><TextBlock x:Name="oTopRName" Foreground="#CCFFFFFF" MaxWidth="100" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="oTopRVal" Foreground="White" FontWeight="SemiBold" Margin="5,0,0,0"/></StackPanel>
      <StackPanel x:Name="sBatt" Orientation="Horizontal"><Border x:Name="dBatt" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iBatt" Width="14" Height="14" Stretch="Uniform" Stroke="#97C459" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M3 8h15v8H3z M21 11v2"/><TextBlock x:Name="oBatt" Foreground="White" FontWeight="SemiBold"/></StackPanel>
      <StackPanel x:Name="sClock" Orientation="Horizontal"><Border x:Name="dClock" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><Path x:Name="iClock" Width="14" Height="14" Stretch="Uniform" Stroke="#E6FFFFFF" StrokeThickness="1.7" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round" VerticalAlignment="Center" Margin="0,0,4,0" Data="M12 3a9 9 0 1 1 0 18a9 9 0 1 1 0 -18z M12 7v5l3 2"/><TextBlock x:Name="oClock" Foreground="White"/></StackPanel>
    </StackPanel>
  </Border>
  </Grid>
  </Grid>
</Window>
"@

$osdKeys = @('Cpu', 'Gpu', 'Ram', 'Graph', 'Net', 'TopC', 'TopR', 'Batt', 'Clock')
$osdLabels = [ordered]@{ Cpu = 'CPU'; Gpu = 'GPU'; Ram = 'RAM'; Graph = 'Mini graph'; Net = 'Network'; TopC = 'Top CPU app'; TopR = 'Top RAM app'; Batt = 'Battery'; Clock = 'Clock' }
$posNames = @('Top left', 'Top center', 'Top right', 'Bottom left', 'Bottom right', 'Custom', 'Bottom center')
$posOrder = @(0, 1, 2, 3, 6, 4, 5)   # order shown in Settings / cycled by Ctrl+Alt+P
$script:osds = @()
$outlineEdgeDark = Brush '#8C000000'; $haloLight = Brush '#80FFFFFF'; $haloDark = Brush '#66000000'
$pillLight = Brush '#E6FFFFFF'; $pillDark = Brush '#E612141A'
$inkDark = Brush '#12141A'; $hotDark = Brush '#A32D2D'
$freeEdge = Brush '#9FE1CB'; $osdEdge = Brush '#40FFFFFF'; $outlineEdge = Brush '#73FFFFFF'   # Outline frame: white at 45% opacity, 1 px
$solidFill = Brush '#F20C0E16'; $clearFill = Brush '#00000000'; $grabFill = Brush '#40000000'
$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:dpi = $g.DpiX / 96.0; $g.Dispose()   # refined from the first shown window

function Place-Osd($o) {
    if ($cfg.OverlayFree) { return }     # user is dragging it around
    $w = $o.Win; $a = $o.Screen.WorkingArea
    $L = $a.Left / $script:dpi; $T = $a.Top / $script:dpi; $R = $a.Right / $script:dpi; $B = $a.Bottom / $script:dpi
    $ww = $w.ActualWidth; $hh = $w.ActualHeight; $m = if ($o.Collapsed) { 3 } else { 4 }
    switch ([int]$cfg.OverlayPos) {
        0 { $x = $L + $m; $y = $T + $m }
        1 { $x = ($L + $R - $ww) / 2; $y = $T + $m }
        2 { $x = $R - $ww - $m; $y = $T + $m }
        3 { $x = $L + $m; $y = $B - $hh - $m }
        4 { $x = $R - $ww - $m; $y = $B - $hh - $m }
        6 { $x = ($L + $R - $ww) / 2; $y = $B - $hh - $m }
        default {
            # custom: saved as a fraction of the screen, so it lands in the same spot on every monitor
            $x = $L + [double]$cfg.OverlayX * [Math]::Max(0, ($R - $L - $ww))
            $y = $T + [double]$cfg.OverlayY * [Math]::Max(0, ($B - $T - $hh))
        }
    }
    $x = [Math]::Round($x); $y = [Math]::Round($y)
    if ([Math]::Abs($w.Left - $x) -gt 0.5) { $w.Left = $x }
    if ([Math]::Abs($w.Top - $y) -gt 0.5) { $w.Top = $y }
}
function Apply-OsdMetrics($o) {
    $first = $true
    foreach ($k in $osdKeys) {
        $on = [bool]$cfg.OsdShow.$k
        $o.Seg[$k].Visibility = if ($on) { 'Visible' } else { 'Collapsed' }
        $o.Div[$k].Visibility = if ($on -and -not $first) { 'Visible' } else { 'Collapsed' }   # no divider before the first item
        if ($on) { $first = $false }
    }
    $ic = [bool]$cfg.Icons
    foreach ($e in $o.IconEls) { $e.Visibility = if ($ic) { 'Visible' } else { 'Collapsed' } }
    foreach ($e in $o.LabelEls) { $e.Visibility = if ($ic) { 'Collapsed' } else { 'Visible' } }
    foreach ($k in $osdKeys) { $o.Seg[$k].MinWidth = 0 }   # reset the grow-only widths (metrics / clock format changed)
    Apply-OsdLook $o
}
function Build-Osds {
    foreach ($o in $script:osds) { try { $o.Win.Close() } catch {} }
    $script:osds = @()
    if (-not $cfg.Overlay) { $hoverTimer.Stop(); $watchTimer.Stop(); return }
    $screens = if ($cfg.OverlayAll) { [System.Windows.Forms.Screen]::AllScreens } else { @([System.Windows.Forms.Screen]::PrimaryScreen) }
    foreach ($sc in $screens) {
        $w = [Windows.Markup.XamlReader]::Parse($osdXaml)
        $h = Win-Handle $w
        [LhNative]::MakeOverlay($h)
        $w.Left = $sc.WorkingArea.Left / $script:dpi; $w.Top = $sc.WorkingArea.Top / $script:dpi
        $seg = @{}; $div = @{}; foreach ($k in $osdKeys) { $seg[$k] = $w.FindName("s$k"); $div[$k] = $w.FindName("d$k") }
        $w.Add_SizeChanged({ param($sn, $e); foreach ($oo in $script:osds) { if ($oo.Win -eq $sn) { Place-Osd $oo } } })
        $w.Add_MouseLeftButtonDown({
            param($sn, $e)
            if (-not $cfg.OverlayFree) { return }
            try { $sn.DragMove() } catch {}
            Clamp-ToScreen $sn
            Save-OsdSpot $sn
        })
        $o = @{ Win = $w; H = $h; Screen = $sc; Seg = $seg; Div = $div; Bg = $w.FindName('oBg'); Halo = $w.FindName('oHalo'); Body = $w.FindName('oContent'); Pad = $w.FindName('oPad')
                Cpu = $w.FindName('oCpu'); Gpu = $w.FindName('oGpu'); Ram = $w.FindName('oRam'); Down = $w.FindName('oDown'); Up = $w.FindName('oUp')
                TopCName = $w.FindName('oTopCName'); TopCVal = $w.FindName('oTopCVal'); TopRName = $w.FindName('oTopRName'); TopRVal = $w.FindName('oTopRVal')
                Batt = $w.FindName('oBatt'); Clock = $w.FindName('oClock'); LineCpu = $w.FindName('oLineCpu'); LineRam = $w.FindName('oLineRam')
                Full = $w.FindName('oFull'); Scale = $w.FindName('oScale'); Handle = $w.FindName('oHandle'); IconEls = @(foreach ($nm in 'iCpu','iGpu','iRam','iDown','iUp','iTopC','iTopR','iBatt','iClock') { $w.FindName($nm) }); LabelEls = @(foreach ($nm in 'lCpu','lGpu','lRam','lDown','lUp') { $w.FindName($nm) })
                Collapsed = $false; LeaveAt = $null; Closing = $false; Q = 1.0; Dir = 0; LastT = 0.0; Dark = $false; Shrink = @{}; Ink = (Collect-Ink $w) }
        Apply-OsdMetrics $o
        $w.Show(); $w.UpdateLayout()
        try { $script:dpi = [Windows.PresentationSource]::FromVisual($w).CompositionTarget.TransformToDevice.M11 } catch {}
        Place-Osd $o
        $script:osds += $o
    }
    Apply-Free
    Apply-AutoHide
    $watchTimer.Start()
}
# remember where the user dropped the overlay (fraction of that monitor)
function Save-OsdSpot($w) {
    $cx = [int](($w.Left + $w.ActualWidth / 2) * $script:dpi); $cy = [int](($w.Top + $w.ActualHeight / 2) * $script:dpi)
    $sc = [System.Windows.Forms.Screen]::FromPoint((New-Object System.Drawing.Point($cx, $cy)))
    $a = $sc.WorkingArea
    $L = $a.Left / $script:dpi; $T = $a.Top / $script:dpi; $scW = $a.Width / $script:dpi; $scH = $a.Height / $script:dpi
    $cfg.OverlayX = [Math]::Max(0, [Math]::Min(1, ($w.Left - $L) / [Math]::Max(1, $scW - $w.ActualWidth)))
    $cfg.OverlayY = [Math]::Max(0, [Math]::Min(1, ($w.Top - $T) / [Math]::Max(1, $scH - $w.ActualHeight)))
    $cfg.OverlayPos = 5
    foreach ($o in $script:osds) { if ($o.Win -eq $w) { $o.Screen = $sc } }
    Save-Cfg
}
# free move ON = overlay can be grabbed with the mouse (dashed outline). OFF = locked + click-through.
function Apply-Free {
    foreach ($o in $script:osds) {
        [LhNative]::ClickThrough($o.H, -not $cfg.OverlayFree)
        $o.Win.IsHitTestVisible = [bool]$cfg.OverlayFree
        if ($cfg.OverlayFree) {
            $o.Bg.BorderBrush = $freeEdge; $o.Bg.BorderThickness = 1.6
            if ($cfg.Look -eq 'Outline') { $o.Bg.Background = $grabFill }   # something to grab
            $o.Win.Cursor = [Windows.Input.Cursors]::SizeAll
        } else {
            $o.Win.Cursor = $null
            Apply-OsdLook $o
            Place-Osd $o
        }
    }
}
function Set-AutoHide($on) { $cfg.OverlayAutoHide = [bool]$on; Save-Cfg; Apply-AutoHide; Sync-Settings; if ($mi) { Refresh-Menu } }
function Set-Free($on) {
    if ($on -and -not $cfg.Overlay) { $cfg.Overlay = $true; Build-Osds }
    $cfg.OverlayFree = [bool]$on
    Apply-Free
    Apply-AutoHide
    Save-Cfg
    Sync-Settings
    if ($mi) { Refresh-Menu }
}

# =====================================================================
#  AUTO-HIDE (iPhone-style): thin pill at the edge, hover to expand
#  The overlay stays click-through; we just poll the cursor (every 70 ms,
#  only while auto-hide is active) and compare it to the overlay's rectangle.
# =====================================================================
$script:inFullscreen = $false
function AutoHide-Active { $cfg.Overlay -and $cfg.OverlayAutoHide -and -not $cfg.OverlayFree -and [int]$cfg.OverlayPos -ne 5 -and -not ($cfg.GameMode -and $script:inFullscreen) }
# ---------- genie open / close (macOS-style): the bar pours out of the thin pill like a funnel ----------
# WPF can't mesh-warp, so: an animated trapezoid clip (edge near the pill stays narrow longer,
# far edge widens first) + ScaleY + fade. Driven by a 20 ms timer that only runs during a transition.
$openMs = 480; $closeMs = 380
$easeOut = New-Object Windows.Media.Animation.CubicEase; $easeOut.EasingMode = 'EaseOut'; $easeOut.Freeze()
function New-Anim($to, [int]$ms, $ease, $from = $null) {
    $a = New-Object Windows.Media.Animation.DoubleAnimation
    if ($null -ne $from) { $a.From = [double]$from }
    $a.To = [double]$to; $a.Duration = [TimeSpan]::FromMilliseconds($ms); $a.EasingFunction = $ease
    $a.Freeze(); $a
}
function Pos-Anchor { $p = [int]$cfg.OverlayPos; if (@(0, 3) -contains $p) { 0.0 } elseif (@(2, 4) -contains $p) { 1.0 } else { 0.5 } }
function Pos-Bottom { @(3, 4, 6) -contains [int]$cfg.OverlayPos }
function Set-Origin($o) { $o.Full.RenderTransformOrigin = New-Object Windows.Point((Pos-Anchor), $(if (Pos-Bottom) { 1 } else { 0 })) }
function Apply-Genie($o) {
    $W = $o.Full.ActualWidth; $H = $o.Full.ActualHeight
    if ($W -le 0 -or $H -le 0) { return }
    $q = [Math]::Max(0.0, [Math]::Min(1.0, $o.Q))
    $pf = [Math]::Min(1.0, 110.0 / $W)                                   # pill width as a fraction of the bar
    $near = $pf + (1 - $pf) * [Math]::Pow($q, 2.2)                      # edge touching the pill: opens late
    $far  = $pf + (1 - $pf) * [Math]::Pow($q, 0.55)                     # far edge: opens early
    $h = [Math]::Min(1.0, $q * 1.15) * $H
    $ax = Pos-Anchor
    $nL = $ax * ($W - $near * $W); $nR = $nL + $near * $W
    $fL = $ax * ($W - $far * $W);  $fR = $fL + $far * $W
    if (Pos-Bottom) { $yN = $H; $yF = $H - $h } else { $yN = 0; $yF = $h }
    $geo = New-Object Windows.Media.StreamGeometry
    $ctx = $geo.Open()
    $ctx.BeginFigure((New-Object Windows.Point($nL, $yN)), $true, $true)
    $ctx.PolyLineTo([Windows.Point[]]@((New-Object Windows.Point($nR, $yN)), (New-Object Windows.Point($fR, $yF)), (New-Object Windows.Point($fL, $yF))), $true, $false)
    $ctx.Close(); $geo.Freeze()
    $o.Full.Clip = $geo
    $o.Scale.ScaleX = 1
    $o.Scale.ScaleY = 0.4 + 0.6 * [Math]::Min(1.0, $q * 1.3)
    $o.Full.Opacity = [Math]::Min(1.0, $q * 3)
}
function Reset-Full($o) {
    $o.Full.Clip = $null
    $o.Scale.ScaleX = 1; $o.Scale.ScaleY = 1; $o.Full.Opacity = 1
}
$script:animSw = [Diagnostics.Stopwatch]::StartNew()
$animTimer = New-Object Windows.Threading.DispatcherTimer
$animTimer.Interval = [TimeSpan]::FromMilliseconds(20)
$animTimer.Add_Tick({
    try {
        $now = $script:animSw.Elapsed.TotalMilliseconds; $busy = $false
        foreach ($o in $script:osds) {
            if (-not $o.Dir) { continue }
            $dt = $now - $o.LastT; $o.LastT = $now
            $o.Q += $o.Dir * $dt / $(if ($o.Dir -gt 0) { $openMs } else { $closeMs })
            if ($o.Dir -gt 0 -and $o.Q -ge 1) { $o.Q = 1; $o.Dir = 0; Reset-Full $o; continue }
            if ($o.Dir -lt 0 -and $o.Q -le 0) { $o.Q = 0; $o.Dir = 0; Finish-Collapse $o; continue }
            Apply-Genie $o; $busy = $true
        }
        if (-not $busy) { $animTimer.Stop() }
    } catch {}
})
function Start-Genie($o, [int]$dir) {
    $o.Dir = $dir; $o.LastT = $script:animSw.Elapsed.TotalMilliseconds
    Set-Origin $o; Apply-Genie $o
    if (-not $animTimer.IsEnabled) { $animTimer.Start() }
}
function Finish-Collapse($o) {
    $o.Closing = $false; $o.Dir = 0; $o.Q = 0; $o.Collapsed = $true; $o.LeaveAt = $null
    Reset-Full $o
    $o.Full.Visibility = 'Collapsed'; $o.Handle.Visibility = 'Visible'
    if ($cfg.Animations) { $o.Handle.BeginAnimation([Windows.UIElement]::OpacityProperty, (New-Anim 1 160 $easeOut 0)) }
    Apply-OsdLook $o
    $o.Win.UpdateLayout(); Place-Osd $o
}
function Set-OsdCollapsed($o, [bool]$c, [bool]$instant = $false) {
    $anim = [bool]$cfg.Animations -and -not $instant
    if ($c) {
        if ($o.Collapsed) { return }
        if ($anim) {
            if ($o.Closing) { return }
            $o.Closing = $true
            if ($o.Dir -eq 0) { $o.Q = 1 }
            Start-Genie $o -1            # pour back into the pill; the anim timer swaps to the pill at the end
            return
        }
        Finish-Collapse $o
        return
    }
    if ($o.Closing) {
        # mouse came back mid-close: reverse from wherever it is
        $o.Closing = $false; $o.LeaveAt = $null
        if ($anim) { Start-Genie $o 1 } else { $o.Dir = 0; $o.Q = 1; Reset-Full $o }
        return
    }
    if (-not $o.Collapsed) { return }
    $o.Collapsed = $false; $o.LeaveAt = $null
    $o.Handle.BeginAnimation([Windows.UIElement]::OpacityProperty, $null)
    $o.Handle.Visibility = 'Collapsed'; $o.Full.Visibility = 'Visible'
    Apply-OsdLook $o
    $o.Win.UpdateLayout(); Place-Osd $o
    if ($anim) { $o.Q = 0; Start-Genie $o 1 } else { $o.Dir = 0; $o.Q = 1; Reset-Full $o }
}
function Apply-AutoHide {
    $on = AutoHide-Active
    foreach ($o in $script:osds) { Set-OsdCollapsed $o $on $true }
    if ($on) { $hoverTimer.Start() } else { $hoverTimer.Stop() }
}
$script:watchN = 0
$watchTimer = New-Object Windows.Threading.DispatcherTimer
$watchTimer.Interval = [TimeSpan]::FromSeconds(1)
$watchTimer.Add_Tick({
    try {
        if (-not $cfg.Overlay -or -not $script:osds.Count) { return }
        # 1) game mode: fullscreen app in front -> keep overlay open
        $fs = [bool]($cfg.GameMode -and [LhNative]::FullscreenForeground([uint32]$PID))
        if ($fs -ne $script:inFullscreen) { $script:inFullscreen = $fs; Apply-AutoHide }
        # 2) adaptive ink: sample an 8 px strip right next to the bar (never the bar itself)
        $script:watchN++
        if ($cfg.Look -eq 'Outline' -and $cfg.AdaptiveInk) {
            if ($script:watchN % 2) { return }   # brightness every 2 s is plenty
            foreach ($o in $script:osds) {
                $rc = [LhNative]::Rect($o.H); $wd = $rc[2] - $rc[0]; $gap = [int](3 * $script:dpi); $hgt = [int](8 * $script:dpi)
                $y = if (@(3, 4, 6) -contains [int]$cfg.OverlayPos) { $rc[1] - $gap - $hgt } else { $rc[3] + $gap }
                $lum = [LhNative]::Luma($rc[0], $y, $wd, $hgt)
                if ($lum -lt 0) { continue }
                $want = if ($o.Dark) { $lum -gt 0.45 } else { $lum -gt 0.62 }   # hysteresis: no flicker around the threshold
                if ($want -ne $o.Dark) { $o.Dark = $want; Apply-OsdLook $o; Apply-HandleInk $o }
            }
        } else {
            foreach ($o in $script:osds) { if ($o.Dark) { $o.Dark = $false; Apply-OsdLook $o; Apply-HandleInk $o } }
        }
    } catch {}
})
function Apply-HandleInk($o) {
    if ($o.Dark) { $o.Handle.Background = $pillDark; $o.Handle.BorderBrush = $haloLight } else { $o.Handle.Background = $pillLight; $o.Handle.BorderBrush = $haloDark }
}
$hoverTimer = New-Object Windows.Threading.DispatcherTimer
$hoverTimer.Interval = [TimeSpan]::FromMilliseconds(80)
$hoverTimer.Add_Tick({
    try {
        $p = [System.Windows.Forms.Cursor]::Position
        foreach ($o in $script:osds) {
            $rc = [LhNative]::Rect($o.H); $L = $rc[0]; $T = $rc[1]; $R = $rc[2]; $B = $rc[3]
            $sb = $o.Screen.Bounds
            # generous hot zone around the thin pill, a grace margin around the full bar
            if ($o.Collapsed) { $dx = 28 * $script:dpi; $dy = 14 * $script:dpi } else { $dx = 14 * $script:dpi; $dy = 14 * $script:dpi }
            $zT = $T - $dy; $zB = $B + $dy
            # the gap between the bar and the screen edge always counts as "inside" -> no blinking
            if (@(0, 1, 2) -contains [int]$cfg.OverlayPos) { $zT = $sb.Top - 2 }
            if (@(3, 4, 6) -contains [int]$cfg.OverlayPos) { $zB = $sb.Bottom + 2 }
            $inside = ($p.X -ge $L - $dx) -and ($p.X -le $R + $dx) -and ($p.Y -ge $zT) -and ($p.Y -le $zB)
            if ($inside) {
                $o.LeaveAt = $null
                if ($o.Collapsed -or $o.Closing) { Set-OsdCollapsed $o $false }
            } elseif (-not $o.Collapsed -and -not $o.Closing) {
                if (-not $o.LeaveAt) { $o.LeaveAt = [DateTime]::Now.AddMilliseconds(400) }
                elseif ([DateTime]::Now -ge $o.LeaveAt) { Set-OsdCollapsed $o $true }
            }
        }
    } catch {}
})

# =====================================================================
#  LOOK (Outline / Solid) + METRICS
# =====================================================================
# Look: Outline = text + frame only (see straight through to what's behind)
#       Solid   = text + fully coloured background + frame
# ---------- adaptive ink: remember every colour in the overlay, swap white<->black ----------
function Collect-Ink($root) {
    $list = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack; $stack.Push($root)
    while ($stack.Count) {
        $e = $stack.Pop()
        if ($e -is [Windows.Controls.TextBlock] -and $e.Foreground -is [Windows.Media.SolidColorBrush]) { [void]$list.Add(@($e, 'Foreground', $e.Foreground.Color)) }
        elseif ($e -is [Windows.Shapes.Shape] -and $e.Stroke -is [Windows.Media.SolidColorBrush]) { [void]$list.Add(@($e, 'Stroke', $e.Stroke.Color)) }
        elseif ($e -is [Windows.Controls.Border] -and $e.Name -notin @('oBg', 'oHalo', 'oPad', 'oHandle') -and $e.Background -is [Windows.Media.SolidColorBrush]) { [void]$list.Add(@($e, 'Background', $e.Background.Color)) }
        foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($e)) { if ($c -is [Windows.DependencyObject]) { $stack.Push($c) } }
    }
    ,$list
}
$inkMap = @{ 'FF9FE1CB' = 'FF0F6E56'; 'FF85B7EB' = 'FF185FA5'; 'FFAFA9EC' = 'FF534AB7'; 'FFF09595' = 'FFA32D2D'
            'FF5DCAA5' = 'FF0F6E56'; 'FFF0997B' = 'FF993C1D'; 'FFFAC775' = 'FF854F0B'; 'FF97C459' = 'FF3B6D11' }
function Ink-Color($c, [bool]$dark) {
    if (-not $dark) { return $c }
    $k = '{0:X2}{1:X2}{2:X2}{3:X2}' -f 255, $c.R, $c.G, $c.B
    if ($inkMap.ContainsKey($k)) { $n = [Windows.Media.ColorConverter]::ConvertFromString('#' + $inkMap[$k]); return [Windows.Media.Color]::FromArgb($c.A, $n.R, $n.G, $n.B) }
    if ($c.R -gt 180 -and $c.G -gt 180 -and $c.B -gt 180) { return [Windows.Media.Color]::FromArgb($c.A, 0x12, 0x14, 0x1A) }
    $c
}
function Apply-OsdInk($o) {
    $dark = [bool]($o.Dark -and $cfg.Look -ne 'Solid')
    foreach ($it in $o.Ink) {
        $b = New-Object Windows.Media.SolidColorBrush (Ink-Color $it[2] $dark); $b.Freeze()
        $it[0].($it[1]) = $b
    }
    $o.Main = if ($dark) { $inkDark } else { $white }
    $o.Hot = if ($dark) { $hotDark } else { $hot }
}
function Apply-OsdLook($o) {
    $o.Win.Opacity = 1; $o.Bg.Opacity = 1
    if ($cfg.Look -eq 'Solid') {
        $o.Bg.Background = $solidFill; $o.Bg.BorderBrush = $osdEdge; $o.Bg.BorderThickness = 1
        $o.Halo.Visibility = 'Collapsed'
        $o.Body.Effect = $null; $o.Pad.Effect = $null
    } else {
        $o.Halo.Visibility = if ($o.Collapsed) { 'Collapsed' } else { 'Visible' }   # contrasting ring outside the frame
        if ($o.Dark) {
            # bright background behind the overlay -> black text, dark frame, white glow
            $o.Bg.Background = $clearFill; $o.Bg.BorderBrush = $outlineEdgeDark; $o.Bg.BorderThickness = 1
            $o.Halo.BorderBrush = $haloLight
            $o.Body.Effect = $textShadowW; $o.Pad.Effect = $null
        } else {
            $o.Bg.Background = $clearFill; $o.Bg.BorderBrush = $outlineEdge; $o.Bg.BorderThickness = 1
            $o.Halo.BorderBrush = $haloDark
            $o.Body.Effect = $textShadow; $o.Pad.Effect = $null
        }
    }
    Apply-OsdInk $o
}
function Apply-Look {
    foreach ($o in $script:osds) { Apply-OsdLook $o }
    if ($cfg.OverlayFree) { Apply-Free }
}
function Apply-Metrics {
    foreach ($o in $script:osds) { Apply-OsdMetrics $o; $o.Win.UpdateLayout(); Place-Osd $o }
    $sync.Want = Want-Table
}

# =====================================================================
#  SETTINGS WINDOW
# =====================================================================
$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LiquidHUD Settings" Width="680" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" Background="Transparent"
        Topmost="True" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Display, Segoe UI">
  <Window.Resources>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="12.5"/>
      <Setter Property="Width" Value="150"/><Setter Property="Margin" Value="0,0,0,8"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <StackPanel Orientation="Horizontal" Background="Transparent">
              <Border x:Name="Box" Width="18" Height="18" CornerRadius="5" BorderThickness="1.2" BorderBrush="#66FFFFFF" Background="#14FFFFFF">
                <TextBlock x:Name="Tick" Text="&#x2713;" Foreground="#0C0E16" FontWeight="Bold" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center" Visibility="Hidden"/>
              </Border>
              <ContentPresenter Margin="9,0,0,0" VerticalAlignment="Center"/>
            </StackPanel>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Box" Property="Background" Value="#9FE1CB"/>
                <Setter TargetName="Box" Property="BorderBrush" Value="#9FE1CB"/>
                <Setter TargetName="Tick" Property="Visibility" Value="Visible"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="White"/><Setter Property="FontSize" Value="12.5"/><Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="Bd" CornerRadius="8" Padding="12,5" Margin="0,0,6,6" Background="#14FFFFFF" BorderBrush="#33FFFFFF" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#339FE1CB"/>
                <Setter TargetName="Bd" Property="BorderBrush" Value="#9FE1CB"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Head" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#B3FFFFFF"/><Setter Property="FontSize" Value="11.5"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Margin" Value="0,16,0,8"/>
    </Style>
  </Window.Resources>
  <Border x:Name="sRoot" Background="#F50C0E16" CornerRadius="16" BorderBrush="#40FFFFFF" BorderThickness="1" Padding="22,16,22,20">
    <StackPanel>
      <Grid>
        <TextBlock Text="Settings" Foreground="White" FontSize="18" FontWeight="Bold"/>
        <Border x:Name="sClose" HorizontalAlignment="Right" Width="28" Height="28" CornerRadius="14" Background="#1FFFFFFF" Cursor="Hand">
          <TextBlock Text="&#x2715;" Foreground="White" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="28"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
      <TextBlock Style="{StaticResource Head}" Text="Overlay"/>
      <CheckBox x:Name="sShowO" Width="300" Content="Show the overlay  (Ctrl+Alt+O)"/>
      <CheckBox x:Name="sStart" Width="300" Content="Start with Windows"/>
      <CheckBox x:Name="sIcons" Width="300" Content="Coloured icons  (off = text labels)"/>

      <TextBlock Style="{StaticResource Head}" Text="Look"/>
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="sLO" GroupName="look" Content="Outline  (text + frame)"/>
        <RadioButton x:Name="sLS" GroupName="look" Content="Solid  (filled)"/>
      </StackPanel>

      <TextBlock Style="{StaticResource Head}" Text="Overlay position"/>
      <WrapPanel x:Name="sPos"/>
      <CheckBox x:Name="sFree" Width="300" Margin="0,6,0,0" Content="Free move  (drag the overlay, untick to lock it)"/>
      <CheckBox x:Name="sAuto" Width="300" Margin="0,0,0,0" Content="Auto-hide  (thin bar, hover to show)"/>
      <CheckBox x:Name="sAnim" Width="300" Margin="0,8,0,0" Content="Genie open / close animation  (macOS style)"/>
      <CheckBox x:Name="sGame" Width="300" Margin="0,8,0,0" Content="Game mode  (stay open over fullscreen apps)"/>
      <CheckBox x:Name="sInk" Width="300" Margin="0,8,0,0" Content="Adaptive text  (black on bright, white on dark)"/>

      <TextBlock Style="{StaticResource Head}" Text="Clock"/>
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="sC24" GroupName="clk" Content="24h  (18:46)"/>
        <RadioButton x:Name="sC12" GroupName="clk" Content="12h  (6:46 PM)"/>
      </StackPanel>


        </StackPanel>
        <StackPanel Grid.Column="2">
      <TextBlock Style="{StaticResource Head}" Text="Overlay shows"/>
      <WrapPanel x:Name="sOsdChecks"/>

      <TextBlock Style="{StaticResource Head}" Text="Refresh rate (slower = lighter)"/>
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="sR1" GroupName="rr" Content="1s"/>
        <RadioButton x:Name="sR2" GroupName="rr" Content="2s"/>
        <RadioButton x:Name="sR5" GroupName="rr" Content="5s"/>
      </StackPanel>

      <Border Background="#14FFFFFF" CornerRadius="10" Padding="12,9" Margin="0,18,0,0">
        <StackPanel>
          <TextBlock Text="LiquidHUD itself is using" Foreground="#8CFFFFFF" FontSize="10.5"/>
          <TextBlock x:Name="sSelf" Text="--" Foreground="White" FontSize="13" FontWeight="SemiBold" Margin="0,2,0,0"/>
        </StackPanel>
      </Border>
      <TextBlock Text="Tip: LiquidHUD lives in the system tray (Show hidden icons). Click its icon for Settings, right-click for the menu." Foreground="#8CFFFFFF" FontSize="10.5" TextWrapping="Wrap" Margin="0,10,0,0"/>
        </StackPanel>
      </Grid>
    </StackPanel>
  </Border>
</Window>
"@
$script:sWin = $null
function Sync-Settings {
    if (-not $script:sUi) { return }
    $s = $script:sUi
    $s.sShowO.IsChecked = [bool]$cfg.Overlay
    $s.sStart.IsChecked = Test-Path $startupLnk
    $s.sIcons.IsChecked = [bool]$cfg.Icons
    $s.sLO.IsChecked = ($cfg.Look -ne 'Solid'); $s.sLS.IsChecked = ($cfg.Look -eq 'Solid')
    $s.sFree.IsChecked = [bool]$cfg.OverlayFree
    $s.sAuto.IsChecked = [bool]$cfg.OverlayAutoHide
    $s.sAnim.IsChecked = [bool]$cfg.Animations
    $s.sGame.IsChecked = [bool]$cfg.GameMode
    $s.sInk.IsChecked = [bool]$cfg.AdaptiveInk
    $s.sC24.IsChecked = [bool]$cfg.Clock24; $s.sC12.IsChecked = -not [bool]$cfg.Clock24
    Sync-PosRadios
}
function Set-Clock($is24) {
    $cfg.Clock24 = [bool]$is24; Save-Cfg
    foreach ($o in $script:osds) { Apply-OsdMetrics $o }
    Sync-Settings
}
function Set-Look($lk) { $cfg.Look = $lk; Save-Cfg; Apply-Look; Sync-Settings; Refresh-Menu }
function Sync-PosRadios { if ($script:posRadios) { foreach ($rb in $script:posRadios) { $rb.IsChecked = ([int]$cfg.OverlayPos -eq [int]$rb.Tag) } } }
function Set-Pos($i) {
    if ($cfg.OverlayFree) { $cfg.OverlayFree = $false; Apply-Free; if ($script:sUi) { $script:sUi.sFree.IsChecked = $false } }
    $cfg.OverlayPos = $i; Save-Cfg
    Apply-AutoHide
    foreach ($o in $script:osds) { Place-Osd $o }
    Sync-PosRadios; Refresh-Menu
}
function Open-Settings {
    if ($script:sWin) { Sync-Settings; $script:sWin.Show(); $script:sWin.Activate() | Out-Null; return }
    $sw = [Windows.Markup.XamlReader]::Parse($settingsXaml)
    $script:sWin = $sw
    $script:sUi = @{}
    foreach ($n in 'sRoot','sClose','sR1','sR2','sR5','sSelf','sPos','sFree','sAuto','sAnim','sGame','sInk','sShowO','sStart','sIcons','sLO','sLS','sC24','sC12','sOsdChecks') { $script:sUi[$n] = $sw.FindName($n) }
    $s = $script:sUi

    $s.sStart.Add_Click({ Set-Startup ([bool]$this.IsChecked) })
    $s.sIcons.Add_Click({ $cfg.Icons = [bool]$this.IsChecked; Save-Cfg; Apply-Metrics })
    $s.sShowO.Add_Click({ if ([bool]$this.IsChecked -ne [bool]$cfg.Overlay) { Toggle-Overlay } })
    $s.sLO.Tag = 'Outline'; $s.sLS.Tag = 'Solid'
    $s.sLO.Add_Click({ Set-Look 'Outline' }); $s.sLS.Add_Click({ Set-Look 'Solid' })

    # overlay position buttons + behaviour toggles (restored: lost in v13)
    $script:posRadios = @()
    foreach ($i in $posOrder) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.GroupName = 'pos'; $rb.Content = $posNames[$i]; $rb.Tag = $i
        $rb.IsChecked = ([int]$cfg.OverlayPos -eq $i)
        if ($i -eq 5) { $rb.ToolTip = 'Where you last dropped it with Free move' }
        $rb.Add_Click({ Set-Pos ([int]$this.Tag) })
        [void]$s.sPos.Children.Add($rb); $script:posRadios += $rb
    }
    $s.sFree.Add_Click({ Set-Free ([bool]$this.IsChecked) })
    $s.sAuto.Add_Click({ Set-AutoHide ([bool]$this.IsChecked) })
    $s.sAnim.Add_Click({ $cfg.Animations = [bool]$this.IsChecked; Save-Cfg })
    $s.sGame.Add_Click({ $cfg.GameMode = [bool]$this.IsChecked; Save-Cfg; $script:inFullscreen = $false; Apply-AutoHide })
    $s.sInk.Add_Click({ $cfg.AdaptiveInk = [bool]$this.IsChecked; Save-Cfg })

    foreach ($k in $osdLabels.Keys) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $osdLabels[$k]; $cb.Tag = $k; $cb.IsChecked = [bool]$cfg.OsdShow.$k
        $cb.Add_Click({ $cfg.OsdShow.($this.Tag) = [bool]$this.IsChecked; Apply-Metrics; Save-Cfg })
        [void]$s.sOsdChecks.Children.Add($cb)
    }
    $s.sC24.Add_Click({ Set-Clock $true }); $s.sC12.Add_Click({ Set-Clock $false })


    switch ([int]$cfg.Interval) { 1 { $s.sR1.IsChecked = $true } 5 { $s.sR5.IsChecked = $true } default { $s.sR2.IsChecked = $true } }
    foreach ($p in @(@($s.sR1, 1), @($s.sR2, 2), @($s.sR5, 5))) {
        $p[0].Tag = $p[1]
        $p[0].Add_Checked({ $cfg.Interval = [int]$this.Tag; $sync.Interval = $cfg.Interval; $timer.Interval = [TimeSpan]::FromSeconds($cfg.Interval); Save-Cfg })
    }

    Sync-Settings

    $s.sClose.Add_MouseLeftButtonUp({ $script:sWin.Hide(); Save-Cfg })
    $s.sRoot.Add_MouseLeftButtonDown({ param($a, $e); if ($e.OriginalSource -eq $script:sUi.sRoot) { try { $script:sWin.DragMove() } catch {} } })
    $sw.Add_Closing({ param($a, $e); $e.Cancel = $true; $script:sWin.Hide(); Save-Cfg })
    $sw.Show(); $sw.Activate() | Out-Null
}

# =====================================================================
#  MENU
# =====================================================================
$menuXaml = @"
<ContextMenu xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" HasDropShadow="False">
  <ContextMenu.Template>
    <ControlTemplate TargetType="ContextMenu">
      <Border Background="#F2181B26" BorderBrush="#40FFFFFF" BorderThickness="1" CornerRadius="10" Padding="4" MinWidth="240">
        <StackPanel IsItemsHost="True"/>
      </Border>
    </ControlTemplate>
  </ContextMenu.Template>
  <ContextMenu.Resources>
    <Style TargetType="MenuItem">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="MenuItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="6" Padding="8,6,12,6">
              <Grid>
                <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel Orientation="Horizontal">
                  <TextBlock x:Name="Chk" Text="&#x2713;" Width="18" Foreground="#9FE1CB" FontSize="12.5" Visibility="Hidden"/>
                  <ContentPresenter ContentSource="Header" TextBlock.Foreground="White" TextBlock.FontSize="12.5" TextBlock.FontFamily="Segoe UI"/>
                </StackPanel>
                <TextBlock Grid.Column="1" Text="{TemplateBinding InputGestureText}" Foreground="#80FFFFFF" FontSize="11" Margin="24,1,0,0" FontFamily="Segoe UI"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="#26FFFFFF"/></Trigger>
              <Trigger Property="IsChecked" Value="True"><Setter TargetName="Chk" Property="Visibility" Value="Visible"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </ContextMenu.Resources>
  <MenuItem x:Name="mSettings" Header="Settings" InputGestureText="Ctrl+Alt+S"/>
  <MenuItem x:Name="mOverlay"  Header="Game overlay" InputGestureText="Ctrl+Alt+O"/>
  <MenuItem x:Name="mPos"      Header="Overlay position" InputGestureText="Ctrl+Alt+P"/>
  <MenuItem x:Name="mFree"     Header="Free move overlay" InputGestureText="Ctrl+Alt+M"/>
  <MenuItem x:Name="mAuto"     Header="Auto-hide overlay"/>
  <MenuItem x:Name="mAll"      Header="Overlay on all monitors"/>
  <MenuItem x:Name="mLook"     Header="Look: Outline"/>
  <MenuItem x:Name="mStartup"  Header="Start with Windows"/>
  <MenuItem x:Name="mTask"     Header="Task Manager"/>
  <MenuItem x:Name="mExit"     Header="Exit"/>
</ContextMenu>
"@
$script:menu = [Windows.Markup.XamlReader]::Parse($menuXaml)
$menu = $script:menu
$mi = @{}
foreach ($n in 'mSettings','mOverlay','mPos','mFree','mAuto','mAll','mLook','mStartup','mTask','mExit') { $mi[$n] = $menu.FindName($n) }
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LiquidHUD.lnk'

function Refresh-Menu {
    $mi.mOverlay.IsChecked = [bool]$cfg.Overlay
    $mi.mAll.IsChecked = [bool]$cfg.OverlayAll
    $mi.mFree.IsChecked = [bool]$cfg.OverlayFree
    $mi.mAuto.IsChecked = [bool]$cfg.OverlayAutoHide
    $mi.mPos.Header = 'Overlay position: ' + $posNames[[int]$cfg.OverlayPos]
    $mi.mStartup.IsChecked = Test-Path $startupLnk
    $mi.mLook.Header = 'Look: ' + $cfg.Look + '  (click to switch)'
}
function Toggle-Overlay { $cfg.Overlay = -not $cfg.Overlay; if (-not $cfg.Overlay) { $cfg.OverlayFree = $false }; Save-Cfg; Build-Osds; $sync.Want = Want-Table; Sync-Settings; Refresh-Menu }
function Cycle-Pos { $k = [array]::IndexOf($posOrder, [int]$cfg.OverlayPos); Set-Pos $posOrder[($k + 1) % $posOrder.Count] }
function Quit-All {
    $timer.Stop(); $hoverTimer.Stop(); $watchTimer.Stop(); $animTimer.Stop(); $sync.Stop = $true
    $cfg.OverlayFree = $false
    Save-Cfg
    try { $tray.Visible = $false; $tray.Dispose() } catch {}
    foreach ($o in $script:osds) { try { $o.Win.Close() } catch {} }
    try { $hk.Dispose() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

$mi.mSettings.Add_Click({ Open-Settings })
$mi.mOverlay.Add_Click({ Toggle-Overlay })
$mi.mPos.Add_Click({ Cycle-Pos })
$mi.mFree.Add_Click({ Set-Free (-not $cfg.OverlayFree) })
$mi.mAuto.Add_Click({ Set-AutoHide (-not $cfg.OverlayAutoHide) })
$mi.mAll.Add_Click({ $cfg.OverlayAll = -not $cfg.OverlayAll; Save-Cfg; Build-Osds; Refresh-Menu })
$mi.mLook.Add_Click({ Set-Look $(if ($cfg.Look -eq 'Solid') { 'Outline' } else { 'Solid' }) })
function Set-Startup($on) {
    if ($on -and -not (Test-Path $startupLnk)) {
        $ws = New-Object -ComObject WScript.Shell
        $l = $ws.CreateShortcut($startupLnk)
        $l.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $l.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        $l.WindowStyle = 7
        $l.Save()
    } elseif (-not $on) { Remove-Item $startupLnk -ErrorAction SilentlyContinue }
    Sync-Settings; Refresh-Menu
}
$mi.mStartup.Add_Click({ Set-Startup (-not (Test-Path $startupLnk)) })
$mi.mTask.Add_Click({ Start-Process taskmgr.exe })
$mi.mExit.Add_Click({ Quit-All })
$menu.Add_Opened({ Refresh-Menu })

# ---------- global hotkeys ----------
$hk = New-Object LhHotkeys
$MOD = 0x0002 -bor 0x0001 -bor 0x4000    # Ctrl + Alt + NoRepeat
[void]$hk.Register(1, $MOD, 0x4F)   # O
[void]$hk.Register(2, $MOD, 0x50)   # P
[void]$hk.Register(4, $MOD, 0x53)   # S
[void]$hk.Register(5, $MOD, 0x4D)   # M
$hk.Add_Pressed({
    param($id)
    switch ($id) { 1 { Toggle-Overlay } 2 { Cycle-Pos } 4 { Open-Settings } 5 { Set-Free (-not $cfg.OverlayFree) } }
})

# =====================================================================
#  UPDATE LOOP (UI thread - lightweight)
# =====================================================================
function Fmt-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { '{0:N0} B' -f $b }
}
function Draw-Line($line, $hist, [double]$wd, [double]$ht, [int]$max) {
    $pc = New-Object Windows.Media.PointCollection($hist.Count)
    $n = $hist.Count; $step = $wd / ($max - 1); $pad = 2; $scale = ($ht - 2 * $pad) / 100
    for ($i = 0; $i -lt $n; $i++) {
        $pc.Add((New-Object Windows.Point((($max - $n + $i) * $step), ($ht - $pad - ([Math]::Min(100, $hist[$i]) * $scale)))))
    }
    $pc.Freeze(); $line.Points = $pc
}
$histOC = New-Object System.Collections.Generic.List[double]
$histOR = New-Object System.Collections.Generic.List[double]
function Set-Text($tb, $txt) { if ($tb.Text -ne $txt) { $tb.Text = $txt; $script:chg = $true } }
$white = Brush '#FFFFFF'; $hot = Brush '#F09595'
$arrowDown = [string][char]0x2193; $arrowUp = [string][char]0x2191

$timer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
$timer.Interval = [TimeSpan]::FromSeconds([int]$cfg.Interval)
$timer.Add_Tick({
  try {
    $d = $sync.Data
    if (-not $d) { return }
    $clock = if ($cfg.Clock24) { [DateTime]::Now.ToString('HH:mm') } else { [DateTime]::Now.ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture) }
    $gpu = [Math]::Max(0, $d.Gpu)
    $gpuTxt = if ($d.Gpu -ge 0) { '{0:N0}%' -f $gpu } else { 'n/a' }
    $ramPct = if ($d.RamTot) { $d.RamUsed / $d.RamTot * 100 } else { 0 }
    $cpuTxt = '{0:N0}%' -f $d.Cpu
    $ramTxt = '{0:N0}%' -f $ramPct

    $osdGraph = $cfg.Overlay -and $cfg.OsdShow.Graph
    if ($osdGraph) {
        $histOC.Add($d.Cpu); $histOR.Add($ramPct)
        while ($histOC.Count -gt 30) { $histOC.RemoveAt(0); $histOR.RemoveAt(0) }
    }
    $downTxt = if ($null -ne $d.Down) { (Fmt-Bytes $d.Down) + '/s' } else { '' }
    $upTxt = if ($null -ne $d.Up) { (Fmt-Bytes $d.Up) + '/s' } else { '' }
    foreach ($o in $script:osds) {
        $script:chg = $false
        Set-Text $o.Cpu $cpuTxt; $o.Cpu.Foreground = if ($d.Cpu -gt 85) { $o.Hot } else { $o.Main }
        Set-Text $o.Gpu $gpuTxt
        Set-Text $o.Ram $ramTxt; $o.Ram.Foreground = if ($ramPct -gt 85) { $o.Hot } else { $o.Main }
        Set-Text $o.Down $downTxt; Set-Text $o.Up $upTxt
        if ($d.TopCName) { Set-Text $o.TopCName $d.TopCName; Set-Text $o.TopCVal ('{0:N0}%' -f $d.TopCPct) }
        if ($d.TopR) { Set-Text $o.TopRName $d.TopR; Set-Text $o.TopRVal (Fmt-Bytes $d.TopRBytes) }
        Set-Text $o.Batt $(if ($null -eq $d.NoBatt -or $d.NoBatt) { '' } else { ('{0:N0}%' -f $d.Batt) + $(if ($d.Charging) { ' ' + [char]0x26A1 } else { '' }) })
        Set-Text $o.Clock $clock
        if ($osdGraph) { Draw-Line $o.LineCpu $histOC 56 18 30; Draw-Line $o.LineRam $histOR 56 18 30 }
        # widths: grow at once, shrink only after a value has been shorter for 6 updates in a row.
        # Tight bar, and a centered bar never jitters.
        if ($script:chg -and -not $o.Collapsed -and -not $o.Dir) {
            $inf = New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)
            foreach ($k in $osdKeys) {
                $sg = $o.Seg[$k]; if ($sg.Visibility -ne 'Visible') { continue }
                $old = $sg.MinWidth; $sg.MinWidth = 0; $sg.Measure($inf); $nat = [Math]::Ceiling($sg.DesiredSize.Width)
                if ($nat -ge $old) { $sg.MinWidth = $nat; $o.Shrink[$k] = 0 }
                elseif ($old - $nat -le 2) { $sg.MinWidth = $old }
                else {
                    $o.Shrink[$k] = [int]$o.Shrink[$k] + 1
                    $sg.MinWidth = if ($o.Shrink[$k] -ge 6) { $o.Shrink[$k] = 0; $nat } else { $old }
                }
            }
            $o.Win.UpdateLayout()
        }
        Place-Osd $o
        [LhNative]::Top($o.H)
    }

    $tt = 'LiquidHUD  |  CPU ' + $cpuTxt + '  RAM ' + $ramTxt
    if ($tray.Text -ne $tt) { $tray.Text = $tt }

    if ($script:sWin -and $script:sWin.IsVisible) {
        Set-Text $script:sUi.sSelf ('{0:N0} MB RAM in use  ({1:N0} MB reserved)   |   {2:N1}% CPU' -f ($d.SelfWs / 1MB), ($d.SelfPriv / 1MB), [Math]::Max(0, $d.SelfCpu))
    }
  } catch {}
})

# =====================================================================
#  SYSTEM TRAY ICON  (taskbar > "Show hidden icons")
#  click = Settings | right-click = menu
# =====================================================================
function New-TrayIcon {
    $bmp = New-Object System.Drawing.Bitmap 32, 32
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([System.Drawing.Color]::Transparent)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $r = 9; $path.AddArc(1, 1, $r, $r, 180, 90); $path.AddArc(30 - $r, 1, $r, $r, 270, 90); $path.AddArc(30 - $r, 30 - $r, $r, $r, 0, 90); $path.AddArc(1, 30 - $r, $r, $r, 90, 90); $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 18, 20, 28))), $path)
    $g.DrawPath((New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(140, 255, 255, 255)), 1.2), $path)
    $cols = @([System.Drawing.Color]::FromArgb(255, 133, 183, 235), [System.Drawing.Color]::FromArgb(255, 159, 225, 203), [System.Drawing.Color]::FromArgb(255, 175, 169, 236))
    $hs = @(10, 18, 13)
    for ($i = 0; $i -lt 3; $i++) { $g.FillRectangle((New-Object System.Drawing.SolidBrush $cols[$i]), 7 + $i * 7, 25 - $hs[$i], 4, $hs[$i]) }
    $g.Dispose()
    [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
# invisible host window: lets the dark WPF menu open at the cursor and close when you click elsewhere
$trayHost = New-Object Windows.Window
$trayHost.WindowStyle = 'None'; $trayHost.AllowsTransparency = $true; $trayHost.Background = [Windows.Media.Brushes]::Transparent
$trayHost.ShowInTaskbar = $false; $trayHost.Width = 1; $trayHost.Height = 1; $trayHost.Left = -32000; $trayHost.Top = -32000
$trayHost.Show(); [LhNative]::ToolWindow((Win-Handle $trayHost))
$menu.PlacementTarget = $trayHost
$menu.Placement = 'MousePoint'

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-TrayIcon
$tray.Text = 'LiquidHUD'
$tray.Add_MouseUp({
    param($sn, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $trayHost.Activate() | Out-Null; $menu.IsOpen = $true }
    elseif ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-Settings }
})
$tray.Visible = $true
if (-not $cfg.TrayTipShown) {
    $tray.ShowBalloonTip(4000, 'LiquidHUD is running', 'Find it under "Show hidden icons" in the taskbar. Click for Settings, right-click for the menu.', 'Info')
    $cfg.TrayTipShown = $true; Save-Cfg
}

# ---------- start ----------
Build-Osds
Apply-Metrics
Apply-Look
$timer.Start()
[Windows.Threading.Dispatcher]::Run()
try { [void]$bg.EndInvoke($bgHandle) } catch {}
$bg.Dispose(); $rs.Close()
