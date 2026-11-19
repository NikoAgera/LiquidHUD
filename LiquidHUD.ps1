# =====================================================================
#  LiquidHUD v5  -  glass system monitor widget + game overlay for Windows
#  Pure PowerShell + WPF (built into Windows). Nothing to install.
#  https://github.com/NikoAgera/LiquidHUD
#
#  HOTKEYS (work even inside games):
#    Ctrl+Alt+S  = open Settings (opacity, metrics, refresh rate)
#    Ctrl+Alt+O  = toggle game overlay (small click-through bar on top of everything)
#    Ctrl+Alt+P  = cycle overlay position
#    Ctrl+Alt+H  = hide/show the big widget
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

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class LhNative {
    [StructLayout(LayoutKind.Sequential)] public struct MARGINS { public int L, R, T, B; }
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int val, int size);
    [DllImport("dwmapi.dll")] static extern int DwmExtendFrameIntoClientArea(IntPtr h, ref MARGINS m);
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
    [DllImport("psapi.dll")] static extern bool EmptyWorkingSet(IntPtr p);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);

    static void Set(IntPtr h, int attr, int v) { DwmSetWindowAttribute(h, attr, ref v, 4); }

    public static void Glass(IntPtr h, int backdrop) {
        MARGINS m = new MARGINS(); m.L = m.R = m.T = m.B = -1;
        DwmExtendFrameIntoClientArea(h, ref m);
        Set(h, 20, 1); Set(h, 33, 2); Set(h, 34, 0x00707070); Set(h, 38, backdrop);
    }
    public static void MakeOverlay(IntPtr h) {
        long ex = GetWindowLongPtr(h, -20).ToInt64();
        ex |= 0x20 | 0x80 | 0x08000000 | 0x80000;
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
try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch {}

$modern = [Environment]::OSVersion.Version.Build -ge 22621

# ---------- metric list ----------
$metrics = [ordered]@{
    Cpu = 'CPU'; Gpu = 'GPU'; Ram = 'RAM'; Disk = 'Disk C:'; Graph = 'Graph (60s)'
    Net = 'Network'; Batt = 'Battery'; Up = 'Uptime'; TopC = 'Top CPU app'; TopR = 'Top RAM app'; Clock = 'Clock'
}

# ---------- settings ----------
$cfgDir  = Join-Path $env:APPDATA 'LiquidHUD'
$cfgFile = Join-Path $cfgDir 'settings.json'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir | Out-Null }
$showDefault = [ordered]@{}; foreach ($k in $metrics.Keys) { $showDefault[$k] = $true }
$cfg = [pscustomobject]@{
    Left = -1; Top = 40; Topmost = $false; Style = 'Clear'; Overlay = $false; OverlayAll = $true; OverlayPos = 2
    WidgetHidden = $false; WidgetOpacity = 55; OverlayOpacity = 45; Interval = 2
    Show = [pscustomobject]$showDefault
}
if (Test-Path $cfgFile) {
    try {
        $j = Get-Content $cfgFile -Raw | ConvertFrom-Json
        foreach ($p in $cfg.PSObject.Properties.Name) { if ($p -ne 'Show' -and $null -ne $j.$p) { $cfg.$p = $j.$p } }
        if ($j.Show) { foreach ($k in $metrics.Keys) { if ($null -ne $j.Show.$k) { $cfg.Show.$k = [bool]$j.Show.$k } } }
    } catch {}
}
if (@(1, 2, 5) -notcontains [int]$cfg.Interval) { $cfg.Interval = 2 }
if (@('Clear', 'Acrylic', 'Mica') -notcontains $cfg.Style) { $cfg.Style = 'Clear' }
if (-not $modern) { $cfg.Style = 'Clear' }
function Save-Cfg { try { $cfg | ConvertTo-Json -Depth 3 | Set-Content -Path $cfgFile -Encoding UTF8 } catch {} }
function Want-Table {
    $w = @{}; foreach ($k in $metrics.Keys) { $w[$k] = [bool]$cfg.Show.$k }
    $w.Graph = $w.Graph -and -not $cfg.WidgetHidden
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
    $d = @{ TopC = ''; TopR = ''; TopRBytes = 0; DiskUsed = 0; DiskTot = 0 }

    while (-not $sync.Stop) {
        $loop = [Diagnostics.Stopwatch]::StartNew()
        $w = $sync.Want
        try {
            $n = @{ Cores = $cores }
            $n.Cpu = if ($cpuC) { [Math]::Min(100, $cpuC.NextValue()) } else { 0 }

            # GPU counters are the most expensive -> only when enabled
            if ($w.Gpu) {
                if (-not $gpuFresh -or $gpuSw.Elapsed.TotalSeconds -ge 30) { Refresh-Gpu; $gpuSw.Restart(); $gpuFresh = $true }
                $g = 0.0
                foreach ($c in $script:gpuC) { try { $g += $c.NextValue() } catch {} }
                $n.Gpu = if ($script:gpuC.Count) { [Math]::Min(100, $g) } else { -1 }
            } else {
                if ($gpuFresh) { Clear-Gpu; $gpuFresh = $false }
                $n.Gpu = -1
            }

            if ($w.Ram) { $n.RamTot = [double]$ci.TotalPhysicalMemory; $n.RamUsed = $n.RamTot - [double]$ci.AvailablePhysicalMemory }

            if ($w.Disk -and ($null -eq $diskSw -or $diskSw.Elapsed.TotalSeconds -ge 30)) {
                $dr = New-Object IO.DriveInfo('C')
                $d.DiskTot = [double]$dr.TotalSize; $d.DiskUsed = [double]($dr.TotalSize - $dr.AvailableFreeSpace)
                $diskSw = [Diagnostics.Stopwatch]::StartNew()
            }
            $n.DiskTot = $d.DiskTot; $n.DiskUsed = $d.DiskUsed

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
            if (($w.TopC -or $w.TopR) -and $procSw.Elapsed.TotalSeconds -ge 5) {
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
                if ($bk) { $d.TopC = '{0}  {1:N0}%' -f $bk, ([Math]::Min(100, $bv / ($el * $cores) * 100)) }
                $bk = $null; $bv = -1.0
                foreach ($e in $ramBy.GetEnumerator()) { if ($e.Value -gt $bv) { $bv = $e.Value; $bk = $e.Key } }
                if ($bk) { $d.TopR = $bk; $d.TopRBytes = $bv }
                $cpuBy = $null; $ramBy = $null
            }
            $n.TopC = $d.TopC; $n.TopR = $d.TopR; $n.TopRBytes = $d.TopRBytes

            # how much LiquidHUD itself is using
            $self.Refresh()
            $st = $self.TotalProcessorTime.TotalSeconds; $se = [Math]::Max(0.2, $selfSw.Elapsed.TotalSeconds); $selfSw.Restart()
            $n.SelfCpu = ($st - $selfPrev) / ($se * $cores) * 100; $selfPrev = $st
            $n.SelfRam = $self.WorkingSet64
            $n.SelfPriv = $self.PrivateMemorySize64

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

$chromeXaml = '<WindowChrome.WindowChrome><WindowChrome GlassFrameThickness="-1" CaptionHeight="0" ResizeBorderThickness="0" CornerRadius="0" UseAeroCaptionButtons="False"/></WindowChrome.WindowChrome>'
$bc = New-Object Windows.Media.BrushConverter
function Brush($hex) { $b = $bc.ConvertFromString($hex); $b.Freeze(); $b }
function Win-Handle($w) { (New-Object Windows.Interop.WindowInteropHelper($w)).EnsureHandle() }

# Style: Clear = real see-through (layered window). Acrylic / Mica = Windows 11 blur (DWM).
function Use-Dwm { $modern -and $cfg.Style -ne 'Clear' }
function Backdrop-Id { if ($cfg.Style -eq 'Mica') { 2 } else { 3 } }
function Apply-Glass($w, $bd) {
    if (-not $modern) { return }
    $h = Win-Handle $w
    $src = [Windows.Interop.HwndSource]::FromHwnd($h)
    if ($src) { $src.CompositionTarget.BackgroundColor = [Windows.Media.Colors]::Transparent }
    [LhNative]::Glass($h, [int]$bd)
}

function Widget-Xaml {
    if (Use-Dwm) {
        $winAttrs = 'Width="300" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize" Background="Transparent"'
        $chrome = $chromeXaml; $gridMargin = '0'; $radius = '0'; $edge = '0'
    } else {
        $winAttrs = 'Width="320" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" Background="Transparent"'
        $chrome = ''; $gridMargin = '10'; $radius = '22'; $edge = '1.2'
    }
    @"
    <Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
            Title="LiquidHUD" $winAttrs ShowInTaskbar="False"
            FontFamily="Segoe UI Variable Display, Segoe UI" UseLayoutRounding="True">
      $chrome
      <Grid Margin="$gridMargin">
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
    
        <StackPanel x:Name="Content" Margin="20,16,20,18">
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
          $(Row 'Disk' 'C:'  '#85B7EB' '#9FE1CB')
    
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
      </Grid>
    </Window>
"@
}

$script:win = $null
$textShadow = New-Object Windows.Media.Effects.DropShadowEffect
$textShadow.BlurRadius = 6; $textShadow.ShadowDepth = 0; $textShadow.Opacity = 0.95; $textShadow.Color = [Windows.Media.Colors]::Black
$textShadow.Freeze()

function Build-Widget {
    if ($script:win) {
        $cfg.Left = $script:win.Left; $cfg.Top = $script:win.Top
        $script:win.ContextMenu = $null
        $script:win.Close()
    }
    $w = [Windows.Markup.XamlReader]::Parse((Widget-Xaml))
    $script:win = $w
    $script:ui = @{}
    foreach ($n in 'Glass','Sheen','Content','Pill','PillText','Clock','CpuVal','CpuBar','CpuSub','GpuVal','GpuBar','GpuSub','RamVal','RamBar','RamSub',
                   'DiskVal','DiskBar','DiskSub','LineCpu','LineGpu','NetVal','BattVal','UpVal','TopCVal','TopRVal') { $script:ui[$n] = $w.FindName($n) }
    $script:rows = @{}
    foreach ($k in $metrics.Keys) { if ($k -ne 'Clock') { $script:rows[$k] = $w.FindName("${k}Row") } }
    $script:rows['Clock'] = $script:ui.Clock
    $script:barLast = @{}

    $wa = [System.Windows.SystemParameters]::WorkArea
    if ($cfg.Left -lt 0 -or $cfg.Left -gt $wa.Right - 50) { $w.Left = $wa.Right - $w.Width - 16 } else { $w.Left = $cfg.Left }
    if ($cfg.Top -lt 0 -or $cfg.Top -gt $wa.Bottom - 50) { $w.Top = 40 } else { $w.Top = $cfg.Top }
    $w.Topmost = [bool]$cfg.Topmost

    $w.Add_SourceInitialized({
        if (Use-Dwm) { Apply-Glass $script:win (Backdrop-Id) }
        [LhNative]::ToolWindow((Win-Handle $script:win))
    })
    $w.Add_MouseLeftButtonDown({
        param($s, $e)
        if ($e.ClickCount -ge 2) { Start-Process taskmgr.exe; return }
        try { $script:win.DragMove() } catch {}
        $cfg.Left = $script:win.Left; $cfg.Top = $script:win.Top; Save-Cfg
    })
    if ($script:menu) { $w.ContextMenu = $script:menu }
    Apply-Opacity
    if ($script:rows) { foreach ($k in $metrics.Keys) { $script:rows[$k].Visibility = if ($cfg.Show.$k) { 'Visible' } else { 'Collapsed' } } }
    if (-not $cfg.WidgetHidden) { $w.Show() }
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
  <Grid>
  <Border x:Name="oBg" CornerRadius="11" Background="#F00C0E16" BorderBrush="#40FFFFFF" BorderThickness="1"/>
  <Border Padding="6,5,12,6">
    <StackPanel x:Name="oContent" Orientation="Horizontal" TextBlock.FontSize="12.5">
      <StackPanel x:Name="sCpu" Orientation="Horizontal" Margin="6,0,6,0"><TextBlock Text="CPU " Foreground="#99FFFFFF" FontWeight="SemiBold"/><TextBlock x:Name="oCpu" Text="--" Foreground="White" FontWeight="Bold" MinWidth="30"/></StackPanel>
      <StackPanel x:Name="sGpu" Orientation="Horizontal" Margin="6,0,6,0"><TextBlock Text="GPU " Foreground="#99FFFFFF" FontWeight="SemiBold"/><TextBlock x:Name="oGpu" Text="--" Foreground="#9FE1CB" FontWeight="Bold" MinWidth="30"/></StackPanel>
      <StackPanel x:Name="sRam" Orientation="Horizontal" Margin="6,0,6,0"><TextBlock Text="RAM " Foreground="#99FFFFFF" FontWeight="SemiBold"/><TextBlock x:Name="oRam" Text="--" Foreground="White" FontWeight="Bold" MinWidth="30"/></StackPanel>
      <TextBlock x:Name="sNet" Text="" Foreground="#CCFFFFFF" Margin="6,0,6,0" MinWidth="140"/>
      <TextBlock x:Name="sTopC" Text="" Foreground="#99FFFFFF" Margin="6,0,6,0" MaxWidth="160" TextTrimming="CharacterEllipsis"/>
      <TextBlock x:Name="sClock" Text="" Foreground="White" FontWeight="Light" Margin="6,0,0,0"/>
    </StackPanel>
  </Border>
  </Grid>
</Window>
"@
$osdKeys = @('Cpu', 'Gpu', 'Ram', 'Net', 'TopC', 'Clock')
$posNames = @('Top left', 'Top center', 'Top right', 'Bottom left', 'Bottom right')
$script:osds = @()
$g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $dpi = $g.DpiX / 96.0; $g.Dispose()

function Place-Osd($o) {
    $w = $o.Win; $a = $o.Screen.WorkingArea
    $L = $a.Left / $dpi; $T = $a.Top / $dpi; $R = $a.Right / $dpi; $B = $a.Bottom / $dpi
    $ww = $w.ActualWidth; $hh = $w.ActualHeight; $m = 10
    switch ([int]$cfg.OverlayPos) {
        0 { $x = $L + $m; $y = $T + $m }
        1 { $x = ($L + $R - $ww) / 2; $y = $T + $m }
        2 { $x = $R - $ww - $m; $y = $T + $m }
        3 { $x = $L + $m; $y = $B - $hh - $m }
        default { $x = $R - $ww - $m; $y = $B - $hh - $m }
    }
    if ([Math]::Abs($w.Left - $x) -gt 0.5) { $w.Left = $x }
    if ([Math]::Abs($w.Top - $y) -gt 0.5) { $w.Top = $y }
}
function Apply-OsdMetrics($o) {
    foreach ($k in $osdKeys) { $o.Seg[$k].Visibility = if ($cfg.Show.$k) { 'Visible' } else { 'Collapsed' } }
    Apply-OsdOpacity $o
}
function Build-Osds {
    foreach ($o in $script:osds) { try { $o.Win.Close() } catch {} }
    $script:osds = @()
    if (-not $cfg.Overlay) { return }
    $screens = if ($cfg.OverlayAll) { [System.Windows.Forms.Screen]::AllScreens } else { @([System.Windows.Forms.Screen]::PrimaryScreen) }
    foreach ($sc in $screens) {
        $w = [Windows.Markup.XamlReader]::Parse($osdXaml)
        $h = Win-Handle $w
        [LhNative]::MakeOverlay($h)
        $w.Left = $sc.WorkingArea.Left / $dpi; $w.Top = $sc.WorkingArea.Top / $dpi
        $seg = @{}; foreach ($k in $osdKeys) { $seg[$k] = $w.FindName("s$k") }
        $o = @{ Win = $w; H = $h; Screen = $sc; Seg = $seg; Bg = $w.FindName('oBg'); Body = $w.FindName('oContent'); Cpu = $w.FindName('oCpu'); Gpu = $w.FindName('oGpu'); Ram = $w.FindName('oRam') }
        Apply-OsdMetrics $o
        $w.Show(); $w.UpdateLayout()
        Place-Osd $o
        $script:osds += $o
    }
}

# =====================================================================
#  OPACITY + METRIC VISIBILITY
# =====================================================================
# Slider 0..100. Clear style: background really disappears, text stays crisp (with a shadow).
function Apply-OsdOpacity($o) {
    $t = [Math]::Max(0, [Math]::Min(1, [double]$cfg.OverlayOpacity / 100))
    $o.Win.Opacity = 1
    $o.Bg.Opacity = $t
    $o.Body.Effect = if ($t -lt 0.6) { $textShadow } else { $null }
}
function Apply-Opacity {
    if (-not $script:ui) { return }
    $t = [Math]::Max(0, [Math]::Min(1, [double]$cfg.WidgetOpacity / 100))   # 0 = fully clear, 1 = solid
    if (Use-Dwm) {
        # blur mode: Windows always keeps its own frosted tint
        $script:ui.Glass.Background = Brush ('#{0:X2}0C0E16' -f [int](0x08 + $t * 0xD0))
        $script:ui.Glass.Opacity = 1
        $script:ui.Sheen.Opacity = 0.3 + 0.7 * $t
        $script:ui.Content.Effect = $null
    } else {
        # clear mode: real transparency (min 1% so the widget can still be dragged)
        $script:ui.Glass.Background = Brush '#F00C0E16'
        $script:ui.Glass.Opacity = [Math]::Max(0.012, $t)
        $script:ui.Sheen.Opacity = $t
        $script:ui.Content.Effect = if ($t -lt 0.6) { $textShadow } else { $null }
    }
    $script:ui.Content.Opacity = 1
    foreach ($o in $script:osds) { Apply-OsdOpacity $o }
}
function Apply-Metrics {
    foreach ($k in $metrics.Keys) { $rows[$k].Visibility = if ($cfg.Show.$k) { 'Visible' } else { 'Collapsed' } }
    foreach ($o in $script:osds) { Apply-OsdMetrics $o; $o.Win.UpdateLayout(); Place-Osd $o }
    $sync.Want = Want-Table
}

# =====================================================================
#  SETTINGS WINDOW
# =====================================================================
$settingsXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LiquidHUD Settings" $(if ($modern) { 'Width="360" SizeToContent="Height" WindowStyle="None" ResizeMode="NoResize" Background="Transparent"' } else { 'Width="360" SizeToContent="Height" WindowStyle="None" AllowsTransparency="True" ResizeMode="NoResize" Background="Transparent"' })
        Topmost="True" WindowStartupLocation="CenterScreen" FontFamily="Segoe UI Variable Display, Segoe UI">
  $(if ($modern) { $chromeXaml } else { '' })
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
            <Border x:Name="Bd" CornerRadius="8" Padding="14,5" Margin="0,0,6,0" Background="#14FFFFFF" BorderBrush="#33FFFFFF" BorderThickness="1">
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
  <Border x:Name="sRoot" Background="$(if ($modern) { '#990C0E16' } else { '#F20C0E16' })" CornerRadius="$(if ($modern) { '0' } else { '16' })" BorderBrush="#33FFFFFF" BorderThickness="$(if ($modern) { '0' } else { '1' })" Padding="22,16,22,20">
    <StackPanel>
      <Grid>
        <TextBlock Text="Settings" Foreground="White" FontSize="18" FontWeight="Bold"/>
        <Border x:Name="sClose" HorizontalAlignment="Right" Width="28" Height="28" CornerRadius="14" Background="#1FFFFFFF" Cursor="Hand">
          <TextBlock Text="&#x2715;" Foreground="White" FontSize="12" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
      </Grid>

      <TextBlock Style="{StaticResource Head}" Text="Widget background   (left = clear, right = solid)"/>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
        <Slider x:Name="sWop" Minimum="0" Maximum="100" SmallChange="1" LargeChange="10" IsMoveToPointEnabled="True" VerticalAlignment="Center"/>
        <TextBlock x:Name="sWopVal" Grid.Column="1" Foreground="White" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>

      <TextBlock Style="{StaticResource Head}" Text="Game overlay background"/>
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="46"/></Grid.ColumnDefinitions>
        <Slider x:Name="sOop" Minimum="0" Maximum="100" SmallChange="1" LargeChange="10" IsMoveToPointEnabled="True" VerticalAlignment="Center"/>
        <TextBlock x:Name="sOopVal" Grid.Column="1" Foreground="White" FontWeight="Bold" HorizontalAlignment="Right" VerticalAlignment="Center"/>
      </Grid>

      <StackPanel x:Name="sStyleBox">
        <TextBlock Style="{StaticResource Head}" Text="Style"/>
        <StackPanel Orientation="Horizontal">
          <RadioButton x:Name="sSC" GroupName="st" Content="Clear"/>
          <RadioButton x:Name="sSA" GroupName="st" Content="Acrylic blur"/>
          <RadioButton x:Name="sSM" GroupName="st" Content="Mica"/>
        </StackPanel>
      </StackPanel>

      <TextBlock Style="{StaticResource Head}" Text="What to monitor"/>
      <WrapPanel x:Name="sChecks"/>

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
  </Border>
</Window>
"@
$script:sWin = $null
function Open-Settings {
    if ($script:sWin) { $script:sWin.Show(); $script:sWin.Activate() | Out-Null; return }
    $sw = [Windows.Markup.XamlReader]::Parse($settingsXaml)
    $script:sWin = $sw
    $script:sUi = @{}
    foreach ($n in 'sRoot','sClose','sWop','sWopVal','sOop','sOopVal','sChecks','sR1','sR2','sR5','sSelf','sStyleBox','sSC','sSA','sSM') { $script:sUi[$n] = $sw.FindName($n) }
    $s = $script:sUi

    $s.sWop.Value = [double]$cfg.WidgetOpacity;  $s.sWopVal.Text = "$([int]$cfg.WidgetOpacity)%"
    $s.sOop.Value = [double]$cfg.OverlayOpacity; $s.sOopVal.Text = "$([int]$cfg.OverlayOpacity)%"
    $s.sWop.Add_ValueChanged({ $cfg.WidgetOpacity = [int]$this.Value; $script:sUi.sWopVal.Text = "$($cfg.WidgetOpacity)%"; Apply-Opacity })
    $s.sOop.Add_ValueChanged({ $cfg.OverlayOpacity = [int]$this.Value; $script:sUi.sOopVal.Text = "$($cfg.OverlayOpacity)%"; Apply-Opacity })

    foreach ($k in $metrics.Keys) {
        $cb = New-Object Windows.Controls.CheckBox
        $cb.Content = $metrics[$k]; $cb.Tag = $k; $cb.IsChecked = [bool]$cfg.Show.$k
        $cb.Add_Click({ $cfg.Show.($this.Tag) = [bool]$this.IsChecked; Apply-Metrics; Save-Cfg })
        [void]$s.sChecks.Children.Add($cb)
    }

    switch ([int]$cfg.Interval) { 1 { $s.sR1.IsChecked = $true } 5 { $s.sR5.IsChecked = $true } default { $s.sR2.IsChecked = $true } }
    foreach ($p in @(@($s.sR1, 1), @($s.sR2, 2), @($s.sR5, 5))) {
        $p[0].Tag = $p[1]
        $p[0].Add_Checked({ $cfg.Interval = [int]$this.Tag; $sync.Interval = $cfg.Interval; $timer.Interval = [TimeSpan]::FromSeconds($cfg.Interval); Save-Cfg })
    }

    if (-not $modern) { $s.sStyleBox.Visibility = 'Collapsed' }
    switch ($cfg.Style) { 'Acrylic' { $s.sSA.IsChecked = $true } 'Mica' { $s.sSM.IsChecked = $true } default { $s.sSC.IsChecked = $true } }
    foreach ($p in @(@($s.sSC, 'Clear'), @($s.sSA, 'Acrylic'), @($s.sSM, 'Mica'))) {
        $p[0].Tag = $p[1]
        $p[0].Add_Checked({ Set-Style $this.Tag })
    }

    $s.sClose.Add_MouseLeftButtonUp({ $script:sWin.Hide(); Save-Cfg })
    $s.sRoot.Add_MouseLeftButtonDown({ param($a, $e); if ($e.OriginalSource -eq $script:sUi.sRoot) { try { $script:sWin.DragMove() } catch {} } })
    $sw.Add_Closing({ param($a, $e); $e.Cancel = $true; $script:sWin.Hide(); Save-Cfg })
    $sw.Add_SourceInitialized({ Apply-Glass $script:sWin 3 })
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
  <MenuItem x:Name="mAll"      Header="Overlay on all monitors"/>
  <MenuItem x:Name="mHide"     Header="Hide widget" InputGestureText="Ctrl+Alt+H"/>
  <MenuItem x:Name="mGlass"    Header="Style: Clear"/>
  <MenuItem x:Name="mTop"      Header="Widget always on top"/>
  <MenuItem x:Name="mStartup"  Header="Start with Windows"/>
  <MenuItem x:Name="mTask"     Header="Task Manager"/>
  <MenuItem x:Name="mExit"     Header="Exit"/>
</ContextMenu>
"@
$script:menu = [Windows.Markup.XamlReader]::Parse($menuXaml)
$menu = $script:menu
$mi = @{}
foreach ($n in 'mSettings','mOverlay','mPos','mAll','mHide','mGlass','mTop','mStartup','mTask','mExit') { $mi[$n] = $menu.FindName($n) }
$startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'LiquidHUD.lnk'

function Refresh-Menu {
    $mi.mOverlay.IsChecked = [bool]$cfg.Overlay
    $mi.mAll.IsChecked = [bool]$cfg.OverlayAll
    $mi.mPos.Header = 'Overlay position: ' + $posNames[[int]$cfg.OverlayPos]
    $mi.mTop.IsChecked = [bool]$cfg.Topmost
    $mi.mStartup.IsChecked = Test-Path $startupLnk
    $mi.mGlass.Header = 'Style: ' + $cfg.Style
    $mi.mGlass.Visibility = if ($modern) { 'Visible' } else { 'Collapsed' }
}
function Toggle-Overlay { $cfg.Overlay = -not $cfg.Overlay; Save-Cfg; Build-Osds; Refresh-Menu }
function Cycle-Pos { $cfg.OverlayPos = ([int]$cfg.OverlayPos + 1) % 5; Save-Cfg; foreach ($o in $script:osds) { Place-Osd $o }; Refresh-Menu }
function Toggle-Widget {
    $cfg.WidgetHidden = -not $cfg.WidgetHidden; Save-Cfg
    if ($cfg.WidgetHidden) { $win.Hide() } else { $win.Show(); if (Use-Dwm) { Apply-Glass $win (Backdrop-Id) } }
    $sync.Want = Want-Table
}
function Quit-All {
    $timer.Stop(); $sync.Stop = $true
    $cfg.Left = $win.Left; $cfg.Top = $win.Top; Save-Cfg
    foreach ($o in $script:osds) { try { $o.Win.Close() } catch {} }
    try { $hk.Dispose() } catch {}
    try { $mutex.ReleaseMutex() } catch {}
    [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown()
}

$mi.mSettings.Add_Click({ Open-Settings })
$mi.mOverlay.Add_Click({ Toggle-Overlay })
$mi.mPos.Add_Click({ Cycle-Pos })
$mi.mAll.Add_Click({ $cfg.OverlayAll = -not $cfg.OverlayAll; Save-Cfg; Build-Osds; Refresh-Menu })
$mi.mHide.Add_Click({ Toggle-Widget })
$mi.mGlass.Add_Click({
    $next = @{ 'Clear' = 'Acrylic'; 'Acrylic' = 'Mica'; 'Mica' = 'Clear' }[$cfg.Style]
    Set-Style $next
})
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
function Set-Style($st) {
    if ($cfg.Style -eq $st) { return }
    $cfg.Style = $st; Save-Cfg
    Build-Widget
    Refresh-Menu
    if ($script:sWin -and $script:sUi) {
        $script:sUi.sSC.IsChecked = ($st -eq 'Clear'); $script:sUi.sSA.IsChecked = ($st -eq 'Acrylic'); $script:sUi.sSM.IsChecked = ($st -eq 'Mica')
    }
}

# ---------- global hotkeys ----------
$hk = New-Object LhHotkeys
$MOD = 0x0002 -bor 0x0001 -bor 0x4000    # Ctrl + Alt + NoRepeat
[void]$hk.Register(1, $MOD, 0x4F)   # O
[void]$hk.Register(2, $MOD, 0x50)   # P
[void]$hk.Register(3, $MOD, 0x48)   # H
[void]$hk.Register(4, $MOD, 0x53)   # S
$hk.Add_Pressed({
    param($id)
    switch ($id) { 1 { Toggle-Overlay } 2 { Cycle-Pos } 3 { Toggle-Widget } 4 { Open-Settings } }
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
function Draw-Line($line, $hist) {
    $pc = New-Object Windows.Media.PointCollection($hist.Count)
    $n = $hist.Count; $step = 260.0 / 59
    for ($i = 0; $i -lt $n; $i++) {
        $pc.Add((New-Object Windows.Point(((60 - $n + $i) * $step), (48 - ([Math]::Min(100, $hist[$i]) * 0.44)))))
    }
    $pc.Freeze(); $line.Points = $pc
}
$ease = New-Object Windows.Media.Animation.CubicEase; $ease.EasingMode = 'EaseOut'; $ease.Freeze()
$barLast = @{}
function Set-Bar($bar, [double]$pct) {
    $wd = [Math]::Round([Math]::Max(0, [Math]::Min(100, $pct)) * 2.6)
    if ($barLast[$bar.Name] -eq $wd) { return }        # no change = no animation = cheaper
    $barLast[$bar.Name] = $wd
    $a = New-Object Windows.Media.Animation.DoubleAnimation($wd, [TimeSpan]::FromMilliseconds(600))
    $a.EasingFunction = $ease
    $a.Freeze()
    $bar.BeginAnimation([Windows.FrameworkElement]::WidthProperty, $a)
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
    $clock = [DateTime]::Now.ToString('HH:mm')
    $gpu = [Math]::Max(0, $d.Gpu)
    $gpuTxt = if ($d.Gpu -ge 0) { '{0:N0}%' -f $gpu } else { 'n/a' }
    $ramPct = if ($d.RamTot) { $d.RamUsed / $d.RamTot * 100 } else { 0 }
    $cpuTxt = '{0:N0}%' -f $d.Cpu
    $ramTxt = '{0:N0}%' -f $ramPct
    $netTxt = if ($S.Net) { '{0} {1}/s  {2} {3}/s' -f $arrowDown, (Fmt-Bytes $d.Down), $arrowUp, (Fmt-Bytes $d.Up) } else { '' }

    foreach ($o in $script:osds) {
        Set-Text $o.Cpu $cpuTxt; $o.Cpu.Foreground = if ($d.Cpu -gt 85) { $hot } else { $white }
        Set-Text $o.Gpu $gpuTxt
        Set-Text $o.Ram $ramTxt; $o.Ram.Foreground = if ($ramPct -gt 85) { $hot } else { $white }
        Set-Text $o.Seg.Net $netTxt
        Set-Text $o.Seg.TopC $(if ($d.TopC) { $d.TopC } else { '' })
        Set-Text $o.Seg.Clock $clock
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
        if ($S.Disk -and $d.DiskTot) {
            $dp = $d.DiskUsed / $d.DiskTot * 100
            Set-Text $ui.DiskVal ('{0:N0}%' -f $dp)
            Set-Text $ui.DiskSub ('{0:N0} / {1:N0} GB' -f ($d.DiskUsed / 1GB), ($d.DiskTot / 1GB))
            Set-Bar $ui.DiskBar $dp
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
        Set-Text $script:sUi.sSelf ('{0:N0} MB RAM   |   {1:N1}% CPU' -f ($d.SelfPriv / 1MB), [Math]::Max(0, $d.SelfCpu))
    }
  } catch {}
})

# ---------- start ----------
if ($cfg.WidgetHidden -and -not $cfg.Overlay) { $cfg.WidgetHidden = $false }
Build-Widget
Build-Osds
Apply-Metrics
Apply-Opacity
$timer.Start()
[Windows.Threading.Dispatcher]::Run()
try { [void]$bg.EndInvoke($bgHandle) } catch {}
$bg.Dispose(); $rs.Close()
