# =====================================================================
#  LiquidHUD v12 -  glass system monitor widget + game overlay for Windows
#  Pure PowerShell + WPF (built into Windows). Nothing to install.
#  https://github.com/NikoAgera/LiquidHUD
#
#  HOTKEYS (work even inside games):
#    Ctrl+Alt+S  = open Settings (show widget/overlay, look, metrics, disks, refresh rate)
#    Ctrl+Alt+O  = toggle game overlay (small click-through bar on top of everything)
#    Ctrl+Alt+P  = cycle overlay position
#    Ctrl+Alt+M  = free move overlay (drag it anywhere, press again to lock)
#    Ctrl+Alt+H  = big widget on/off
#  Widget: drag = move | double-click = Task Manager | right-click = menu
#
#  Lightweight by design:
#    - runs at BelowNormal priority (your game always wins)
#    - unticked metrics are not collected at all (GPU / top apps are the heaviest)
#    - default refresh 2s (1s / 2s / 5s)
#    - working set trimmed every 60s
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


# ---------- metric list ----------
$metrics = [ordered]@{
    Cpu = 'CPU'; Gpu = 'GPU'; Ram = 'RAM'; Graph = 'Graph (60s)'
    Net = 'Network'; Batt = 'Battery'; Up = 'Uptime'; TopC = 'Top CPU app'; TopR = 'Top RAM app'; Clock = 'Clock'
}

# ---------- drives (every ready fixed / removable disk) ----------
function Get-Drives {
    $list = @()
    foreach ($dv in [IO.DriveInfo]::GetDrives()) {
        try {
            if (-not $dv.IsReady) { continue }
            if ($dv.DriveType -ne 'Fixed' -and $dv.DriveType -ne 'Removable') { continue }
            $lbl = $dv.VolumeLabel
            $list += [pscustomobject]@{ Letter = $dv.Name.Substring(0, 1).ToUpper(); Label = $lbl; Total = [double]$dv.TotalSize }
        } catch {}
    }
    ,$list
}
$script:drives = Get-Drives

# ---------- settings ----------
$cfgDir  = Join-Path $env:APPDATA 'LiquidHUD'
$cfgFile = Join-Path $cfgDir 'settings.json'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
$showDefault = [ordered]@{}; foreach ($k in $metrics.Keys) { $showDefault[$k] = $true }
$cfg = [pscustomobject]@{
    Left = -1; Top = 40; Topmost = $false; Look = 'Outline'; Overlay = $false; OverlayAll = $true; OverlayPos = 2; OverlayFree = $false; OverlayAutoHide = $true; GameMode = $true; AdaptiveInk = $true; OverlayX = 0.98; OverlayY = 0.01
    WidgetHidden = $false; Interval = 2; Clock24 = $true
    Show = [pscustomobject]$showDefault
    OsdShow = [pscustomobject][ordered]@{ Cpu = $true; Gpu = $true; Ram = $true; Net = $true; TopC = $true; TopR = $false; Batt = $false; Graph = $true; Clock = $true }
    Disks = @{}
}
if (Test-Path $cfgFile) {
    try {
        $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties.Name) { if ($p -ne 'Show' -and $p -ne 'OsdShow' -and $p -ne 'Disks' -and $null -ne $j.$p) { $cfg.$p = $j.$p } }
        if ($j.OsdShow) { foreach ($pp in $cfg.OsdShow.PSObject.Properties.Name) { if ($null -ne $j.OsdShow.$pp) { $cfg.OsdShow.$pp = [bool]$j.OsdShow.$pp } } }
        if ($j.Disks) { foreach ($pp in $j.Disks.PSObject.Properties) { $cfg.Disks[$pp.Name] = [bool]$pp.Value } }
        if ($j.Show) { foreach ($k in $metrics.Keys) { if ($null -ne $j.Show.$k) { $cfg.Show.$k = [bool]$j.Show.$k } } }
    } catch {}
}
if (@(1, 2, 5) -notcontains [int]$cfg.Interval) { $cfg.Interval = 2 }
if ([int]$cfg.OverlayPos -lt 0 -or [int]$cfg.OverlayPos -gt 6) { $cfg.OverlayPos = 2 }
$cfg.OverlayFree = $false
foreach ($dv in $script:drives) { if (-not $cfg.Disks.ContainsKey($dv.Letter)) { $cfg.Disks[$dv.Letter] = $true } }
if (@('Outline', 'Solid') -notcontains $cfg.Look) { $cfg.Look = 'Outline' }
function Save-Cfg { try { $cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $cfgFile -Encoding UTF8 } catch {} }
function Want-Table {
    $w = @{}
    foreach ($k in $metrics.Keys) {
        $w[$k] = ([bool]$cfg.Show.$k -and -not $cfg.WidgetHidden) -or ($cfg.Overlay -and [bool]$cfg.OsdShow.$k)
    }
    $w.Graph = $w.Graph -and -not $cfg.WidgetHidden
    if ($cfg.Overlay -and $cfg.OsdShow.Graph) { $w.Cpu = $true; $w.Ram = $true }
    $w.Disks = @(foreach ($dv in $script:drives) { if ($cfg.Disks[$dv.Letter] -and -not $cfg.WidgetHidden) { $dv.Letter } })
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

    $script:gpuC = @()
    function Clear-Gpu { foreach ($c in $script:gpuC) { try { $c.Dispose() } catch {} }; $script:gpuC = @() }
    function Refresh-Gpu {
        Clear-Gpu
        try {
            $cat = New-Object Diagnostics.PerformanceCounterCategory('GPU Engine')
            $script:gpuC = @(foreach ($n in $cat.GetInstanceNames()) {
                if ($n -notlike '*engtype_3D*') { continue }
                try { $c = New-Object Diagnostics.PerformanceCounter('GPU Engine', 'Utilization Percentage', $n); [void]$c.NextValue(); $c } catch {}
            })
        } catch {}
    }

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
    $gpuSw = [Diagnostics.Stopwatch]::StartNew(); $gpuFresh = $false
    $diskSw = $null
    $trimSw = [Diagnostics.Stopwatch]::StartNew()
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $selfPrev = $self.TotalProcessorTime.TotalSeconds
    $selfSw = [Diagnostics.Stopwatch]::StartNew()
    $d = @{ TopC = ''; TopR = ''; TopRBytes = 0; Disks = @{}; DiskKey = '' }

    while (-not $sync.Stop) {
        $loop = [Diagnostics.Stopwatch]::StartNew()
        $w = $sync.Want
        try {
            $n = @{ Cores = $cores }
            $n.Cpu = if ($cpuC) { [Math]::Min(100, $cpuC.NextValue()) } else { 0 }

            # GPU counters are the most expensive -> only when enabled
            if ($w.Gpu) {
                if (-not $gpuFresh -or $gpuSw.Elapsed.TotalSeconds -ge 60) { Refresh-Gpu; $gpuSw.Restart(); $gpuFresh = $true }
                $g = 0.0
                foreach ($c in $script:gpuC) { try { $g += $c.NextValue() } catch {} }
                $n.Gpu = if ($script:gpuC.Count) { [Math]::Min(100, $g) } else { -1 }
            } else {
                if ($gpuFresh) { Clear-Gpu; $gpuFresh = $false }
                $n.Gpu = -1
            }

            if ($w.Ram) { $n.RamTot = [double]$ci.TotalPhysicalMemory; $n.RamUsed = $n.RamTot - [double]$ci.AvailablePhysicalMemory }

            $want = ($w.Disks -join ',')
            if ($w.Disks.Count -and ($null -eq $diskSw -or $diskSw.Elapsed.TotalSeconds -ge 30 -or $d.DiskKey -ne $want)) {
                $dd = @{}
                foreach ($lt in $w.Disks) {
                    try { $dr = New-Object IO.DriveInfo($lt); if ($dr.IsReady) { $dd[$lt] = @([double]($dr.TotalSize - $dr.AvailableFreeSpace), [double]$dr.TotalSize) } } catch {}
                }
                $d.Disks = $dd; $d.DiskKey = $want
                $diskSw = [Diagnostics.Stopwatch]::StartNew()
            }
            $n.Disks = $d.Disks

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
    Clear-Gpu
}

$rs = [runspacefactory]::CreateRunspace(); $rs.Open()
$bg = [powershell]::Create(); $bg.Runspace = $rs
[void]$bg.AddScript($collector).AddArgument($sync)
$bgHandle = $bg.BeginInvoke()

# =====================================================================
#  WIDGET UI
# =====================================================================
function Row($id, $label, $c1, $c2) {
@"
<StackPanel x:Name="${id}Row" Margin="0,12,0,0">
  <Grid>
    <StackPanel Orientation="Horizontal">
      <TextBlock Text="$label" Foreground="#B3FFFFFF" FontSize="12" FontWeight="SemiBold"/>
      <TextBlock x:Name="${id}Sub" Foreground="#8CFFFFFF" FontSize="10.5" Margin="8,1.5,0,0"/>
    </StackPanel>
    <TextBlock x:Name="${id}Val" Text="--" HorizontalAlignment="Right" Foreground="White" FontSize="14" FontWeight="Bold"/>
  </Grid>
  <Border Height="6" CornerRadius="3" Background="#2EFFFFFF" Margin="0,6,0,0">
    <Border x:Name="${id}Bar" HorizontalAlignment="Left" Width="0" CornerRadius="3">
      <Border.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,0">
          <GradientStop Color="$c1" Offset="0"/><GradientStop Color="$c2" Offset="1"/>
        </LinearGradientBrush>
      </Border.Background>
    </Border>
  </Border>
</StackPanel>
"@
}
function Info($id, $label) {
@"
<Grid x:Name="${id}Row" Margin="0,9,0,0">
  <TextBlock Text="$label" Foreground="#B3FFFFFF" FontSize="12" FontWeight="SemiBold"/>
  <TextBlock x:Name="${id}Val" Text="--" HorizontalAlignment="Right" Foreground="White" FontSize="12" FontWeight="SemiBold" TextTrimming="CharacterEllipsis" MaxWidth="190"/>
</Grid>
"@
}

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

function Disk-Rows {
    $out = ''
    foreach ($dv in $script:drives) { $out += (Row ('Disk' + $dv.Letter) ($dv.Letter + ':') '#85B7EB' '#9FE1CB') }
    $out
}
function Widget-Xaml {
    $winAttrs = 'Width="320" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" Background="Transparent"'
    $chrome = ''; $gridMargin = '10'; $radius = '22'; $edge = '1.2'
    @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="LiquidHUD" $winAttrs ShowInTaskbar="False"
            FontFamily="Segoe UI Variable Display, Segoe UI" UseLayoutRounding="True">
      $chrome
      <Grid Margin="$gridMargin">
        <Border x:Name="Halo" CornerRadius="23" Margin="-1" BorderThickness="1" BorderBrush="#66000000" IsHitTestVisible="False"/>
        <Border x:Name="Glass" CornerRadius="$radius" BorderThickness="$edge" Background="#800C0E16">
          <Border.BorderBrush>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#A0FFFFFF" Offset="0"/><GradientStop Color="#18FFFFFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.BorderBrush>
        </Border>
        <Border x:Name="Sheen" CornerRadius="$radius,$radius,0,0" Height="90" VerticalAlignment="Top" IsHitTestVisible="False">
          <Border.Background>
            <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
              <GradientStop Color="#26FFFFFF" Offset="0"/><GradientStop Color="#00FFFFFF" Offset="1"/>
            </LinearGradientBrush>
          </Border.Background>
        </Border>
    
        <Border x:Name="ContentWrap">
        <StackPanel x:Name="Content" Margin="20,16,20,18" Typography.NumeralAlignment="Tabular">
          <Grid>
            <StackPanel Orientation="Horizontal">
              <TextBlock Text="System" Foreground="White" FontSize="19" FontWeight="Bold"/>
              <Border x:Name="Pill" CornerRadius="9" BorderThickness="1" BorderBrush="#5DCAA5" Margin="10,4,0,0" Padding="9,1,9,2" VerticalAlignment="Center">
                <TextBlock x:Name="PillText" Text="chill" Foreground="#9FE1CB" FontSize="10.5" FontWeight="SemiBold"/>
              </Border>
            </StackPanel>
            <TextBlock x:Name="Clock" Text="--:--" HorizontalAlignment="Right" Foreground="White" FontSize="19" FontWeight="Light"/>
          </Grid>
    
          $(Row 'Cpu'  'CPU' '#85B7EB' '#AFA9EC')
          $(Row 'Gpu'  'GPU' '#9FE1CB' '#85B7EB')
          $(Row 'Ram'  'RAM' '#AFA9EC' '#85B7EB')
          $(Disk-Rows)
    
          <StackPanel x:Name="GraphRow">
            <Border Height="52" CornerRadius="10" Background="#14FFFFFF" Margin="0,14,0,0" ClipToBounds="True">
              <Canvas>
                <Polyline x:Name="LineGpu" Stroke="#9FE1CB" StrokeThickness="1.6" StrokeLineJoin="Round"/>
                <Polyline x:Name="LineCpu" Stroke="#85B7EB" StrokeThickness="1.6" StrokeLineJoin="Round"/>
              </Canvas>
            </Border>
            <TextBlock HorizontalAlignment="Right" FontSize="9.5" Foreground="#8CFFFFFF" Margin="0,3,0,0">
              <Run Text="&#x25CF;" Foreground="#85B7EB"/><Run Text=" cpu   "/><Run Text="&#x25CF;" Foreground="#9FE1CB"/><Run Text=" gpu"/>
            </TextBlock>
          </StackPanel>
    
          $(Info 'Net'  'Net')
          $(Info 'Batt' 'Battery')
          $(Info 'Up'   'Uptime')
          $(Info 'TopC' 'Top CPU')
          $(Info 'TopR' 'Top RAM')
        </StackPanel>
        </Border>
      </Grid>
    </Window>
"@
}

$script:win = $null
$textShadow = New-Object Windows.Media.Effects.DropShadowEffect
$textShadow.BlurRadius = 4; $textShadow.ShadowDepth = 0; $textShadow.Opacity = 1; $textShadow.Color = [Windows.Media.Colors]::Black
$textShadow.Freeze()
# second, wider halo layered on top: keeps white text readable on white wallpapers
$textHalo = New-Object Windows.Media.Effects.DropShadowEffect
$textHalo.BlurRadius = 9; $textHalo.ShadowDepth = 0; $textHalo.Opacity = 0.55; $textHalo.Color = [Windows.Media.Colors]::Black
$textHalo.Freeze()
$textShadowW = New-Object Windows.Media.Effects.DropShadowEffect
$textShadowW.BlurRadius = 4; $textShadowW.ShadowDepth = 0; $textShadowW.Opacity = 1; $textShadowW.Color = [Windows.Media.Colors]::White; $textShadowW.Freeze()
$textHaloW = New-Object Windows.Media.Effects.DropShadowEffect
$textHaloW.BlurRadius = 9; $textHaloW.ShadowDepth = 0; $textHaloW.Opacity = 0.6; $textHaloW.Color = [Windows.Media.Colors]::White; $textHaloW.Freeze()

function Build-Widget {
    if ($script:win) {
        $cfg.Left = $script:win.Left; $cfg.Top = $script:win.Top
        $script:win.ContextMenu = $null
        $script:win.Close()
    }
    $w = [Windows.Markup.XamlReader]::Parse((Widget-Xaml))
    $script:win = $w
    $script:ui = @{}
    foreach ($n in 'Halo','Glass','Sheen','Content','ContentWrap','Pill','PillText','Clock','CpuVal','CpuBar','CpuSub','GpuVal','GpuBar','GpuSub','RamVal','RamBar','RamSub',
                   'LineCpu','LineGpu','NetVal','BattVal','UpVal','TopCVal','TopRVal') { $script:ui[$n] = $w.FindName($n) }
    $script:rows = @{}
    foreach ($k in $metrics.Keys) { if ($k -ne 'Clock') { $script:rows[$k] = $w.FindName("${k}Row") } }
    $script:rows['Clock'] = $script:ui.Clock
    $script:edgeSolid = $script:ui.Glass.BorderBrush
    $script:diskUi = @{}
    foreach ($dv in $script:drives) {
        $id = 'Disk' + $dv.Letter
        $script:diskUi[$dv.Letter] = @{ Row = $w.FindName("${id}Row"); Val = $w.FindName("${id}Val"); Sub = $w.FindName("${id}Sub"); Bar = $w.FindName("${id}Bar") }
    }
    $script:barLast = @{}

    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($cfg.Left -lt 0 -or $cfg.Left -gt $wa.Right - 50) { $w.Left = $wa.Right - $w.Width - 16 } else { $w.Left = $cfg.Left }
    if ($cfg.Top -lt 0 -or $cfg.Top -gt $wa.Bottom - 50) { $w.Top = 40 } else { $w.Top = $cfg.Top }
    $w.Topmost = [bool]$cfg.Topmost

    $w.Add_SourceInitialized({ [LhNative]::ToolWindow((Win-Handle $script:win)) })
    $w.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -ge 2) { Start-Process taskmgr.exe; return }
        try { $script:win.DragMove() } catch {}
        Clamp-ToScreen $script:win
        $cfg.Left = $script:win.Left; $cfg.Top = $script:win.Top; Save-Cfg
    })
    if ($script:menu) { $w.ContextMenu = $script:menu }
    Apply-Look
    Apply-RowVisibility
    if (-not $cfg.WidgetHidden) { $w.Show(); $w.UpdateLayout(); Clamp-ToScreen $w }
}

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
  <Grid x:Name="oFull">
  <Border x:Name="oHalo" CornerRadius="12" Margin="-1" BorderThickness="1" BorderBrush="#66000000"/>
  <Border x:Name="oBg" CornerRadius="11" Background="#F00C0E16" BorderBrush="#40FFFFFF" BorderThickness="1"/>
  <Border x:Name="oPad" Padding="9,4,10,5">
    <StackPanel x:Name="oContent" Orientation="Horizontal" TextBlock.FontSize="12.5" Typography.NumeralAlignment="Tabular" VerticalAlignment="Center">
      <StackPanel x:Name="sCpu" Orientation="Horizontal"><Border x:Name="dCpu" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock Text="CPU" Foreground="#A6FFFFFF" FontWeight="SemiBold" Margin="0,0,3,0"/><TextBlock x:Name="oCpu" Text="--" Foreground="White" FontWeight="Bold"/></StackPanel>
      <StackPanel x:Name="sGpu" Orientation="Horizontal"><Border x:Name="dGpu" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock Text="GPU" Foreground="#A6FFFFFF" FontWeight="SemiBold" Margin="0,0,3,0"/><TextBlock x:Name="oGpu" Text="--" Foreground="#9FE1CB" FontWeight="Bold"/></StackPanel>
      <StackPanel x:Name="sRam" Orientation="Horizontal"><Border x:Name="dRam" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock Text="RAM" Foreground="#A6FFFFFF" FontWeight="SemiBold" Margin="0,0,3,0"/><TextBlock x:Name="oRam" Text="--" Foreground="White" FontWeight="Bold"/></StackPanel>
      <StackPanel x:Name="sGraph" Orientation="Horizontal"><Border x:Name="dGraph" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/>
        <Border Width="56" Height="18" CornerRadius="4" Background="#1AFFFFFF" ClipToBounds="True" VerticalAlignment="Center">
          <Canvas><Polyline x:Name="oLineRam" Stroke="#AFA9EC" StrokeThickness="1.3" StrokeLineJoin="Round"/><Polyline x:Name="oLineCpu" Stroke="#85B7EB" StrokeThickness="1.3" StrokeLineJoin="Round"/></Canvas>
        </Border>
      </StackPanel>
      <StackPanel x:Name="sNet" Orientation="Horizontal"><Border x:Name="dNet" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock Text="&#x2193;" Foreground="#A6FFFFFF" Margin="0,0,3,0"/><TextBlock x:Name="oDown" Foreground="White"/><TextBlock Text="&#x2191;" Foreground="#A6FFFFFF" Margin="7,0,3,0"/><TextBlock x:Name="oUp" Foreground="White"/></StackPanel>
      <StackPanel x:Name="sTopC" Orientation="Horizontal"><Border x:Name="dTopC" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock x:Name="oTopCName" Foreground="#CCFFFFFF" MaxWidth="110" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="oTopCVal" Foreground="White" FontWeight="SemiBold" Margin="5,0,0,0"/></StackPanel>
      <StackPanel x:Name="sTopR" Orientation="Horizontal"><Border x:Name="dTopR" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock x:Name="oTopRName" Foreground="#CCFFFFFF" MaxWidth="100" TextTrimming="CharacterEllipsis"/><TextBlock x:Name="oTopRVal" Foreground="White" FontWeight="SemiBold" Margin="5,0,0,0"/></StackPanel>
      <StackPanel x:Name="sBatt" Orientation="Horizontal"><Border x:Name="dBatt" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock x:Name="oBatt" Foreground="White" FontWeight="SemiBold"/></StackPanel>
      <StackPanel x:Name="sClock" Orientation="Horizontal"><Border x:Name="dClock" Width="1" Height="12" Background="#40FFFFFF" Margin="7,0,7,0" VerticalAlignment="Center"/><TextBlock x:Name="oClock" Foreground="White"/></StackPanel>
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
$solidFill = Brush '#F20C0E16'; $clearFill = Brush '#00000000'; $hitFill = Brush '#03000000'; $grabFill = Brush '#40000000'
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
                Full = $w.FindName('oFull'); Handle = $w.FindName('oHandle'); Collapsed = $false; LeaveAt = $null; Dark = $false; Shrink = @{}; Ink = (Collect-Ink $w) }
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
$fadeIn = New-Object Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [TimeSpan]::FromMilliseconds(160))
$ease0 = New-Object Windows.Media.Animation.CubicEase; $ease0.EasingMode = 'EaseOut'; $fadeIn.EasingFunction = $ease0; $fadeIn.Freeze()
function Set-OsdCollapsed($o, [bool]$c) {
    if ($o.Collapsed -eq $c) { return }
    $o.Collapsed = $c; $o.LeaveAt = $null
    if ($c) {
        $o.Full.Visibility = 'Collapsed'; $o.Handle.Visibility = 'Visible'
    } else {
        $o.Handle.Visibility = 'Collapsed'; $o.Full.Visibility = 'Visible'
        $o.Full.BeginAnimation([Windows.UIElement]::OpacityProperty, $fadeIn)
    }
    Apply-OsdLook $o
    $o.Win.UpdateLayout(); Place-Osd $o
}
function Apply-AutoHide {
    $on = AutoHide-Active
    foreach ($o in $script:osds) { Set-OsdCollapsed $o $on }
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
$hoverTimer.Interval = [TimeSpan]::FromMilliseconds(100)
$hoverTimer.Add_Tick({
    try {
        $p = [System.Windows.Forms.Cursor]::Position
        foreach ($o in $script:osds) {
            $rc = [LhNative]::Rect($o.H); $L = $rc[0]; $T = $rc[1]; $R = $rc[2]; $B = $rc[3]
            $sb = [System.Windows.Forms.Screen]::FromHandle($o.H).Bounds
            # generous hot zone around the thin pill, a grace margin around the full bar
            if ($o.Collapsed) { $dx = 28 * $script:dpi; $dy = 14 * $script:dpi } else { $dx = 14 * $script:dpi; $dy = 14 * $script:dpi }
            $zT = $T - $dy; $zB = $B + $dy
            # the gap between the bar and the screen edge always counts as "inside" -> no blinking
            if (@(0, 1, 2) -contains [int]$cfg.OverlayPos) { $zT = $sb.Top - 2 }
            if (@(3, 4, 6) -contains [int]$cfg.OverlayPos) { $zB = $sb.Bottom + 2 }
            $inside = ($p.X -ge $L - $dx) -and ($p.X -le $R + $dx) -and ($p.Y -ge $zT) -and ($p.Y -le $zB)
            if ($inside) {
                $o.LeaveAt = $null
                if ($o.Collapsed) { Set-OsdCollapsed $o $false }
            } elseif (-not $o.Collapsed) {
                if (-not $o.LeaveAt) { $o.LeaveAt = [DateTime]::Now.AddMilliseconds(500) }
                elseif ([DateTime]::Now -ge $o.LeaveAt) { Set-OsdCollapsed $o $true }
            }
        }
    } catch {}
})

# =====================================================================
#  LOOK (Outline / Solid) + METRIC VISIBILITY
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
        elseif ($e -is [Windows.Shapes.Polyline] -and $e.Stroke -is [Windows.Media.SolidColorBrush]) { [void]$list.Add(@($e, 'Stroke', $e.Stroke.Color)) }
        elseif ($e -is [Windows.Controls.Border] -and $e.Name -notin @('oBg', 'oHalo', 'oPad', 'oHandle') -and $e.Background -is [Windows.Media.SolidColorBrush]) { [void]$list.Add(@($e, 'Background', $e.Background.Color)) }
        foreach ($c in [Windows.LogicalTreeHelper]::GetChildren($e)) { if ($c -is [Windows.DependencyObject]) { $stack.Push($c) } }
    }
    ,$list
}
$inkMap = @{ 'FF9FE1CB' = 'FF0F6E56'; 'FF85B7EB' = 'FF185FA5'; 'FFAFA9EC' = 'FF534AB7'; 'FFF09595' = 'FFA32D2D' }
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
            $o.Body.Effect = $textShadowW; $o.Pad.Effect = $textHaloW
        } else {
            $o.Bg.Background = $clearFill; $o.Bg.BorderBrush = $outlineEdge; $o.Bg.BorderThickness = 1
            $o.Halo.BorderBrush = $haloDark
            $o.Body.Effect = $textShadow; $o.Pad.Effect = $textHalo
        }
    }
    Apply-OsdInk $o
}
function Apply-Look {
    if ($script:ui) {
        $g = $script:ui.Glass
        if ($cfg.Look -eq 'Solid') {
            $g.Background = $solidFill; $g.BorderBrush = $script:edgeSolid; $g.BorderThickness = 1.2
            $script:ui.Sheen.Visibility = 'Visible'; $script:ui.Halo.Visibility = 'Collapsed'
            $script:ui.Content.Effect = $null; $script:ui.ContentWrap.Effect = $null
        } else {
            $g.Background = $hitFill; $g.BorderBrush = $outlineEdge; $g.BorderThickness = 1   # 1% fill so it can still be dragged
            $script:ui.Sheen.Visibility = 'Collapsed'; $script:ui.Halo.Visibility = 'Visible'
            $script:ui.Content.Effect = $textShadow; $script:ui.ContentWrap.Effect = $textHalo
        }
    }
    foreach ($o in $script:osds) { Apply-OsdLook $o }
    if ($cfg.OverlayFree) { Apply-Free }
}
function Apply-RowVisibility {
    if (-not $script:rows) { return }
    foreach ($k in $metrics.Keys) { $script:rows[$k].Visibility = if ($cfg.Show.$k) { 'Visible' } else { 'Collapsed' } }
    foreach ($lt in $script:diskUi.Keys) { $script:diskUi[$lt].Row.Visibility = if ($cfg.Disks[$lt]) { 'Visible' } else { 'Collapsed' } }
}
function Apply-Metrics {
    Apply-RowVisibility
    foreach ($o in $script:osds) { Apply-OsdMetrics $o; $o.Win.UpdateLayout(); Place-Osd $o }
    $sync.Want = Want-Table
}

# =====================================================================
#  SETTINGS WINDOW
# =====================================================================
$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LiquidHUD Settings" Width="1000" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" Background="Transparent"
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
        <Grid.ColumnDefinitions><ColumnDefinition Width="300"/><ColumnDefinition Width="28"/><ColumnDefinition Width="300"/><ColumnDefinition Width="28"/><ColumnDefinition Width="300"/></Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0">
      <TextBlock Style="{StaticResource Head}" Text="Show"/>
      <StackPanel Orientation="Horizontal">
        <CheckBox x:Name="sShowW" Content="Big widget"/>
        <CheckBox x:Name="sShowO" Content="Game overlay"/>
      </StackPanel>
      <TextBlock x:Name="sNone" Text="Both off: press Ctrl+Alt+S to get back here" Foreground="#FAC775" FontSize="11" Margin="0,0,0,4" Visibility="Collapsed"/>

      <TextBlock Style="{StaticResource Head}" Text="Look"/>
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="sLO" GroupName="look" Content="Outline  (text + frame)"/>
        <RadioButton x:Name="sLS" GroupName="look" Content="Solid  (filled)"/>
      </StackPanel>

      <TextBlock Style="{StaticResource Head}" Text="Overlay position"/>
      <WrapPanel x:Name="sPos"/>
      <CheckBox x:Name="sFree" Width="300" Margin="0,6,0,0" Content="Free move  (drag the overlay, untick to lock it)"/>
      <CheckBox x:Name="sAuto" Width="300" Margin="0,0,0,0" Content="Auto-hide  (thin bar, hover to show)"/>
      <CheckBox x:Name="sGame" Width="300" Margin="0,8,0,0" Content="Game mode  (stay open over fullscreen apps)"/>
      <CheckBox x:Name="sInk" Width="300" Margin="0,8,0,0" Content="Adaptive text  (black on bright, white on dark)"/>

      <TextBlock Style="{StaticResource Head}" Text="Clock"/>
      <StackPanel Orientation="Horizontal">
        <RadioButton x:Name="sC24" GroupName="clk" Content="24h  (18:46)"/>
        <RadioButton x:Name="sC12" GroupName="clk" Content="12h  (6:46 PM)"/>
      </StackPanel>


        </StackPanel>
        <StackPanel Grid.Column="2">
      <TextBlock Style="{StaticResource Head}" Text="Big widget shows"/>
      <WrapPanel x:Name="sChecks"/>

      <TextBlock Style="{StaticResource Head}" Text="Disks"/>
      <WrapPanel x:Name="sDisks"/>

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
        </StackPanel>
        <StackPanel Grid.Column="4">
      <TextBlock Style="{StaticResource Head}" Text="Game overlay shows"/>
      <WrapPanel x:Name="sOsdChecks"/>
      <TextBlock Text="The overlay bar keeps a fixed width, so it never jumps around when numbers change." Foreground="#8CFFFFFF" FontSize="10.5" TextWrapping="Wrap" Margin="0,6,0,0"/>
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
    $s.sShowW.IsChecked = -not [bool]$cfg.WidgetHidden
    $s.sShowO.IsChecked = [bool]$cfg.Overlay
    $s.sNone.Visibility = if ($cfg.WidgetHidden -and -not $cfg.Overlay) { 'Visible' } else { 'Collapsed' }
    $s.sLO.IsChecked = ($cfg.Look -ne 'Solid'); $s.sLS.IsChecked = ($cfg.Look -eq 'Solid')
    $s.sFree.IsChecked = [bool]$cfg.OverlayFree
    $s.sAuto.IsChecked = [bool]$cfg.OverlayAutoHide
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
function Fill-DiskChecks {
    if (-not $script:sUi) { return }
    $p = $script:sUi.sDisks; $p.Children.Clear()
    foreach ($dv in $script:drives) {
        $cb = New-Object Windows.Controls.CheckBox
        $size = if ($dv.Total -ge 1TB) { '{0:N1} TB' -f ($dv.Total / 1TB) } else { '{0:N0} GB' -f ($dv.Total / 1GB) }
        $name = if ($dv.Label) { $dv.Label } else { 'Disk' }
        $cb.Content = '{0}:  {1}  ({2})' -f $dv.Letter, $name, $size
        $cb.Width = 300; $cb.Tag = $dv.Letter; $cb.IsChecked = [bool]$cfg.Disks[$dv.Letter]
        $cb.Add_Click({ $cfg.Disks[$this.Tag] = [bool]$this.IsChecked; Apply-Metrics; Save-Cfg })
        [void]$p.Children.Add($cb)
    }
    if (-not $script:drives.Count) {
        $tb = New-Object Windows.Controls.TextBlock; $tb.Text = 'No disks found'; $tb.Foreground = $white
        [void]$p.Children.Add($tb)
    }
}
# new USB / extra disk plugged in? rescan when Settings opens and rebuild the widget if the list changed
function Refresh-Drives {
    $now = Get-Drives
    $a = ($script:drives | ForEach-Object { $_.Letter }) -join ','
    $b = ($now | ForEach-Object { $_.Letter }) -join ','
    if ($a -ne $b) {
        $script:drives = $now
        foreach ($dv in $now) { if (-not $cfg.Disks.ContainsKey($dv.Letter)) { $cfg.Disks[$dv.Letter] = $true } }
        Build-Widget; $sync.Want = Want-Table
    }
}
function Open-Settings {
    if ($script:sWin) { Refresh-Drives; Fill-DiskChecks; Sync-Settings; $script:sWin.Show(); $script:sWin.Activate() | Out-Null; return }
    $sw = [Windows.Markup.XamlReader]::Parse($settingsXaml)
    $script:sWin = $sw
    $script:sUi = @{}
    foreach ($n in 'sRoot','sClose','sChecks','sR1','sR2','sR5','sSelf','sPos','sFree','sAuto','sGame','sInk','sDisks','sShowW','sShowO','sNone','sLO','sLS','sC24','sC12','sOsdChecks') { $script:sUi[$n] = $sw.FindName($n) }
    $s = $script:sUi

    $s.sShowW.Add_Click({ if ([bool]$this.IsChecked -eq [bool]$cfg.WidgetHidden) { Toggle-Widget } })
    $s.sShowO.Add_Click({ if ([bool]$this.IsChecked -ne [bool]$cfg.Overlay) { Toggle-Overlay } })
    $s.sLO.Tag = 'Outline'; $s.sLS.Tag = 'Solid'
    $s.sLO.Add_Click({ Set-Look 'Outline' }); $s.sLS.Add_Click({ Set-Look 'Solid' })

    foreach ($k in $metrics.Keys) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $metrics[$k]; $cb.Tag = $k; $cb.IsChecked = [bool]$cfg.Show.$k
        $cb.Add_Click({ $cfg.Show.($this.Tag) = [bool]$this.IsChecked; Apply-Metrics; Save-Cfg })
        [void]$s.sChecks.Children.Add($cb)
    }

    $script:posRadios = @()
    foreach ($i in $posOrder) {
        $rb = New-Object Windows.Controls.RadioButton
        $rb.GroupName = 'pos'; $rb.Content = $posNames[$i]; $rb.Tag = $i
        $rb.IsChecked = ([int]$cfg.OverlayPos -eq $i)
        if ($i -eq 5) { $rb.ToolTip = 'Where you last dropped it with Free move' }
        $rb.Add_Click({ Set-Pos ([int]$this.Tag) })
        [void]$s.sPos.Children.Add($rb); $script:posRadios += $rb
    }
    $s.sFree.IsChecked = [bool]$cfg.OverlayFree
    $s.sFree.Add_Click({ Set-Free ([bool]$this.IsChecked) })
    $s.sAuto.Add_Click({ Set-AutoHide ([bool]$this.IsChecked) })
    $s.sGame.Add_Click({ $cfg.GameMode = [bool]$this.IsChecked; Save-Cfg; $script:inFullscreen = $false; Apply-AutoHide })
    $s.sInk.Add_Click({ $cfg.AdaptiveInk = [bool]$this.IsChecked; Save-Cfg })

    foreach ($k in $osdLabels.Keys) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $osdLabels[$k]; $cb.Tag = $k; $cb.IsChecked = [bool]$cfg.OsdShow.$k
        $cb.Add_Click({ $cfg.OsdShow.($this.Tag) = [bool]$this.IsChecked; Apply-Metrics; Save-Cfg })
        [void]$s.sOsdChecks.Children.Add($cb)
    }
    $s.sC24.Add_Click({ Set-Clock $true }); $s.sC12.Add_Click({ Set-Clock $false })

    Fill-DiskChecks

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
  <MenuItem x:Name="mHide"     Header="Big widget" InputGestureText="Ctrl+Alt+H"/>
  <MenuItem x:Name="mLook"     Header="Look: Outline"/>
  <MenuItem x:Name="mTop"      Header="Widget always on top"/>
  <MenuItem x:Name="mStartup"  Header="Start with Windows"/>
  <MenuItem x:Name="mTask"     Header="Task Manager"/>
  <MenuItem x:Name="mExit"     Header="Exit"/>
</ContextMenu>
"@
$script:menu = [Windows.Markup.XamlReader]::Parse($menuXaml)
$menu = $script:menu
$mi = @{}
foreach ($n in 'mSettings','mOverlay','mPos','mFree','mAuto','mAll','mHide','mLook','mTop','mStartup','mTask','mExit') { $mi[$n] = $menu.FindName($n) }
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LiquidHUD.lnk'

function Refresh-Menu {
    $mi.mOverlay.IsChecked = [bool]$cfg.Overlay
    $mi.mAll.IsChecked = [bool]$cfg.OverlayAll
    $mi.mFree.IsChecked = [bool]$cfg.OverlayFree
    $mi.mAuto.IsChecked = [bool]$cfg.OverlayAutoHide
    $mi.mPos.Header = 'Overlay position: ' + $posNames[[int]$cfg.OverlayPos]
    $mi.mTop.IsChecked = [bool]$cfg.Topmost
    $mi.mStartup.IsChecked = Test-Path $startupLnk
    $mi.mLook.Header = 'Look: ' + $cfg.Look + '  (click to switch)'
    $mi.mHide.IsChecked = -not [bool]$cfg.WidgetHidden
}
function Toggle-Overlay { $cfg.Overlay = -not $cfg.Overlay; if (-not $cfg.Overlay) { $cfg.OverlayFree = $false }; Save-Cfg; Build-Osds; $sync.Want = Want-Table; Sync-Settings; Refresh-Menu }
function Cycle-Pos { $k = [array]::IndexOf($posOrder, [int]$cfg.OverlayPos); Set-Pos $posOrder[($k + 1) % $posOrder.Count] }
function Toggle-Widget {
    $cfg.WidgetHidden = -not $cfg.WidgetHidden; Save-Cfg
    if ($cfg.WidgetHidden) { $win.Hide() } else { $win.Show() }
    Sync-Settings; Refresh-Menu
    $sync.Want = Want-Table
}
function Quit-All {
    $timer.Stop(); $hoverTimer.Stop(); $watchTimer.Stop(); $sync.Stop = $true
    $cfg.OverlayFree = $false
    $cfg.Left = $win.Left; $cfg.Top = $win.Top; Save-Cfg
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
$mi.mHide.Add_Click({ Toggle-Widget })
$mi.mLook.Add_Click({ Set-Look $(if ($cfg.Look -eq 'Solid') { 'Outline' } else { 'Solid' }) })
$mi.mTop.Add_Click({ $cfg.Topmost = -not $cfg.Topmost; $win.Topmost = [bool]$cfg.Topmost; Save-Cfg; Refresh-Menu })
$mi.mStartup.Add_Click({
    if (-not (Test-Path $startupLnk)) {
        $ws = New-Object -ComObject WScript.Shell
        $l = $ws.CreateShortcut($startupLnk)
        $l.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
        $l.Arguments = "-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        $l.WindowStyle = 7
        $l.Save()
    } else { Remove-Item $startupLnk -ErrorAction SilentlyContinue }
    Refresh-Menu
})
$mi.mTask.Add_Click({ Start-Process taskmgr.exe })
$mi.mExit.Add_Click({ Quit-All })
$menu.Add_Opened({ Refresh-Menu })

# ---------- global hotkeys ----------
$hk = New-Object LhHotkeys
$MOD = 0x0002 -bor 0x0001 -bor 0x4000    # Ctrl + Alt + NoRepeat
[void]$hk.Register(1, $MOD, 0x4F)   # O
[void]$hk.Register(2, $MOD, 0x50)   # P
[void]$hk.Register(3, $MOD, 0x48)   # H
[void]$hk.Register(4, $MOD, 0x53)   # S
[void]$hk.Register(5, $MOD, 0x4D)   # M
$hk.Add_Pressed({
    param($id)
    switch ($id) { 1 { Toggle-Overlay } 2 { Cycle-Pos } 3 { Toggle-Widget } 4 { Open-Settings } 5 { Set-Free (-not $cfg.OverlayFree) } }
})

# =====================================================================
#  UPDATE LOOP (UI thread - lightweight)
# =====================================================================
function Fmt-Bytes([double]$b) {
    if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } elseif ($b -ge 1MB) { '{0:N1} MB' -f ($b / 1MB) }
    elseif ($b -ge 1KB) { '{0:N0} KB' -f ($b / 1KB) } else { '{0:N0} B' -f $b }
}
$histCpu = New-Object System.Collections.Generic.List[double]
$histGpu = New-Object System.Collections.Generic.List[double]
function Draw-Line($line, $hist, [double]$wd = 260, [double]$ht = 52, [int]$max = 60) {
    $pc = New-Object Windows.Media.PointCollection($hist.Count)
    $n = $hist.Count; $step = $wd / ($max - 1); $pad = 2; $scale = ($ht - 2 * $pad) / 100
    for ($i = 0; $i -lt $n; $i++) {
        $pc.Add((New-Object Windows.Point((($max - $n + $i) * $step), ($ht - $pad - ([Math]::Min(100, $hist[$i]) * $scale)))))
    }
    $pc.Freeze(); $line.Points = $pc
}
$histOC = New-Object System.Collections.Generic.List[double]
$histOR = New-Object System.Collections.Generic.List[double]
$ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'; $ease.Freeze()
$barLast = @{}
function Set-Bar($bar, [double]$pct) {
    $wd = [Math]::Round([Math]::Max(0, [Math]::Min(100, $pct)) * 2.6)
    if ($barLast[$bar.Name] -eq $wd) { return }        # no change = no redraw
    $barLast[$bar.Name] = $wd
    $bar.Width = $wd                                    # instant: animations re-render the whole layered window at 60 fps
}
function Set-Text($tb, $txt) { if ($tb.Text -ne $txt) { $tb.Text = $txt } }
$white = Brush '#FFFFFF'; $hot = Brush '#F09595'
$pill = @{
    chill    = @((Brush '#9FE1CB'), (Brush '#5DCAA5'))
    busy     = @((Brush '#FAC775'), (Brush '#EF9F27'))
    'hot!' = @((Brush '#F7C1C1'), (Brush '#E24B4A'))
}
$bootTime = [DateTime]::Now
try { $bootTime = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime } catch {}
$arrowDown = [string][char]0x2193; $arrowUp = [string][char]0x2191

$timer = New-Object Windows.Threading.DispatcherTimer([Windows.Threading.DispatcherPriority]::Background)
$timer.Interval = [TimeSpan]::FromSeconds([int]$cfg.Interval)
$timer.Add_Tick({
  try {
    $d = $sync.Data
    if (-not $d) { return }
    $S = $cfg.Show
    $clock = if ($cfg.Clock24) { [DateTime]::Now.ToString('HH:mm') } else { [DateTime]::Now.ToString('h:mm tt', [Globalization.CultureInfo]::InvariantCulture) }
    $gpu = [Math]::Max(0, $d.Gpu)
    $gpuTxt = if ($d.Gpu -ge 0) { '{0:N0}%' -f $gpu } else { 'n/a' }
    $ramPct = if ($d.RamTot) { $d.RamUsed / $d.RamTot * 100 } else { 0 }
    $cpuTxt = '{0:N0}%' -f $d.Cpu
    $ramTxt = '{0:N0}%' -f $ramPct
    $netTxt = if ($null -ne $d.Down) { '{0} {1}/s  {2} {3}/s' -f $arrowDown, (Fmt-Bytes $d.Down), $arrowUp, (Fmt-Bytes $d.Up) } else { '' }

    $osdGraph = $cfg.Overlay -and $cfg.OsdShow.Graph
    if ($osdGraph) {
        $histOC.Add($d.Cpu); $histOR.Add($ramPct)
        while ($histOC.Count -gt 30) { $histOC.RemoveAt(0); $histOR.RemoveAt(0) }
    }
    $downTxt = if ($null -ne $d.Down) { (Fmt-Bytes $d.Down) + '/s' } else { '' }
    $upTxt = if ($null -ne $d.Up) { (Fmt-Bytes $d.Up) + '/s' } else { '' }
    foreach ($o in $script:osds) {
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
        if (-not $o.Collapsed) {
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

    if (-not $cfg.WidgetHidden) {
        if ($cfg.Topmost) { [LhNative]::Top((Win-Handle $win)) }
        if ($S.Clock) { Set-Text $ui.Clock $clock }
        $st = if ($d.Cpu -gt 85) { 'hot!' } elseif ($d.Cpu -ge 40) { 'busy' } else { 'chill' }
        if ($ui.PillText.Text -ne $st) { $ui.PillText.Text = $st; $ui.PillText.Foreground = $pill[$st][0]; $ui.Pill.BorderBrush = $pill[$st][1] }

        if ($S.Cpu) {
            Set-Text $ui.CpuVal $cpuTxt
            $ui.CpuVal.Foreground = if ($d.Cpu -gt 85) { $hot } else { $white }
            Set-Text $ui.CpuSub "$($d.Cores) threads"
            Set-Bar $ui.CpuBar $d.Cpu
        }
        if ($S.Gpu) { Set-Text $ui.GpuVal $gpuTxt; Set-Bar $ui.GpuBar $gpu }
        if ($S.Ram -and $d.RamTot) {
            Set-Text $ui.RamVal $ramTxt
            $ui.RamVal.Foreground = if ($ramPct -gt 85) { $hot } else { $white }
            Set-Text $ui.RamSub ('{0:N1} / {1:N1} GB' -f ($d.RamUsed / 1GB), ($d.RamTot / 1GB))
            Set-Bar $ui.RamBar $ramPct
        }
        foreach ($lt in $script:diskUi.Keys) {
            if (-not $cfg.Disks[$lt] -or -not $d.Disks -or -not $d.Disks.ContainsKey($lt)) { continue }
            $du = $d.Disks[$lt][0]; $dt = $d.Disks[$lt][1]; if (-not $dt) { continue }
            $dp = $du / $dt * 100; $dui = $script:diskUi[$lt]
            Set-Text $dui.Val ('{0:N0}%' -f $dp)
            $dui.Val.Foreground = if ($dp -gt 90) { $hot } else { $white }
            Set-Text $dui.Sub $(if ($dt -ge 1TB) { '{0:N2} / {1:N2} TB' -f ($du / 1TB), ($dt / 1TB) } else { '{0:N0} / {1:N0} GB' -f ($du / 1GB), ($dt / 1GB) })
            Set-Bar $dui.Bar $dp
        }
        if ($S.Net) { Set-Text $ui.NetVal $netTxt.Replace('  ', '    ') }
        if ($S.Batt -and $null -ne $d.NoBatt) {
            if ($d.NoBatt) { Set-Text $ui.BattVal 'no battery' }
            else { Set-Text $ui.BattVal (('{0:N0}%' -f $d.Batt) + $(if ($d.Charging) { '  ' + [char]0x26A1 + ' charging' } else { '' })) }
        }
        if ($S.Up) { $u = [DateTime]::Now - $bootTime; Set-Text $ui.UpVal ('{0}d {1}h {2}m' -f $u.Days, $u.Hours, $u.Minutes) }
        if ($S.TopC -and $d.TopC) { Set-Text $ui.TopCVal $d.TopC }
        if ($S.TopR -and $d.TopR) { Set-Text $ui.TopRVal ('{0}  {1}' -f $d.TopR, (Fmt-Bytes $d.TopRBytes)) }

        if ($S.Graph) {
            $histCpu.Add($d.Cpu); $histGpu.Add($gpu)
            while ($histCpu.Count -gt 60) { $histCpu.RemoveAt(0); $histGpu.RemoveAt(0) }
            Draw-Line $ui.LineCpu $histCpu
            if ($S.Gpu) { Draw-Line $ui.LineGpu $histGpu } else { $ui.LineGpu.Points = $null }
        }
    }

    if ($script:sWin -and $script:sWin.IsVisible) {
        Set-Text $script:sUi.sSelf ('{0:N0} MB RAM in use  ({1:N0} MB reserved)   |   {2:N1}% CPU' -f ($d.SelfWs / 1MB), ($d.SelfPriv / 1MB), [Math]::Max(0, $d.SelfCpu))
    }
  } catch {}
})

# ---------- start ----------
if ($cfg.WidgetHidden -and -not $cfg.Overlay) { $cfg.WidgetHidden = $false }
Build-Widget
Build-Osds
Apply-Metrics
Apply-Look
$timer.Start()
[Windows.Threading.Dispatcher]::Run()
try { [void]$bg.EndInvoke($bgHandle) } catch {}
$bg.Dispose(); $rs.Close()
