param(
    [string]$Launch = '',
    [string]$Install = ''
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

Add-Type -TypeDefinition @"
using System;
using System.Text;
using System.Threading.Tasks;
using System.Runtime.InteropServices;
public class WinoidActivate {
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
}
public class WinoidDrive {
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "DefineDosDeviceW")]
    public static extern bool DefineDosDevice(uint flags, string name, string target);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "QueryDosDeviceW")]
    public static extern uint QueryDosDevice(string name, StringBuilder target, uint max);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    public static extern void SHChangeNotify(int eventId, uint flags, string item1, string item2);
}
"@

$script:baseDir = $PSScriptRoot
$script:requestDir = Join-Path $env:LOCALAPPDATA 'Winoid\queue'
$script:instanceMutex = New-Object System.Threading.Mutex($false, 'Local\WinoidManager')
if (-not $script:instanceMutex.WaitOne(0)) {
    $queued = $false
    if ($Launch -or $Install) {
        try {
            if (-not (Test-Path -LiteralPath $script:requestDir)) {
                New-Item -ItemType Directory -Path $script:requestDir -Force | Out-Null
            }
            $action = 'launch'
            $target = $Launch
            if (-not $Launch) { $action = 'install'; $target = $Install }
            $req = [ordered]@{
                action  = $action
                target  = $target
                created = (Get-Date).ToString('o')
            } | ConvertTo-Json -Compress
            $name = 'req-{0}-{1}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'), ([Guid]::NewGuid().ToString('N').Substring(0, 8))
            $tmp = Join-Path $script:requestDir ($name + '.tmp')
            [System.IO.File]::WriteAllText($tmp, $req, (New-Object System.Text.UTF8Encoding($false)))
            Move-Item -LiteralPath $tmp -Destination (Join-Path $script:requestDir $name) -ErrorAction Stop
            $queued = $true
        } catch { }
    }
    $existing = [WinoidActivate]::FindWindow($null, 'Winoid')
    if ($existing -ne [IntPtr]::Zero) {
        [void][WinoidActivate]::ShowWindow($existing, 9)
        [void][WinoidActivate]::SetForegroundWindow($existing)
    } elseif (-not $queued) {
        [System.Windows.MessageBox]::Show('Winoid уже запущен.', 'Winoid') | Out-Null
    }
    exit
}

Add-Type -TypeDefinition @"
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading.Tasks;

public class NativeWin {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lp);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsZoomed(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
    [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool repaint);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int idx, int val);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr wp, IntPtr lp);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vkey);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // Windows 10/11 pick a dark caption from this attribute; the old 19 is
    // kept for pre-2004 builds where 20 is ignored.
    public static void UseDarkTitleBar(IntPtr h) {
        if (h == IntPtr.Zero) return;
        int on = 1;
        DwmSetWindowAttribute(h, 20, ref on, 4);
        DwmSetWindowAttribute(h, 19, ref on, 4);
    }
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFO bi, uint usage, out IntPtr bits, IntPtr section, uint offset);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr obj);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr obj);
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr h, IntPtr hdc);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER {
        public int biSize; public int biWidth; public int biHeight;
        public short biPlanes; public short biBitCount; public int biCompression;
        public int biSizeImage; public int biXPelsPerMeter; public int biYPelsPerMeter;
        public int biClrUsed; public int biClrImportant;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFO { public BITMAPINFOHEADER bmiHeader; }
    public delegate bool EnumProc(IntPtr h, IntPtr lp);

    public class WinInfo {
        public IntPtr Hwnd;
        public IntPtr RootOwner;
        public string Title;
        public int Left, Top, Right, Bottom;
        public bool Visible;
        public int Width { get { return Right - Left; } }
        public int Height { get { return Bottom - Top; } }
    }

    public static WinInfo[] ListWindows(uint pid) {
        var list = new List<WinInfo>();
        EnumWindows((h, lp) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p != pid) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            if (sb.Length == 0) return true;
            RECT r; GetWindowRect(h, out r);
            list.Add(new WinInfo {
                Hwnd = h, RootOwner = GetAncestor(h, 3), Title = sb.ToString(), Visible = IsWindowVisible(h),
                Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom
            });
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }

    public static IntPtr FindWindowContains(string needle, string exclude) {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, lp) => {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            var t = sb.ToString();
            if (t.Length == 0) return true;
            if (!String.IsNullOrEmpty(exclude) && t.IndexOf(exclude, StringComparison.OrdinalIgnoreCase) >= 0) return true;
            if (t.IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    public static void ForceForeground(IntPtr h) {
        IntPtr fg = GetForegroundWindow();
        uint fgPid; uint fgThread = GetWindowThreadProcessId(fg, out fgPid);
        uint myThread = GetCurrentThreadId();
        if (fgThread != 0 && fgThread != myThread) {
            AttachThreadInput(myThread, fgThread, true);
            SetForegroundWindow(h);
            AttachThreadInput(myThread, fgThread, false);
        } else {
            SetForegroundWindow(h);
        }
    }

    public static bool LeftButtonDown() {
        return (GetAsyncKeyState(0x01) & 0x8000) != 0;
    }
}

public class FrameGrabber : IDisposable {
    public readonly int W, H, Stride, ByteSize;
    IntPtr _memDc, _dib, _old, _screenDc, _bits;
    public long LastMs;
    Task<bool> _capture;
    IntPtr _captureHwnd;

    public FrameGrabber(int w, int h) {
        W = w; H = h; Stride = w * 4; ByteSize = Stride * h;
        _screenDc = NativeWin.GetDC(IntPtr.Zero);
        _memDc = NativeWin.CreateCompatibleDC(_screenDc);
        var bi = new NativeWin.BITMAPINFO();
        bi.bmiHeader.biSize = Marshal.SizeOf(typeof(NativeWin.BITMAPINFOHEADER));
        bi.bmiHeader.biWidth = w;
        bi.bmiHeader.biHeight = -h;
        bi.bmiHeader.biPlanes = 1;
        bi.bmiHeader.biBitCount = 32;
        bi.bmiHeader.biCompression = 0;
        _dib = NativeWin.CreateDIBSection(_screenDc, ref bi, 0, out _bits, IntPtr.Zero, 0);
        _old = NativeWin.SelectObject(_memDc, _dib);
    }

    public IntPtr Bits { get { return _bits; } }

    public bool Capture(IntPtr hwnd) {
        var sw = Stopwatch.StartNew();
        bool ok = NativeWin.PrintWindow(hwnd, _memDc, 2);
        LastMs = sw.ElapsedMilliseconds;
        return ok;
    }

    // PrintWindow can take tens of milliseconds. Start it on a thread-pool
    // thread so the WPF dispatcher is never blocked by the capture itself.
    public bool CaptureBegin(IntPtr hwnd) {
        if (_capture != null && !_capture.IsCompleted) return false;
        _captureHwnd = hwnd;
        var dc = _memDc;
        _capture = Task.Run(() => {
            var sw = Stopwatch.StartNew();
            bool ok = NativeWin.PrintWindow(_captureHwnd, dc, 2);
            LastMs = sw.ElapsedMilliseconds;
            return ok;
        });
        return true;
    }

    public bool CaptureComplete() {
        if (_capture == null || !_capture.IsCompleted) return false;
        bool ok;
        try { ok = _capture.Result; } catch { ok = false; }
        _capture = null;
        return ok;
    }

    public double MeanLuma() {
        long sum = 0; int n = 0;
        int count = W * H;
        for (int i = 0; i < count; i += 53) {
            int off = i * 4;
            sum += Marshal.ReadByte(_bits, off) + Marshal.ReadByte(_bits, off + 1) + Marshal.ReadByte(_bits, off + 2);
            n++;
        }
        return n == 0 ? 0 : sum / (double)n / 3.0;
    }

    // WSLg sometimes centers its translucent shadow around the app surface
    // and sometimes leaves it all on the right/bottom. Find where a
    // cw x ch content rectangle sits inside this W x H window by picking
    // the window position with the brightest margins (the shadow is black).
    public bool FindContentOffset(int cw, int ch, out int ox, out int oy) {
        ox = 0; oy = 0;
        if (cw <= 0 || ch <= 0 || cw > W || ch > H) return false;
        if (cw == W && ch == H) return true;
        double[] col = new double[W];
        double[] row = new double[H];
        for (int x = 0; x < W; x++) {
            long s = 0; int n = 0;
            for (int y = 0; y < H; y += 5) {
                int off = y * Stride + x * 4;
                s += Marshal.ReadByte(_bits, off) + Marshal.ReadByte(_bits, off + 1) + Marshal.ReadByte(_bits, off + 2);
                n++;
            }
            col[x] = n > 0 ? (double)s / n : 0;
        }
        for (int y = 0; y < H; y++) {
            long s = 0; int n = 0;
            for (int x = 0; x < W; x += 5) {
                int off = y * Stride + x * 4;
                s += Marshal.ReadByte(_bits, off) + Marshal.ReadByte(_bits, off + 1) + Marshal.ReadByte(_bits, off + 2);
                n++;
            }
            row[y] = n > 0 ? (double)s / n : 0;
        }
        double best = -1;
        for (int x0 = 0; x0 <= W - cw; x0++) {
            double s = 0;
            for (int x = x0; x < x0 + cw; x++) s += col[x];
            if (s > best) { best = s; ox = x0; }
        }
        best = -1;
        for (int y0 = 0; y0 <= H - ch; y0++) {
            double s = 0;
            for (int y = y0; y < y0 + ch; y++) s += row[y];
            if (s > best) { best = s; oy = y0; }
        }
        return true;
    }

    public void Dispose() {
        if (_capture != null) { try { _capture.Wait(500); } catch { } }
        try { NativeWin.SelectObject(_memDc, _old); } catch { }
        try { NativeWin.DeleteObject(_dib); } catch { }
        try { NativeWin.DeleteDC(_memDc); } catch { }
        try { NativeWin.ReleaseDC(IntPtr.Zero, _screenDc); } catch { }
    }
}

public class AdbShell : IDisposable {
    Process _p;
    BlockingCollection<string> _lines = new BlockingCollection<string>();

    public AdbShell(string adb, string serial) : this(adb, serial, new string[0]) { }

    public AdbShell(string adb, string serial, string[] prefixArgs) {
        var psi = new ProcessStartInfo(adb);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        foreach (var a in prefixArgs) { psi.ArgumentList.Add(a); }
        psi.ArgumentList.Add("-s");
        psi.ArgumentList.Add(serial);
        psi.ArgumentList.Add("shell");
        _p = Process.Start(psi);
        _p.OutputDataReceived += (s, e) => { if (e.Data != null) { try { _lines.Add(e.Data); } catch { } } };
        _p.ErrorDataReceived += (s, e) => { if (e.Data != null) { try { _lines.Add(e.Data); } catch { } } };
        _p.BeginOutputReadLine();
        _p.BeginErrorReadLine();
    }

    public bool Running { get { return _p != null && !_p.HasExited; } }

    public void Send(string cmd) {
        if (!Running) throw new InvalidOperationException("adb shell is not running");
        _p.StandardInput.Write(cmd + "\n");
        _p.StandardInput.Flush();
    }

    public long SendSync(string cmd, int timeoutMs) {
        string marker = "M" + Guid.NewGuid().ToString("N");
        var sw = Stopwatch.StartNew();
        _p.StandardInput.Write(cmd + "; echo " + marker + "\n");
        _p.StandardInput.Flush();
        string line;
        while (sw.ElapsedMilliseconds < timeoutMs) {
            if (_lines.TryTake(out line, 25)) {
                if (line == marker) break;
            }
        }
        sw.Stop();
        return sw.ElapsedMilliseconds;
    }

    // Runs a command on the persistent shell and returns its output. Used
    // sparingly (Settings Back) so the UI does not launch a slow wsl.exe.
    public string SendQuery(string cmd, int timeoutMs) {
        if (!Running) throw new InvalidOperationException("adb shell is not running");
        string marker = "Q" + Guid.NewGuid().ToString("N");
        StringBuilder sb = new StringBuilder();
        _p.StandardInput.Write(cmd + "; echo " + marker + "\n");
        _p.StandardInput.Flush();
        var sw = Stopwatch.StartNew();
        string line;
        while (sw.ElapsedMilliseconds < timeoutMs) {
            if (_lines.TryTake(out line, 25)) {
                if (line == marker) break;
                sb.AppendLine(line);
            }
        }
        return sb.ToString();
    }

    public void Dispose() {
        try { _p.StandardInput.WriteLine("exit"); _p.StandardInput.Flush(); } catch { }
        try { if (!_p.WaitForExit(400)) _p.Kill(); } catch { }
    }
}
"@

$script:wsl = "$env:SystemRoot\System32\wsl.exe"
$script:sessionRunning = $false
$script:apps = @()
$script:launchState = $null
$script:pendingAndroidWindow = $null
$script:installJob = $null
$script:installTicks = 0
$script:sessionJob = $null
$script:sessionTicks = 0
$script:sessionWaiting = $false
$script:wslKeepAlive = $null
$script:msrdcId = 0
$script:exiting = $false
$script:pendingLaunch = ''
$script:pendingLaunchUntil = [DateTime]::MinValue
$script:pendingAppsAt = [DateTime]::MinValue
$script:pendingLaunchTries = 0
$script:lastErrorAt = [DateTime]::MinValue
$script:lastErrorText = ''
$script:frameErrorAt = [DateTime]::MinValue

$script:wrappers = New-Object System.Collections.ArrayList
$script:wrapByImage = @{}
$script:wrapByWindow = @{}
$script:bounceWrap = $null
$script:adb = $null
$script:adbPath = $null
$script:adbViaWsl = $false
$script:adbNextTry = [DateTime]::MinValue
$script:adbSerial = '192.168.240.112:5555'
$script:adbCheckedAt = [DateTime]::MinValue
$script:wslDistro = ''
$script:wslHome = ''
$script:wslUser = ''
$script:androidDrive = ''
$script:androidDriveTarget = ''
$script:androidDriveMode = ''
$script:androidDriveAclDone = $false
$script:staleDrivesCleared = $false
$script:armCompat = $false
$script:armCompatApplied = $null
$script:armCompatDirty = $false
$script:armCompatNextTry = [DateTime]::MinValue
$script:armCompatRestarted = @{}
# '' = unknown, 'libndk' or 'libhoudini'. Saved by Setup-Backend, and read
# from waydroid.cfg when the manager starts on an older install.
$script:armTranslator = ''

# One-time migration from the old Winndroid data directory.
function Initialize-WinoidData {
    $newRoot = Join-Path $env:LOCALAPPDATA 'Winoid'
    $oldRoot = Join-Path $env:LOCALAPPDATA 'Winndroid'
    $moved = $false
    if ((Test-Path -LiteralPath $oldRoot) -and -not (Test-Path -LiteralPath $newRoot)) {
        try {
            Move-Item -LiteralPath $oldRoot -Destination $newRoot -ErrorAction Stop
            $moved = $true
        } catch { }
    }
    if ($moved) {
        try {
            $wslConfig = Join-Path $env:USERPROFILE '.wslconfig'
            if (Test-Path -LiteralPath $wslConfig) {
                $changed = $false
                $out = foreach ($line in @(Get-Content -LiteralPath $wslConfig)) {
                    if ($line -match '^\s*kernel=' -and $line -match '[\\/]Winndroid[\\/]') {
                        $changed = $true
                        $line.Replace('\\Winndroid\\', '\\Winoid\\').Replace('\Winndroid\', '\Winoid\')
                    } else { $line }
                }
                if ($changed) {
                    Copy-Item -LiteralPath $wslConfig -Destination ("$wslConfig.winoid-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.bak') -Force
                    Set-Content -LiteralPath $wslConfig -Value ($out -join "`r`n") -Encoding utf8NoBOM
                }
            }
        } catch {
            try {
                if (-not (Test-Path -LiteralPath $oldRoot) -and (Test-Path -LiteralPath $newRoot)) {
                    Move-Item -LiteralPath $newRoot -Destination $oldRoot -ErrorAction Stop
                }
            } catch { }
            return $oldRoot
        }
    }
    if (-not (Test-Path -LiteralPath $newRoot)) {
        # If the old folder is still there, migration failed (for example a
        # file is locked). Keep using it instead of starting from an empty
        # folder and hiding the user's settings.
        if (Test-Path -LiteralPath $oldRoot) { return $oldRoot }
        try { New-Item -ItemType Directory -Path $newRoot -Force -ErrorAction Stop | Out-Null } catch { }
    }
    if (Test-Path -LiteralPath $newRoot) { return $newRoot }
    return $oldRoot
}

# Optional config: %LOCALAPPDATA%\Winoid\config.json
# { "wslDistro": "Winoid", "adbSerial": "192.168.240.112:5555" }
$script:dataRoot = Initialize-WinoidData
$script:appVersion = '0.1.30'
$script:iconQueue = New-Object System.Collections.Queue
$script:geometryPath = Join-Path $script:dataRoot 'geometry.json'
$script:appGeometry = @{}
$script:hideCaption = $false
$script:captionHeightPx = 48
$script:fallbackNavInset = 48
$script:edgeCropPx = 3
$script:stretchFill = $false
$script:language = 'ru'
$script:origText = @{}
$script:adbTimeoutMs = 10000
$script:sessionTimeoutMs = 15000
$script:configDir = $script:dataRoot
$script:configPath = Join-Path $script:configDir 'config.json'
if (Test-Path -LiteralPath $script:configPath) {
    try {
        $cfg = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json
        if ($cfg.wslDistro) { $script:wslDistro = [string]$cfg.wslDistro }
        if ($cfg.adbSerial) { $script:adbSerial = [string]$cfg.adbSerial }
        if ($cfg.adbTimeoutMs) { $script:adbTimeoutMs = [int]$cfg.adbTimeoutMs }
        if ($cfg.sessionTimeoutMs) { $script:sessionTimeoutMs = [int]$cfg.sessionTimeoutMs }
        if ($null -ne $cfg -and ($cfg.PSObject.Properties.Name -contains 'hideCaption')) { $script:hideCaption = [bool]$cfg.hideCaption }
        if ($cfg.captionHeightPx) { $script:captionHeightPx = [int]$cfg.captionHeightPx }
        if ($null -ne $cfg -and ($cfg.PSObject.Properties.Name -contains 'fallbackNavInset')) { $script:fallbackNavInset = [int]$cfg.fallbackNavInset }
        if ($null -ne $cfg -and ($cfg.PSObject.Properties.Name -contains 'stretchFill')) { $script:stretchFill = [bool]$cfg.stretchFill }
        if ($cfg.language) { $script:language = [string]$cfg.language }
        if ($cfg.armTranslator) { $script:armTranslator = [string]$cfg.armTranslator }
        if ($null -ne $cfg -and ($cfg.PSObject.Properties.Name -contains 'armCompat')) {
            $script:armCompat = [bool]$cfg.armCompat
        }
    } catch { }
}
if ($env:WINOID_WSL_DISTRO) { $script:wslDistro = $env:WINOID_WSL_DISTRO }
if ($env:WINOID_ADB_SERIAL) { $script:adbSerial = $env:WINOID_ADB_SERIAL }

# Android profiles: named sets of WSL distro / adb serial.
$script:profilesPath = Join-Path $script:dataRoot 'profiles.json'
$script:profiles = @{}
$script:activeProfile = 'default'
if (Test-Path -LiteralPath $script:profilesPath) {
    try {
        $pf = Get-Content -LiteralPath $script:profilesPath -Raw -Encoding utf8 | ConvertFrom-Json
        if ($pf.active) { $script:activeProfile = [string]$pf.active }
        if ($null -ne $pf.profiles) {
            foreach ($prop in $pf.profiles.PSObject.Properties) { $script:profiles[[string]$prop.Name] = $prop.Value }
        }
    } catch { }
}
if (-not $script:profiles.ContainsKey($script:activeProfile)) { $script:profiles[$script:activeProfile] = [pscustomobject]@{ wslDistro = $script:wslDistro; adbSerial = $script:adbSerial } }
function Save-Profiles {
    try {
        $map = [pscustomobject]@{}
        foreach ($k in @($script:profiles.Keys)) {
            $v = $script:profiles[$k]
            $map | Add-Member -NotePropertyName ([string]$k) -NotePropertyValue ([pscustomobject]@{ wslDistro = [string]$v.wslDistro; adbSerial = [string]$v.adbSerial }) -Force
        }
        ([pscustomobject]@{ active = $script:activeProfile; profiles = $map }) |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:profilesPath -Encoding utf8NoBOM
    } catch { Write-WinoidLog ("ERROR save profiles: " + $_.Exception.ToString()) }
}
if (-not $env:WINOID_WSL_DISTRO -and $script:profiles[$script:activeProfile].wslDistro) {
    $script:wslDistro = [string]$script:profiles[$script:activeProfile].wslDistro
}
if (-not $env:WINOID_ADB_SERIAL -and $script:profiles[$script:activeProfile].adbSerial) {
    $script:adbSerial = [string]$script:profiles[$script:activeProfile].adbSerial
}

# Keep the user's existing config keys; only add or update ARM settings.
# The translator is remembered too, so the manager does not have to inspect
# waydroid.cfg on every start.
function Save-ArmCompatSetting {
    try {
        $cfg = $null
        if (Test-Path -LiteralPath $script:configPath) {
            try { $cfg = Get-Content -LiteralPath $script:configPath -Raw | ConvertFrom-Json } catch { }
        }
        if ($null -eq $cfg) { $cfg = [pscustomobject]@{} }
        if ($cfg.PSObject.Properties.Name -contains 'armCompat') {
            $cfg.armCompat = [bool]$script:armCompat
        } else {
            $cfg | Add-Member -NotePropertyName armCompat -NotePropertyValue ([bool]$script:armCompat)
        }
        if ($script:armTranslator) {
            if ($cfg.PSObject.Properties.Name -contains 'armTranslator') {
                $cfg.armTranslator = [string]$script:armTranslator
            } else {
                $cfg | Add-Member -NotePropertyName armTranslator -NotePropertyValue ([string]$script:armTranslator)
            }
        }
        if ($cfg.PSObject.Properties.Name -contains 'hideCaption') {
            $cfg.hideCaption = [bool]$script:hideCaption
        } else {
            $cfg | Add-Member -NotePropertyName hideCaption -NotePropertyValue ([bool]$script:hideCaption)
        }
        if ($cfg.PSObject.Properties.Name -contains 'captionHeightPx') {
            $cfg.captionHeightPx = [int]$script:captionHeightPx
        } else {
            $cfg | Add-Member -NotePropertyName captionHeightPx -NotePropertyValue ([int]$script:captionHeightPx)
        }
        if ($cfg.PSObject.Properties.Name -contains 'fallbackNavInset') {
            $cfg.fallbackNavInset = [int]$script:fallbackNavInset
        } else {
            $cfg | Add-Member -NotePropertyName fallbackNavInset -NotePropertyValue ([int]$script:fallbackNavInset)
        }
        if ($cfg.PSObject.Properties.Name -contains 'stretchFill') {
            $cfg.stretchFill = [bool]$script:stretchFill
        } else {
            $cfg | Add-Member -NotePropertyName stretchFill -NotePropertyValue ([bool]$script:stretchFill)
        }
        if ($cfg.PSObject.Properties.Name -contains 'language') {
            $cfg.language = [string]$script:language
        } else {
            $cfg | Add-Member -NotePropertyName language -NotePropertyValue ([string]$script:language)
        }
        $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $script:configPath -Encoding utf8NoBOM
    } catch {
        Write-WinoidLog ("ERROR save config: " + $_.Exception.ToString())
    }
}

if (Test-Path -LiteralPath $script:geometryPath) {
    try {
        $g = Get-Content -LiteralPath $script:geometryPath -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($prop in $g.PSObject.Properties) { $script:appGeometry[[string]$prop.Name] = $prop.Value }
    } catch { }
}

function Save-AppGeometry {
    try {
        $map = [pscustomobject]@{}
        foreach ($key in @($script:appGeometry.Keys)) {
            $v = $script:appGeometry[$key]
            $map | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue ([pscustomobject]@{ W = [int]$v.W; H = [int]$v.H }) -Force
        }
        $map | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:geometryPath -Encoding utf8NoBOM
    } catch { Write-WinoidLog ("ERROR save geometry: " + $_.Exception.ToString()) }
}

function Read-JsonFile([string]$path) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { return (Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json) } catch { return $null }
}

# Per-application display mode (phone / tablet) remembered between launches.
$script:modesPath = Join-Path $script:dataRoot 'modes.json'
$script:appModes = @{}
$script:rememberMode = $false
if (Test-Path -LiteralPath $script:modesPath) {
    try {
        $mc = Get-Content -LiteralPath $script:modesPath -Raw -Encoding utf8 | ConvertFrom-Json
        $script:rememberMode = [bool]$mc.remember
        if ($null -ne $mc.modes) {
            foreach ($prop in $mc.modes.PSObject.Properties) { $script:appModes[[string]$prop.Name] = [int]$prop.Value }
        }
    } catch { }
}

function Save-AppModes {
    try {
        $map = [pscustomobject]@{}
        foreach ($key in @($script:appModes.Keys)) {
            $map | Add-Member -NotePropertyName ([string]$key) -NotePropertyValue ([int]$script:appModes[$key]) -Force
        }
        ([pscustomobject]@{ remember = [bool]$script:rememberMode; modes = $map }) |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:modesPath -Encoding utf8NoBOM
    } catch { Write-WinoidLog ("ERROR save modes: " + $_.Exception.ToString()) }
}

# Static UI translation. Dynamic status strings stay in the language of the
# caller; this covers window controls, buttons and labels.
$script:translations = @{
    'Winoid' = 'Winoid'
    'Android-приложения в отдельных окнах Windows' = 'Android apps in separate Windows'
    'Проверка…' = 'Checking…'
    'Обновить' = 'Refresh'
    'Запустить в отдельном окне' = 'Launch in separate window'
    'Ярлык на рабочем столе' = 'Desktop shortcut'
    'Открыть диск Android' = 'Open Android drive'
    'Мой компьютер' = 'My Computer'
    'Удалить приложение (APK)' = 'Remove app (APK)'
    'Удалить APK-файл…' = 'Delete APK file…'
    'Диагностика и лог' = 'Diagnostics and log'
    'Проверить обновления' = 'Check for updates'
    'Экспорт настроек' = 'Export settings'
    'Импорт настроек' = 'Import settings'
    'Перезапустить Android' = 'Restart Android'
    'Настройки Android' = 'Android settings'
    'Установить APK…' = 'Install APK…'
    'Настроить Android' = 'Set up Android'
    'Размер нового окна' = 'New window size'
    'Как есть (на весь экран)' = 'As is (full screen)'
    '1280 × 800' = '1280 × 800'
    '1600 × 900' = '1600 × 900'
    '1920 × 1080' = '1920 × 1080'
    'Телефон — вертикально (720 × 1280)' = 'Phone — portrait (720 × 1280)'
    'Планшет — горизонтально (1280 × 800)' = 'Tablet — landscape (1280 × 800)'
    'Скрывать индикатор после появления окна' = 'Hide loader when window appears'
    'Запоминать режим для каждого приложения' = 'Remember mode per app'
    'Обрезать заголовок Android (обычно не нужно)' = 'Crop Android caption (usually off)'
    'Обрезать нижнюю полосу Android' = 'Crop Android bottom strip'
    'Растягивать картинку по окну (без полей)' = 'Stretch image to window (no bars)'
    'Режим совместимости ARM' = 'ARM compatibility mode'
    'Помогает играм, которые зависают в ARM-трансляторе libndk. Медленнее, но надёжнее.' = 'Helps games that hang in the libndk ARM translator. Slower but safer.'
    'Android-навигация' = 'Android navigation'
    'Игра' = 'Game'
    'Телефон' = 'Phone'
    'Планшет' = 'Tablet'
    '◀  Назад' = '◀  Back'
    '●  Домой' = '●  Home'
    '■  Недавние' = '■  Recents'
    'Нажмите на окно — ввод пойдёт в Android' = 'Click the window to send input to Android'
    'Приложение запускается…' = 'Starting app…'
    'Запуск…' = 'Starting…'
    'Готово' = 'Ready'
    'Язык: RU' = 'Language: EN'
    'Язык: EN' = 'Language: RU'
    'Winoid — диагностика' = 'Winoid — diagnostics'
    'Фильтр лога:' = 'Log filter:'
    'Открыть лог' = 'Open log'
    'Закрыть' = 'Close'
}

function Translate-Text([string]$text) {
    if ($script:language -ne 'en') { return $text }
    if ($script:translations.ContainsKey($text)) { return [string]$script:translations[$text] }
    return $text
}

function Register-TextControl($control, [string]$property) {
    try {
        $value = $control.$property
        if ($value -is [string] -and -not $script:origText.ContainsKey($control)) {
            $script:origText[$control] = @{ Prop = $property; Value = $value }
        }
    } catch { }
}

function Register-WindowText($root) {
    if ($null -eq $root) { return }
    $q = New-Object System.Collections.Queue
    $q.Enqueue($root)
    while ($q.Count -gt 0) {
        $el = $q.Dequeue()
        if ($null -eq $el) { continue }
        if ($el -is [System.Windows.Controls.TextBlock]) { Register-TextControl $el 'Text' }
        elseif ($el -is [System.Windows.Controls.Button] -or $el -is [System.Windows.Controls.CheckBox]) { Register-TextControl $el 'Content' }
        elseif ($el -is [System.Windows.Window]) { Register-TextControl $el 'Title' }
        $n = 0
        try { $n = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($el) } catch { }
        for ($i = 0; $i -lt $n; $i++) {
            try { $q.Enqueue([System.Windows.Media.VisualTreeHelper]::GetChild($el, $i)) } catch { }
        }
    }
}

function Apply-Language {
    foreach ($entry in $script:origText.GetEnumerator()) {
        try { $entry.Key.($entry.Value.Prop) = (Translate-Text ([string]$entry.Value.Value)) } catch { }
    }
}

$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Winoid" Height="700" Width="1040" MinHeight="520" MinWidth="820"
        WindowStartupLocation="CenterScreen" Background="#141519" Foreground="#F1F3F5"
        FontFamily="Segoe UI" AllowDrop="True" UseLayoutRounding="True">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="BorderBrush" Value="#34363E"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#31343C"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#3A3D46"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button">
      <Setter Property="Background" Value="#3D7EFF"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="14,12"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="8" Padding="{TemplateBinding Padding}">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#518CFF"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#2F6BEA"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ListBoxItem">
      <Setter Property="Padding" Value="0"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ListBoxItem">
            <Border x:Name="Bd" Background="Transparent" CornerRadius="8" Padding="8">
              <ContentPresenter/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#20222A"/></Trigger>
              <Trigger Property="IsSelected" Value="True"><Setter TargetName="Bd" Property="Background" Value="#25314D"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBox">
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="BorderBrush" Value="#34363E"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBox">
            <Grid>
              <ToggleButton x:Name="ToggleButton" Focusable="False" ClickMode="Press"
                            Content="{TemplateBinding SelectionBoxItem}"
                            ContentTemplate="{TemplateBinding SelectionBoxItemTemplate}"
                            ContentStringFormat="{TemplateBinding SelectionBoxItemStringFormat}"
                            IsChecked="{Binding IsDropDownOpen, Mode=TwoWay, RelativeSource={RelativeSource TemplatedParent}}">
                <ToggleButton.Template>
                  <ControlTemplate TargetType="ToggleButton">
                    <Border x:Name="Bd" Background="#26282F" BorderBrush="#34363E" BorderThickness="1" CornerRadius="6">
                      <Grid>
                        <ContentPresenter Margin="10,0,30,0" VerticalAlignment="Center"/>
                        <Path HorizontalAlignment="Right" VerticalAlignment="Center" Margin="0,0,11,0"
                              Data="M 0 0 L 4 4 L 8 0" Stroke="#A9AEBA" StrokeThickness="1.5"/>
                      </Grid>
                    </Border>
                    <ControlTemplate.Triggers>
                      <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="#4A4D58"/></Trigger>
                    </ControlTemplate.Triggers>
                  </ControlTemplate>
                </ToggleButton.Template>
              </ToggleButton>
              <Popup x:Name="PART_Popup" Placement="Bottom" IsOpen="{TemplateBinding IsDropDownOpen}"
                     AllowsTransparency="True" Focusable="False" PopupAnimation="Slide">
                <Border Background="#26282F" BorderBrush="#34363E" BorderThickness="1" CornerRadius="6"
                        Margin="0,4,0,0" MinWidth="{TemplateBinding ActualWidth}" MaxHeight="240">
                  <ScrollViewer>
                    <ItemsPresenter/>
                  </ScrollViewer>
                </Border>
              </Popup>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ComboBoxItem">
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ComboBoxItem">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" Padding="{TemplateBinding Padding}" CornerRadius="4">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#25314D"/>
              </Trigger>
              <Trigger Property="IsHighlighted" Value="True">
                <Setter TargetName="Bd" Property="Background" Value="#3D7EFF"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="10"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Grid Background="Transparent">
              <Track x:Name="PART_Track" Orientation="{TemplateBinding Orientation}" IsDirectionReversed="True">
                <Track.DecreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageUpCommand}" Focusable="False" Opacity="0">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.DecreaseRepeatButton>
                <Track.Thumb>
                  <Thumb MinHeight="24">
                    <Thumb.Template>
                      <ControlTemplate TargetType="Thumb">
                        <Border Background="#3A3D46" CornerRadius="5" Margin="2,0"/>
                      </ControlTemplate>
                    </Thumb.Template>
                  </Thumb>
                </Track.Thumb>
                <Track.IncreaseRepeatButton>
                  <RepeatButton Command="{x:Static ScrollBar.PageDownCommand}" Focusable="False" Opacity="0">
                    <RepeatButton.Template>
                      <ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate>
                    </RepeatButton.Template>
                  </RepeatButton>
                </Track.IncreaseRepeatButton>
              </Track>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <Grid Grid.Row="0" Margin="0,0,0,16">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <StackPanel>
        <TextBlock Text="Winoid" FontSize="28" FontWeight="SemiBold" Foreground="#F1F3F5"/>
        <TextBlock Text="Android-приложения в отдельных окнах Windows" FontSize="12" Foreground="#8D929C" Margin="0,2,0,0"/>
      </StackPanel>
      <Border Grid.Column="1" Background="#1E2027" BorderBrush="#2E3139" BorderThickness="1" CornerRadius="20" Padding="14,7" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal">
          <Ellipse x:Name="StatusDot" Width="8" Height="8" Fill="#F5A623" Margin="0,0,8,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="StatusText" Text="Проверка…" FontSize="12" Foreground="#A9AEBA"/>
        </StackPanel>
      </Border>
    </Grid>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="320"/>
      </Grid.ColumnDefinitions>

      <Border Background="#191A1F" BorderBrush="#2A2C33" BorderThickness="1" CornerRadius="12" Padding="10">
        <DockPanel>
          <Grid DockPanel.Dock="Top" Margin="4,2,4,10">
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Border Background="#202127" CornerRadius="8" Padding="10,6">
              <TextBox x:Name="SearchBox" Background="Transparent" BorderThickness="0" Foreground="#F1F3F5" FontSize="13" VerticalContentAlignment="Center"/>
            </Border>
            <Button x:Name="RefreshBtn" Grid.Column="1" Content="Обновить" Margin="8,0,0,0" Padding="12,7"/>
          </Grid>
          <ListBox x:Name="AppsList" Background="Transparent" BorderThickness="0" ScrollViewer.HorizontalScrollBarVisibility="Disabled" SelectionMode="Extended">
            <ListBox.ItemTemplate>
              <DataTemplate>
                <Grid>
                  <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="44"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                  </Grid.ColumnDefinitions>
                  <Border Width="34" Height="34" CornerRadius="9" Background="#2A2F3A" VerticalAlignment="Center">
                    <Image Source="{Binding Icon}" Width="26" Height="26" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                  </Border>
                  <StackPanel Grid.Column="1" Margin="10,0,0,0" VerticalAlignment="Center">
                    <TextBlock Text="{Binding Name}" FontSize="14" FontWeight="SemiBold" Foreground="#F1F3F5" TextTrimming="CharacterEllipsis"/>
                    <TextBlock Text="{Binding Package}" FontSize="11" Foreground="#A9AEBA" TextTrimming="CharacterEllipsis"/>
                  </StackPanel>
                  <TextBlock Grid.Column="2" Text="↗" FontSize="16" Foreground="#5E6470" VerticalAlignment="Center" Margin="8,0,4,0"/>
                </Grid>
              </DataTemplate>
            </ListBox.ItemTemplate>
          </ListBox>
        </DockPanel>
      </Border>

      <ScrollViewer Grid.Column="1" Margin="16,0,0,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel>
        <Button x:Name="LaunchBtn" Style="{StaticResource Primary}" Content="Запустить в отдельном окне" IsEnabled="False"/>
        <Button x:Name="ShortcutBtn" Content="Ярлык на рабочем столе" IsEnabled="False"/>
        <Button x:Name="DriveBtn" Content="Открыть диск Android"/>
        <Button x:Name="MyComputerBtn" Content="Мой компьютер" ToolTip="Открыть проводник Windows: Этот компьютер (shell:MyComputerFolder)"/>
        <Button x:Name="UninstallBtn" Content="Удалить приложение (APK)" IsEnabled="False" ToolTip="Удалить выбранное приложение из Android"/>
        <Button x:Name="DeleteApkBtn" Content="Удалить APK-файл…" ToolTip="Удалить скачанный APK-файл с диска"/>
        <Button x:Name="DiagBtn" Content="Диагностика и лог"/>
        <Button x:Name="UpdateBtn" Content="Проверить обновления"/>
        <Button x:Name="ExportCfgBtn" Content="Экспорт настроек"/>
        <Button x:Name="ImportCfgBtn" Content="Импорт настроек"/>
        <Button x:Name="LangBtn" Content="Язык: RU"/>
        <TextBlock Text="Профиль Android" FontSize="12" Foreground="#8D929C" Margin="2,4,0,6"/>
        <ComboBox x:Name="ProfileBox" Margin="0,0,0,6"/>
        <Button x:Name="NewProfileBtn" Content="Новый профиль…"/>
        <Button x:Name="FullUiBtn" Content="Перезапустить Android"/>
        <Button x:Name="SettingsBtn" Content="Настройки Android"/>
        <Button x:Name="InstallBtn" Content="Установить APK…"/>
        <Button x:Name="BackendBtn" Content="Настроить Android" Visibility="Collapsed"/>
        <Border Height="1" Background="#2A2C33" Margin="0,8,0,14"/>
        <TextBlock Text="Размер нового окна" FontSize="12" Foreground="#8D929C" Margin="2,0,0,6"/>
        <ComboBox x:Name="SizeBox" Background="#26282F" Foreground="#F1F3F5" BorderBrush="#34363E" Padding="8,6" Margin="0,0,0,12">
          <ComboBoxItem Content="Как есть (на весь экран)" IsSelected="True"/>
          <ComboBoxItem Content="Телефон — вертикально (720 × 1280)"/>
          <ComboBoxItem Content="Планшет — горизонтально (1280 × 800)"/>
          <ComboBoxItem Content="1280 × 800"/>
          <ComboBoxItem Content="1600 × 900"/>
          <ComboBoxItem Content="1920 × 1080"/>
        </ComboBox>
        <CheckBox x:Name="RememberModeCheck" Content="Запоминать режим для каждого приложения" Foreground="#C9CDD4" Margin="2,0,0,12"/>
        <CheckBox x:Name="AutoHideCheck" Content="Скрывать индикатор после появления окна" Foreground="#C9CDD4" IsChecked="True" Margin="2,0,0,14"/>
        <CheckBox x:Name="HideCaptionCheck" Content="Обрезать заголовок Android (обычно не нужно)" Foreground="#C9CDD4" IsChecked="False" Margin="2,0,0,4"/>
        <CheckBox x:Name="NavInsetCheck" Content="Обрезать нижнюю полосу Android" Foreground="#C9CDD4" IsChecked="True" Margin="2,0,0,4"/>
        <CheckBox x:Name="StretchFillCheck" Content="Растягивать картинку по окну (без полей)" Foreground="#C9CDD4" IsChecked="False" Margin="2,0,0,4"/>
        <CheckBox x:Name="ArmCompatCheck" Content="Режим совместимости ARM" Foreground="#C9CDD4" Margin="2,0,0,4"/>
        <TextBlock x:Name="ArmCompatHint" Text="Помогает играм, которые зависают в ARM-трансляторе libndk. Медленнее, но надёжнее." TextWrapping="Wrap" FontSize="11" Foreground="#8D929C" Margin="24,0,0,14"/>
        <TextBlock x:Name="HintText" TextWrapping="Wrap" FontSize="12" Foreground="#A9AEBA"
                   Text="Перетащите APK в окно, чтобы установить. Двойной клик по приложению запускает его в отдельном окне. Кнопка «Ярлык на рабочем столе» создаёт ярлык с родной иконкой приложения. «Настройки Android» открывает системные настройки, «Диск Android» — общую память Android в проводнике, «Перезапустить Android» возвращает окна, если графика WSL зависла. Окно Winoid можно открыть ярлыком на рабочем столе, в меню Пуск или файлом Winoid.cmd."/>
        </StackPanel>
      </ScrollViewer>
    </Grid>

    <TextBlock x:Name="FooterText" Grid.Row="2" Margin="2,14,0,0" FontSize="12" Foreground="#A9AEBA" Text="Готово"/>
  </Grid>
</Window>
'@

$loaderXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinoidLoader" Width="500" Height="248"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        ShowInTaskbar="False" Topmost="True" WindowStartupLocation="CenterScreen" ResizeMode="NoResize">
  <Border Background="#1D1F25" BorderBrush="#3A3D46" BorderThickness="1" CornerRadius="16" Padding="24">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <StackPanel Orientation="Horizontal">
        <Border Width="34" Height="34" CornerRadius="9" Background="#2A3550" Margin="0,0,12,0">
          <Image x:Name="LoaderIcon" Width="24" Height="24" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock x:Name="LoaderTitle" Text="Запуск…" FontSize="17" FontWeight="SemiBold" Foreground="#F1F3F5"/>
          <TextBlock x:Name="LoaderElapsed" Text="0 сек" FontSize="11" Foreground="#8D929C"/>
        </StackPanel>
      </StackPanel>
      <TextBlock x:Name="LoaderSub" Grid.Row="1" Margin="0,14,0,0" TextWrapping="Wrap" Foreground="#B9BEC7" FontSize="12"
                 Text="Открываю приложение в отдельном окне."/>
      <ProgressBar x:Name="LoaderBar" Grid.Row="2" Height="4" Margin="0,16,0,0" IsIndeterminate="True"
                   Foreground="#3D7EFF" Background="#2A2C33" BorderThickness="0"/>
      <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,16,0,0">
        <Button x:Name="ShowWindowBtn" Content="Показать окно" Margin="0,0,8,0" Padding="12,8"
                Background="#2A2C33" Foreground="#F1F3F5" BorderBrush="#3A3D46" BorderThickness="1"/>
        <Button x:Name="HideLoaderBtn" Content="Скрыть" Padding="12,8"
                Background="#3D7EFF" Foreground="White" BorderThickness="0"/>
      </StackPanel>
    </Grid>
  </Border>
</Window>
'@

$diagXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Winoid — диагностика" Width="720" Height="540"
        WindowStartupLocation="CenterScreen" Background="#141519" Foreground="#F1F3F5">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
    </Style>
  </Window.Resources>
  <DockPanel Margin="16">
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
      <TextBlock Text="Фильтр лога:" VerticalAlignment="Center" Margin="0,0,8,0"/>
      <TextBox x:Name="DiagFilter" Width="420"/>
    </StackPanel>
    <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
      <Button x:Name="DiagRefreshBtn" Content="Обновить" Width="110"/>
      <Button x:Name="DiagOpenLogBtn" Content="Открыть лог" Width="120"/>
      <Button x:Name="DiagCloseBtn" Content="Закрыть" Width="100" Margin="0"/>
    </StackPanel>
    <TextBox x:Name="DiagText" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap"
             VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"
             Background="#0B0C0E" Foreground="#D6DAE2" BorderBrush="#2A2C33"
             FontFamily="Consolas" FontSize="11"/>
  </DockPanel>
</Window>
'@

$script:wrapperNavHeight = 44

$script:wrapperXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="1280" Height="860" MinWidth="360" MinHeight="300"
        WindowStartupLocation="CenterScreen" Background="#0B0C0E"
        ResizeMode="CanResizeWithGrip">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#26282F"/>
      <Setter Property="Foreground" Value="#F1F3F5"/>
      <Setter Property="BorderBrush" Value="#34363E"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,0,6,0"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}"
                    CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="#32353D"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Background" Value="#3D7EFF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TextBlock">
      <Setter Property="Foreground" Value="#A9AEBA"/>
      <Setter Property="FontFamily" Value="Segoe UI"/>
    </Style>
  </Window.Resources>
  <DockPanel LastChildFill="True">
    <Border x:Name="NavPanel" DockPanel.Dock="Bottom" Height="44" Background="#15171C"
            BorderBrush="#2A2C33" BorderThickness="0,1,0,0">
      <Grid Margin="10,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <Button x:Name="GameModeBtn" Content="Игра" FontSize="11" Padding="8,5" ToolTip="Скрыть панель и растянуть картинку"/>
          <Button x:Name="PhoneModeBtn" Content="Телефон" FontSize="11" Padding="8,5" ToolTip="Вертикальный режим 720 × 1280"/>
          <Button x:Name="TabletModeBtn" Content="Планшет" FontSize="11" Padding="8,5" ToolTip="Горизонтальный режим 1280 × 800"/>
          <Button x:Name="BackBtn" Content="◀  Назад" ToolTip="Назад в Android (Esc, Backspace или Alt+←)"/>
          <Button x:Name="HomeBtn" Content="●  Домой" ToolTip="На главный экран Android (Home)"/>
          <Button x:Name="RecentsBtn" Content="■  Недавние" ToolTip="Недавние приложения Android"/>
        </StackPanel>
        <TextBlock x:Name="NavLabel" Grid.Column="1" Text="Android-навигация" FontSize="11"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Margin="8,0,14,0" Foreground="#A9AEBA"/>
      </Grid>
    </Border>
    <Grid>
      <Image x:Name="View" Stretch="Uniform" RenderOptions.BitmapScalingMode="HighQuality"/>
      <Border x:Name="Loading" Background="#E60B0C0E" IsHitTestVisible="False">
        <StackPanel HorizontalAlignment="Center" VerticalAlignment="Center">
          <Border Width="46" Height="46" CornerRadius="12" Background="#2A3550" HorizontalAlignment="Center">
            <Image x:Name="LoadingIcon" Width="30" Height="30" Stretch="Uniform" HorizontalAlignment="Center" VerticalAlignment="Center"/>
          </Border>
          <TextBlock x:Name="LoadingText" Text="Приложение запускается…" Foreground="#D6DAE2" FontSize="14" Margin="0,16,0,0" HorizontalAlignment="Center"/>
        </StackPanel>
      </Border>
      <Border x:Name="Hint" Background="#CC101318" CornerRadius="10" Padding="14,10"
              HorizontalAlignment="Center" VerticalAlignment="Bottom" Margin="0,0,0,18"
              IsHitTestVisible="False">
        <TextBlock Text="Нажмите на окно — ввод пойдёт в Android" Foreground="#D6DAE2" FontSize="12"/>
      </Border>
    </Grid>
  </DockPanel>
</Window>
'@

$window = [System.Windows.Markup.XamlReader]::Parse($mainXaml)
$loader = [System.Windows.Markup.XamlReader]::Parse($loaderXaml)
$diagWindow = [System.Windows.Markup.XamlReader]::Parse($diagXaml)
try { $diagWindow.Owner = $window } catch { }

$script:appIcon = $null
$iconPath = Join-Path $PSScriptRoot 'assets\android.ico'
if (Test-Path -LiteralPath $iconPath) {
    try {
        $script:appIcon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($iconPath))
        $window.Icon = $script:appIcon
        $loader.Icon = $script:appIcon
    } catch { }
}

$statusDot     = $window.FindName('StatusDot')
$statusText    = $window.FindName('StatusText')
$searchBox     = $window.FindName('SearchBox')
$refreshBtn    = $window.FindName('RefreshBtn')
$appsList      = $window.FindName('AppsList')
$launchBtn     = $window.FindName('LaunchBtn')
$shortcutBtn   = $window.FindName('ShortcutBtn')
$driveBtn      = $window.FindName('DriveBtn')
$myComputerBtn = $window.FindName('MyComputerBtn')
$uninstallBtn  = $window.FindName('UninstallBtn')
$fullUiBtn     = $window.FindName('FullUiBtn')
$settingsBtn   = $window.FindName('SettingsBtn')
$installBtn    = $window.FindName('InstallBtn')
$backendBtn    = $window.FindName('BackendBtn')
$sizeBox       = $window.FindName('SizeBox')
$rememberModeCheck = $window.FindName('RememberModeCheck')
$rememberModeCheck.IsChecked = [bool]$script:rememberMode
$autoHideCheck = $window.FindName('AutoHideCheck')
$armCompatCheck = $window.FindName('ArmCompatCheck')
$hideCaptionCheck = $window.FindName('HideCaptionCheck')
$hideCaptionCheck.IsChecked = [bool]$script:hideCaption
$navInsetCheck = $window.FindName('NavInsetCheck')
$navInsetCheck.IsChecked = ([int]$script:fallbackNavInset -gt 0)
$stretchFillCheck = $window.FindName('StretchFillCheck')
$stretchFillCheck.IsChecked = [bool]$script:stretchFill
$armCompatCheck.IsChecked = [bool]$script:armCompat
$armCompatHint = $window.FindName('ArmCompatHint')
$footerText    = $window.FindName('FooterText')

$diagBtn       = $window.FindName('DiagBtn')
$deleteApkBtn  = $window.FindName('DeleteApkBtn')
$updateBtn     = $window.FindName('UpdateBtn')
$exportCfgBtn  = $window.FindName('ExportCfgBtn')
$importCfgBtn  = $window.FindName('ImportCfgBtn')
$langBtn       = $window.FindName('LangBtn')
$profileBox    = $window.FindName('ProfileBox')
$newProfileBtn = $window.FindName('NewProfileBtn')
$diagText      = $diagWindow.FindName('DiagText')
$diagFilter    = $diagWindow.FindName('DiagFilter')
$diagRefreshBtn = $diagWindow.FindName('DiagRefreshBtn')
$diagOpenLogBtn = $diagWindow.FindName('DiagOpenLogBtn')
$diagCloseBtn  = $diagWindow.FindName('DiagCloseBtn')

# Tray icon with quick access even when the manager window is closed.
$script:tray = $null
try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $icoFile = Join-Path $PSScriptRoot 'assets\android.ico'
    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    if (Test-Path -LiteralPath $icoFile) { $script:tray.Icon = [System.Drawing.Icon]::new($icoFile) }
    $script:tray.Text = 'Winoid'
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add('Показать Winoid', $null, { param($s,$e) $window.Show(); $window.Activate() })
    [void]$menu.Items.Add('Диагностика', $null, { param($s,$e) Show-Diagnostics })
    [void]$menu.Items.Add('Выход', $null, { param($s,$e) $script:quitByUser = $true; $window.Close() })
    $script:tray.ContextMenuStrip = $menu
    $script:tray.Visible = $true
} catch { }

$loaderTitle   = $loader.FindName('LoaderTitle')
$loaderSub     = $loader.FindName('LoaderSub')
$loaderElapsed = $loader.FindName('LoaderElapsed')
$loaderBar     = $loader.FindName('LoaderBar')
$loaderIcon    = $loader.FindName('LoaderIcon')
$showWindowBtn = $loader.FindName('ShowWindowBtn')
$hideLoaderBtn = $loader.FindName('HideLoaderBtn')

Register-WindowText $window
Register-WindowText $loader
Register-WindowText $diagWindow
if ($script:language -eq 'en') { Apply-Language }
$langBtn.Content = $(if ($script:language -eq 'en') { 'EN / RU' } else { 'RU / EN' })
$script:profileLoading = $true
foreach ($pname in @($script:profiles.Keys | Sort-Object)) { [void]$profileBox.Items.Add($pname) }
$profileBox.SelectedItem = $script:activeProfile
$script:profileLoading = $false

function Set-Status([string]$text, [string]$color) {
    $statusText.Text = $text
    $statusDot.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString($color)
}

function Set-Footer([string]$text) {
    $footerText.Text = $text
}

function Show-Diagnostics {
    try {
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('=== Winoid ===')
        [void]$lines.Add("Version: $($script:appVersion)   Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
        [void]$lines.Add("WSL distro: $($script:wslDistro)   ADB: $($script:adbSerial)")
        $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'waydroid', 'status')) 10000
        [void]$lines.Add('=== Waydroid ===')
        [void]$lines.Add($(if ($r.Out) { $r.Out.Trim() } else { "unavailable: $($r.Err)" }))
        [void]$lines.Add('=== State ===')
        [void]$lines.Add("Apps: $($script:apps.Count)   Wrappers: $($script:wrappers.Count)   ADB shell: $(if ($script:adb -and $script:adb.Running) {'up'} else {'down'})")
        [void]$lines.Add("Icons: $(@(Get-ChildItem -LiteralPath (Join-Path $script:dataRoot 'icons') -ErrorAction SilentlyContinue).Count)")
        [void]$lines.Add('=== Log (last 40) ===')
        $log = Join-Path $script:dataRoot 'winoid.log'
        if (Test-Path -LiteralPath $log) {
            $tail = @(Get-Content -LiteralPath $log -Tail 300)
            $needle = $diagFilter.Text.Trim()
            if ($needle) { $tail = @($tail | Where-Object { $_ -match [regex]::Escape($needle) }) }
            [void]$lines.AddRange(@($tail | Select-Object -Last 40))
        }
        $diagText.Text = ($lines -join "`r`n")
        if (-not $diagWindow.IsVisible) { $diagWindow.Show() }
        $diagWindow.Activate()
    } catch {
        Set-Footer "Диагностика недоступна: $($_.Exception.Message)"
    }
}

# --- diagnostics -----------------------------------------------------------
# A single failed timer or UI callback must never terminate the manager:
# PowerShell throws into the WPF dispatcher and Windows kills the process.
function Write-WinoidLog([string]$Text) {
    try {
        $path = Join-Path $script:dataRoot 'winoid.log'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1048576) {
            Move-Item -LiteralPath $path -Destination ($path + '.old') -Force -ErrorAction SilentlyContinue
        }
        $dir = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::AppendAllText($path, ("{0} {1}`r`n" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Text), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

function Show-InternalError([string]$Text) {
    try {
        $now = Get-Date
        if ($Text -eq $script:lastErrorText -and ($now - $script:lastErrorAt).TotalSeconds -lt 20) { return }
        $script:lastErrorText = $Text
        $script:lastErrorAt = $now
        Set-Footer "Ошибка: $Text"
    } catch { }
}

function Set-WinoidDarkTitleBar($Window) {
    try {
        $helper = [System.Windows.Interop.WindowInteropHelper]::new($Window)
        [NativeWin]::UseDarkTitleBar($helper.Handle)
    } catch { }
}

function Invoke-Safe {
    param([string]$Where, [scriptblock]$Action)
    try {
        & $Action
    } catch {
        $ex = $_.Exception
        Write-WinoidLog ("ERROR {0}: {1}" -f $Where, $ex.ToString())
        Show-InternalError $ex.Message
    }
}

# Last line of defence for exceptions the individual guards miss. Handled
# dispatcher errors are logged and the app keeps running.
$window.Dispatcher.Add_UnhandledException({
    param($sender, $e)
    try { Write-WinoidLog ("DISPATCHER: " + $e.Exception.ToString()) } catch { }
    Show-InternalError $e.Exception.Message
    $e.Handled = $true
})
[System.AppDomain]::CurrentDomain.add_UnhandledException({
    param($sender, $e)
    try { Write-WinoidLog ("FATAL: " + $e.ExceptionObject.ToString()) } catch { }
})

# Watchdog support: the launcher stub restarts the manager if it disappears
# without a clean shutdown request. The heartbeat proves we were alive.
$script:heartbeatPath = Join-Path $script:dataRoot 'heartbeat'
$script:shutdownPath = Join-Path $script:dataRoot 'shutdown.request'
$script:quitPath = Join-Path $script:dataRoot 'quit.request'
$script:quitByUser = $false
$script:lastHeartbeat = [DateTime]::MinValue
try { Remove-Item -LiteralPath $script:shutdownPath -Force -ErrorAction SilentlyContinue } catch { }

function Get-WslBase {
    param([switch]$Root)
    $a = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($script:wslDistro)) {
        [void]$a.Add('-d'); [void]$a.Add($script:wslDistro)
    }
    if ($Root) {
        [void]$a.Add('-u'); [void]$a.Add('root')
    }
    return @($a)
}

function Invoke-Wsl {
    param([string[]]$Arguments, [int]$TimeoutMs = 20000)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:wsl
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill() } catch { }
        return [pscustomobject]@{ Out = ''; Err = 'timeout'; Code = -1 }
    }
    return [pscustomobject]@{ Out = $outTask.Result; Err = $errTask.Result; Code = $p.ExitCode }
}

function Get-WslDistroName {
    if (-not [string]::IsNullOrWhiteSpace($script:wslDistro)) { return $script:wslDistro }
    try {
        $out = & $script:wsl -l -q 2>$null
        $text = ($out | Out-String) -replace "`0", ''
        $name = @($text -split "`r?`n" | Where-Object { $_.Trim() })[0]
        if ($name) { $script:wslDistro = $name.Trim() }
    } catch { }
    return $script:wslDistro
}

function Get-WslUserName {
    if (-not [string]::IsNullOrWhiteSpace($script:wslUser)) { return $script:wslUser }
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', 'id -un')) 12000
    if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
        $script:wslUser = $r.Out.Trim()
    }
    return $script:wslUser
}

function Get-WslHome {
    if (-not [string]::IsNullOrWhiteSpace($script:wslHome)) { return $script:wslHome }
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', 'printf %s "$HOME"')) 12000
    if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
        $script:wslHome = $r.Out.Trim()
    }
    return $script:wslHome
}

# libndk's default "two-gear" translator runs a heavy optimizer on hot ARM
# code. On some ARM64 games that optimizer never finishes (Waydroid issue
# #2446): the process spins at 100% CPU and the window stays black. libndk's
# lighter mode skips it, which is slower but gets such games running.
# The property only affects processes started after it is set.
function Set-ArmCompatMode([bool]$Enabled) {
    $mode = $(if ($Enabled) { 'light-translate-or-interpret' } else { 'two-gear' })
    $cmd = "lxc-unfreeze -P /var/lib/waydroid/lxc -n waydroid >/dev/null 2>&1; " +
        "echo WINOID_MODE_BEFORE_BEGIN; lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- getprop ndk_translation.mode 2>/dev/null; " +
        "echo WINOID_MODE_BEFORE_END; " +
        "lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- setprop ndk_translation.mode $mode 2>/dev/null; " +
        "echo WINOID_MODE_AFTER_BEGIN; lxc-attach -P /var/lib/waydroid/lxc -n waydroid -- getprop ndk_translation.mode 2>/dev/null; " +
        "echo WINOID_MODE_AFTER_END"
    $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'bash', '-lc', $cmd)) 15000
    $text = (($r.Out + "`n" + $r.Err) -replace "`0", '')
    $before = ''
    $after = ''
    if ($text -match '(?s)WINOID_MODE_BEFORE_BEGIN\s*(.*?)\s*WINOID_MODE_BEFORE_END') { $before = $matches[1].Trim() }
    if ($text -match '(?s)WINOID_MODE_AFTER_BEGIN\s*(.*?)\s*WINOID_MODE_AFTER_END') { $after = $matches[1].Trim() }
    if ($r.Code -eq 0 -and $after -eq $mode) {
        if ($before -ne $mode) {
            $script:armCompatDirty = $true
            $script:armCompatRestarted = @{}
        }
        $script:armCompatApplied = $Enabled
        Write-WinoidLog "ARM compat: $mode (was $before)"
        return $true
    }
    $detail = (($text -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 2) -join ' | '
    Write-WinoidLog "ERROR ARM compat ($mode): exit $($r.Code) $detail"
    return $false
}

# Make the runtime property match the setting before an app starts. A process
# keeps the mode it was started with, so after a switch the previous instance
# must be stopped instead of being brought back to the foreground.
function Sync-ArmCompatMode([string]$Package) {
    # libhoudini has no ndk_translation.mode; nothing to synchronize.
    if ((Get-ArmTranslator) -eq 'libhoudini') {
        $script:armCompat = $false
        $script:armCompatApplied = $false
        return $true
    }
    # On a cold manager start with the option off, Android already uses the
    # default translator. Do not touch root/LXC unless the setting changed.
    if ($null -eq $script:armCompatApplied -and -not $script:armCompat) {
        $script:armCompatApplied = $false
    }
    if ($script:armCompatApplied -ne $script:armCompat) {
        if ((Get-Date) -lt $script:armCompatNextTry) { return (-not $script:armCompat) }
        if (-not (Set-ArmCompatMode $script:armCompat)) {
            $script:armCompatNextTry = (Get-Date).AddSeconds(60)
            # A failed switch must not stop an ordinary launch when compatibility
            # mode is off: the app simply keeps the translator it already has.
            return (-not $script:armCompat)
        }
    }
    if ($script:armCompatDirty -and $Package -and -not $script:armCompatRestarted.ContainsKey($Package)) {
        # A process keeps the translation mode it started with.
        $null = Send-Android "am force-stop $Package"
        $script:armCompatRestarted[$Package] = $true
        Start-Sleep -Milliseconds 500
    }
    return $true
}

# Waydroid keeps its Android images and /sdcard in the session user's home.
# The files are owned by Android's media_rw (1023), so grant the WSL user an
# ACL instead of changing ownership (Android still sees its normal uids).
function Get-AndroidStorageInfo {
    param([switch]$ApplyAcl)
    $linuxHome = Get-WslHome
    if ([string]::IsNullOrWhiteSpace($linuxHome)) { return $null }

    # Keep the shell command free of variables: WSL's -lc argument handling
    # strips $name expansions when the script is passed through CreateProcess.
    $storage = ''
    foreach ($candidate in @("$linuxHome/.local/share/waydroid/data/media/0", '/var/lib/waydroid/data/media/0')) {
        $cmd = "test -d '$candidate' && printf %s '$candidate'"
        $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'bash', '-lc', $cmd)) 15000
        if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
            $storage = $r.Out.Trim()
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($storage)) { return $null }

    if ($ApplyAcl) {
        # The ACL survives restarts. Re-applying it recursively over the whole
        # /sdcard on every launch froze the manager for tens of seconds, so
        # first check whether the WSL user can already read the folder.
        $checkCmd = "test -r '$storage' -a -x '$storage' && printf WINOID_STORAGE_OK"
        $check = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', $checkCmd)) 10000
        if ($check.Out -match 'WINOID_STORAGE_OK') { return $storage }

        $user = Get-WslUserName
        if ([string]::IsNullOrWhiteSpace($user)) { $user = 'winoid' }
        $cmd = "if command -v setfacl >/dev/null 2>&1; then setfacl -R -m u:$user:rwx '$storage' 2>/dev/null; setfacl -R -d -m u:$user:rwx '$storage' 2>/dev/null; else chmod -R o+rwX '$storage' 2>/dev/null; fi; printf %s '$storage'"
        $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'bash', '-lc', $cmd)) 120000
        if ($r.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($r.Out)) {
            return $r.Out.Trim()
        }
    }
    return $storage
}

function Get-FreeDriveLetter {
    try {
        $used = @{}
        foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            $used[$d.Name] = $true
        }
        foreach ($letter in @('W', 'V', 'X', 'Y', 'Z', 'T', 'S', 'R', 'Q', 'P', 'O', 'N', 'M', 'L', 'K', 'J', 'I', 'H', 'G', 'F')) {
            if ($used.ContainsKey($letter)) { continue }
            $sb = New-Object System.Text.StringBuilder 1024
            if ([WinoidDrive]::QueryDosDevice("${letter}:", $sb, 1024) -ne 0) { continue }
            if (Test-Path -LiteralPath "${letter}:\") { continue }
            return $letter
        }
    } catch { }
    return $null
}

function Set-DriveAppearance([string]$Letter) {
    try {
        $base = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$Letter"
        New-Item -Path "$base\DefaultLabel" -Force | Out-Null
        Set-Item -Path "$base\DefaultLabel" -Value 'Android'
        $icon = Join-Path $script:baseDir 'assets\android.ico'
        if (Test-Path -LiteralPath $icon) {
            New-Item -Path "$base\DefaultIcon" -Force | Out-Null
            Set-Item -Path "$base\DefaultIcon" -Value $icon
        }
    } catch { }
}

# A drive can have a stack of DOS-device mappings. P9Rdr targets need
# DDD_RAW_TARGET_PATH, ordinary UNC targets do not.
function Remove-DriveMapping([string]$Letter) {
    for ($i = 0; $i -lt 12; $i++) {
        $sb = New-Object System.Text.StringBuilder 1024
        $n = [WinoidDrive]::QueryDosDevice("${Letter}:", $sb, 1024)
        if ($n -eq 0) { break }
        $target = $sb.ToString()
        $flags = if ($target.StartsWith('\Device\')) { 7 } else { 6 }
        if (-not [WinoidDrive]::DefineDosDevice($flags, "${Letter}:", $target)) { break }
    }
    try { & net.exe use "${Letter}:" /delete /y 2>&1 | Out-Null } catch { }
}

# A force-killed or crashed manager leaves its DOS-device mapping behind.
# Over several launches those stale mappings consume every free letter, so
# remove only mappings that point at Waydroid's media directory.
function Clear-StaleAndroidDrives {
    $removed = 0
    foreach ($code in 65..90) {
        $letter = [string][char]$code
        $sb = New-Object System.Text.StringBuilder 1024
        if ([WinoidDrive]::QueryDosDevice("${letter}:", $sb, 1024) -eq 0) { continue }
        $target = $sb.ToString()
        if ($target -notmatch '(?i)waydroid\\data\\media\\0') { continue }
        Write-WinoidLog "drive cleanup ${letter}: $target"
        Remove-DriveMapping $letter
        $removed++
    }
    if ($removed -gt 0) { Write-WinoidLog "drive cleanup: removed $removed stale mapping(s)" }
}

function Mount-AndroidDrive {
    param([switch]$Open)
    if (-not $script:staleDrivesCleared) {
        $script:staleDrivesCleared = $true
        Clear-StaleAndroidDrives
    }
    if (-not [string]::IsNullOrWhiteSpace($script:androidDrive) -and (Test-Path -LiteralPath "${script:androidDrive}\")) {
        if ($Open) { Start-Process -FilePath 'explorer.exe' -ArgumentList "${script:androidDrive}\" }
        return $true
    }

    $storage = Get-AndroidStorageInfo -ApplyAcl:(-not $script:androidDriveAclDone)
    if ([string]::IsNullOrWhiteSpace($storage)) {
        Set-Footer 'Не нашёл хранилище Android в WSL.'
        return $false
    }
    $script:androidDriveAclDone = $true

    $distro = Get-WslDistroName
    if ([string]::IsNullOrWhiteSpace($distro)) {
        Set-Footer 'Не удалось определить дистрибутив WSL.'
        return $false
    }
    $uncRoot = "\\wsl.localhost\$distro"
    if (-not (Test-Path -LiteralPath $uncRoot)) {
        $uncRoot = "\\wsl`$\$distro"
    }
    if (-not (Test-Path -LiteralPath $uncRoot)) {
        Set-Footer "WSL-дистрибутив $distro недоступен."
        return $false
    }

    $letter = Get-FreeDriveLetter
    if ([string]::IsNullOrWhiteSpace($letter)) {
        Set-Footer 'Нет свободной буквы диска для Android.'
        return $false
    }

    Set-DriveAppearance $letter
    Set-Footer 'Подключаю диск Android…'
    $target = ''
    $mode = ''
    $ok = $false

    # Connect the WSL share to the letter, then point the letter at /sdcard
    # through the same Plan 9 device. This keeps Explorer seeing a connected
    # network drive rather than a disconnected UNC mapping.
    try { & net.exe use "${letter}:" $uncRoot /persistent:no 2>&1 | Out-Null } catch { }
    if ($LASTEXITCODE -eq 0) {
        $sb = New-Object System.Text.StringBuilder 1024
        if ([WinoidDrive]::QueryDosDevice("${letter}:", $sb, 1024) -gt 0) {
            $base = $sb.ToString()
            if ($base.StartsWith('\Device\P9Rdr\')) {
                $target = $base + ($storage -replace '/', '\')
                if ([WinoidDrive]::DefineDosDevice(9, "${letter}:", $target)) {
                    $ok = $true
                    $mode = 'p9'
                }
            }
        }
    }

    if (-not $ok) {
        try { & net.exe use "${letter}:" /delete /y 2>&1 | Out-Null } catch { }
        $target = $uncRoot + ($storage -replace '/', '\')
        if ([WinoidDrive]::DefineDosDevice(8, "${letter}:", $target)) {
            $ok = $true
            $mode = 'unc'
        }
    }

    if (-not $ok) {
        Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter" -Recurse -Force -ErrorAction SilentlyContinue
        Set-Footer 'Не удалось подключить диск Android.'
        return $false
    }

    $script:androidDrive = "${letter}:"
    $script:androidDriveTarget = $target
    $script:androidDriveMode = $mode
    try {
        [WinoidDrive]::SHChangeNotify(0x100, 0x5, "${letter}:\", $null)
        [WinoidDrive]::SHChangeNotify(0x2000, 0x5, "${letter}:\", $null)
    } catch { }
    Set-Footer "Диск Android подключён: ${letter}:"
    if ($Open) { Start-Process -FilePath 'explorer.exe' -ArgumentList "${letter}:\" }
    return $true
}

function Disconnect-AndroidDrive {
    if ([string]::IsNullOrWhiteSpace($script:androidDrive)) { return }
    $letter = $script:androidDrive.TrimEnd(':')
    try { Remove-DriveMapping $letter } catch { }
    try { [WinoidDrive]::SHChangeNotify(0x80, 0x5, "${letter}:\", $null) } catch { }
    Remove-Item -LiteralPath "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\DriveIcons\$letter" -Recurse -Force -ErrorAction SilentlyContinue
    $script:androidDrive = ''
    $script:androidDriveTarget = ''
    $script:androidDriveMode = ''
}

function Start-WslDetached {
    param([string[]]$Arguments)
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:wsl
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($null -ne $p) { $p.Dispose() }
}

# WSL stops the VM after about a minute without an active wsl.exe client.
# A sleeping client keeps the Android session alive while the manager is open.
function Start-WslKeepAlive {
    if ($script:wslKeepAlive -and -not $script:wslKeepAlive.HasExited) { return }
    # A manager restart leaves the previous keepalive running; without this
    # cleanup dozens of sleeping wsl.exe clients accumulate.
    $stale = @(Get-CimInstance Win32_Process -Filter "Name='wsl.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*exec sleep 86400*' -and $_.ProcessId -ne $PID })
    foreach ($p in $stale) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:wsl
    foreach ($a in ((Get-WslBase) + @('--', 'bash', '-lc', 'exec sleep 86400'))) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    try {
        $script:wslKeepAlive = [System.Diagnostics.Process]::Start($psi)
    } catch {
        $script:wslKeepAlive = $null
    }
}

function Get-WaydroidStatus {
    $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'waydroid', 'status')) 15000
    if ($r.Out -match '(?m)^Session:\s*(\S+)') { return $matches[1] }
    return 'STOPPED'
}

# Session: RUNNING is not enough: Waydroid suspends the container when idle
# (Container: FROZEN) and then adb, the DEX helper and app launches all hang.
function Get-WaydroidContainerStatus {
    $r = Invoke-Wsl ((Get-WslBase -Root) + @('--', 'waydroid', 'status')) 15000
    if ($r.Out -match '(?m)^Container:\s*(\S+)') { return $matches[1] }
    return 'UNKNOWN'
}

# Wake a suspended Android runtime before any operation that needs adb.
# show-full-ui opens the launcher surface, which the manager already parks.
function Ensure-WaydroidAwake([string]$package) {
    $state = Get-WaydroidContainerStatus
    if ($state -eq 'RUNNING') { return $true }
    if ($state -eq 'FROZEN') {
        Write-WinoidLog 'waydroid frozen: waking container quietly'
        # Launching the target app wakes the runtime without opening the
        # Android launcher on the desktop (unlike show-full-ui).
        $wakeCmd = if (-not [string]::IsNullOrWhiteSpace($package)) { "waydroid app launch $package" } else { 'waydroid show-full-ui' }
        try {
            $null = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', $wakeCmd)) 12000
        } catch { }
        for ($i = 0; $i -lt 14; $i++) {
            Start-Sleep -Milliseconds 700
            if ((Get-WaydroidContainerStatus) -eq 'RUNNING') {
                Write-WinoidLog 'waydroid awake'
                return $true
            }
        }
    }
    return $false
}

# Which ARM translator Waydroid uses. Setup-Backend stores it in config.json;
# on older installs it is read from waydroid.cfg once per manager run.
function Get-ArmTranslator {
    if ($script:armTranslator) { return $script:armTranslator }
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'grep', '-m1', '^ro\.dalvik\.vm\.native\.bridge', '/var/lib/waydroid/waydroid.cfg')) 8000
    $text = $r.Out + "`n" + $r.Err
    if ($text -match 'libhoudini') { $script:armTranslator = 'libhoudini' }
    elseif ($text -match 'libndk') { $script:armTranslator = 'libndk' }
    return $script:armTranslator
}

# libndk's compatibility mode has no equivalent in libhoudini, so the option
# is hidden on Intel machines instead of pretending to do something.
function Update-ArmCompatUi {
    if ((Get-ArmTranslator) -ne 'libhoudini') { return }
    if ($script:armCompat) {
        # Upgrading from a libndk install can leave the old setting in
        # config.json. Clear it once so it cannot come back or confuse a later
        # translator switch.
        $script:armCompat = $false
        $script:armCompatApplied = $false
        $script:armCompatDirty = $false
        $script:armCompatRestarted = @{}
        Save-ArmCompatSetting
    }
    if ($armCompatCheck) { $armCompatCheck.Visibility = 'Collapsed' }
    if ($armCompatHint) {
        $armCompatHint.Text = 'На этом компьютере используется libhoudini (Intel) — режим совместимости нужен только для libndk на AMD.'
    }
}

function Test-Backend {
    $cmd = 'command -v waydroid >/dev/null 2>&1 && echo WINOID_BACKEND_OK'
    $r = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', $cmd)) 10000
    return ($r.Out -match 'WINOID_BACKEND_OK')
}

function Test-Session {
    if ((Get-WaydroidStatus) -eq 'RUNNING') {
        $script:sessionRunning = $true
        Update-ArmCompatUi
        Set-Status 'Android работает' '#3DDC84'
        $backendBtn.Visibility = 'Collapsed'
        return $true
    }
    $script:sessionRunning = $false
    if (-not (Test-Backend)) {
        Set-Status 'Бэкенд не настроен' '#E5484D'
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return $false
    }
    Update-ArmCompatUi
    Set-Status 'Android остановлен' '#F5A623'
    $backendBtn.Visibility = 'Collapsed'
    return $false
}

function Update-AppFilter {
    $q = $searchBox.Text.Trim()
    if ($q.Length -gt 0) {
        $escaped = [regex]::Escape($q)
        $view = @($script:apps | Where-Object { $_.Name -match $escaped -or $_.Package -match $escaped })
    } else {
        $view = $script:apps
    }
    $appsList.ItemsSource = $view
    if ($view.Count -gt 0) { $appsList.SelectedIndex = 0 }
    $launchBtn.IsEnabled = ($view.Count -gt 0)
    $shortcutBtn.IsEnabled = ($view.Count -gt 0)
    $uninstallBtn.IsEnabled = ($view.Count -gt 0)
}

function Get-LauncherApps {
    $dex = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    if (-not (Test-Path -LiteralPath $dex)) { return @() }
    $remoteDex = '/data/local/tmp/winoid-icon.dex'
    $linuxDex = ConvertTo-WslPath $dex
    $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon --list"
    $out = ''

    # WSL adb reaches the Waydroid container even when a Windows VPN
    # swallows the route to 192.168.240.0/24.
    try {
        $stateArgs = (Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'get-state')
        $r = Invoke-Wsl $stateArgs 10000
        if ($r.Out -notmatch 'device') {
            $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', 'connect', $script:adbSerial)) 10000
            $r = Invoke-Wsl $stateArgs 10000
        }
        if ($r.Out -match 'device') {
            $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'push', $linuxDex, $remoteDex)) 15000
            $res = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'shell', $cmd)) 20000
            if ($res.Out) { $out = $res.Out }
        }
    } catch { Write-WinoidLog ("ERROR app list via WSL: " + $_.Exception.Message) }

    if (-not $out -and $script:adbPath) {
        try {
            $null = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'push', $dex, $remoteDex) -TimeoutMs 15000
            $res = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'shell', $cmd) -TimeoutMs 20000
            if ($res) { $out = $res }
        } catch { Write-WinoidLog ("ERROR app list via adb: " + $_.Exception.Message) }
    }

    $byPackage = @{}
    $iconsDir = Join-Path $script:dataRoot 'icons'
    $fallbackIcon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new((Join-Path $script:baseDir 'assets\android.ico')))
    foreach ($line in ($out -split "`r?`n")) {
        if ($line -match '^([^\t]+)\t(\S+)$') {
            $name = $matches[1].Trim()
            $pkg = $matches[2].Trim()
            if (-not $byPackage.ContainsKey($pkg)) {
                $appItem = [pscustomobject]@{ Name = $name; Package = $pkg }
                $cachedIco = Join-Path $iconsDir ($pkg + '.ico')
                if (Test-Path -LiteralPath $cachedIco) {
                    $icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($cachedIco))
                } else {
                    # Do the slow adb extraction one app at a time on a timer
                    # so the manager window never freezes during a refresh.
                    $icon = $fallbackIcon
                    $script:iconQueue.Enqueue($pkg)
                }
                $appItem | Add-Member -MemberType NoteProperty -Name Icon -Value $icon -Force
                $byPackage[$pkg] = $appItem
            }
        }
    }
    $apps = @($byPackage.Values | Sort-Object Name)
    if ($apps.Count -gt 0) {
        # Remember a good list so it can still be shown while Waydroid is
        # frozen/suspended and its helper cannot answer.
        try {
            $plain = @($apps | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Package = $_.Package } })
            $cache = Join-Path $script:dataRoot 'apps.json'
            [System.IO.File]::WriteAllText($cache, ($plain | ConvertTo-Json -Depth 3 -Compress), (New-Object System.Text.UTF8Encoding($false)))
        } catch { }
    }
    return $apps
}

function Get-CachedLauncherApps {
    $cache = Join-Path $script:dataRoot 'apps.json'
    if (-not (Test-Path -LiteralPath $cache)) { return @() }
    try {
        $items = @(Get-Content -LiteralPath $cache -Raw -Encoding utf8 | ConvertFrom-Json)
        $result = New-Object System.Collections.ArrayList
        foreach ($it in $items) {
            if ([string]::IsNullOrWhiteSpace([string]$it.Package)) { continue }
            $app = [pscustomobject]@{ Name = [string]$it.Name; Package = [string]$it.Package }
            $app | Add-Member -MemberType NoteProperty -Name Icon -Value (Get-AppIconPath $app) -Force
            [void]$result.Add($app)
        }
        return @($result)
    } catch { return @() }
}

# Applies the result of the background app-list job on the UI thread.
function Apply-AppListResult($result) {
    $generic = [System.Windows.Media.Imaging.BitmapFrame]::Create(
        [Uri]::new((Join-Path $script:baseDir 'assets\android.ico')))
    $list = New-Object System.Collections.ArrayList
    foreach ($r in @($result)) {
        if ([string]::IsNullOrWhiteSpace([string]$r.Package)) { continue }
        $app = [pscustomobject]@{ Name = [string]$r.Name; Package = [string]$r.Package }
        $path = [string]$r.IconPath
        $icon = $generic
        if ($path -and (Test-Path -LiteralPath $path)) {
            try { $icon = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($path)) } catch { }
        } else {
            $script:iconQueue.Enqueue([string]$r.Package)
        }
        $app | Add-Member -MemberType NoteProperty -Name Icon -Value $icon -Force
        [void]$list.Add($app)
    }
    $script:apps = @($list)
    $cached = $false
    if ($script:apps.Count -eq 0) {
        $script:apps = @(Get-CachedLauncherApps)
        $cached = $true
    }
    Update-AppFilter
    Write-WinoidLog ("app list (async): " + $script:apps.Count + " apps, queued icons=" + $script:iconQueue.Count)
    if ($script:apps.Count -eq 0) {
        Set-Footer 'Список пуст. Android ещё запускается? Нажмите «Обновить».'
    } elseif ($cached) {
        Set-Footer 'Список приложений из кэша (Android не отвечает)'
    } else {
        Set-Footer "Приложений: $($script:apps.Count)"
    }
    if ($script:iconQueue.Count -gt 0) { $iconTimer.Start() }
}

# The WSL/ADB work runs in a background job; the dispatcher only applies the
# finished list, so the manager window never freezes while it is read.
$script:appsJob = $null
$script:appsJobStart = [DateTime]::UtcNow
$appsRefreshTimer = [System.Windows.Threading.DispatcherTimer]::new()
$appsRefreshTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$appsRefreshTimer.Add_Tick({
    Invoke-Safe 'appsRefresh' {
        if ($null -eq $script:appsJob) { $appsRefreshTimer.Stop(); return }
        $state = 'Unknown'
        try { $state = [string]$script:appsJob.State } catch { }
        if ($state -notin @('Completed', 'Failed', 'Stopped')) {
            if (([DateTime]::UtcNow - $script:appsJobStart).TotalSeconds -gt 60) {
                Write-WinoidLog 'app list job timed out; using cache'
                try { Stop-Job -Job $script:appsJob -Force -ErrorAction SilentlyContinue } catch { }
            } else { return }
        }
        $appsRefreshTimer.Stop()
        $result = @()
        try { $result = @(Receive-Job -Job $script:appsJob -ErrorAction SilentlyContinue) } catch { }
        try { Remove-Job -Job $script:appsJob -Force -ErrorAction SilentlyContinue } catch { }
        $script:appsJob = $null
        Apply-AppListResult $result
    }
})

function Refresh-Apps {
    $script:iconAdbOffline = $false
    $script:iconQueue.Clear()
    if ($null -ne $script:appsJob) {
        $state = 'Unknown'
        try { $state = [string]$script:appsJob.State } catch { }
        if ($state -notin @('Completed', 'Failed', 'Stopped')) {
            Set-Footer 'Чтение списка приложений…'
            return
        }
        try { Remove-Job -Job $script:appsJob -Force -ErrorAction SilentlyContinue } catch { }
        $script:appsJob = $null
    }
    Set-Footer 'Чтение списка приложений…'
    $dexPath = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    $script:appsJob = Start-Job -ScriptBlock {
        param([string]$Wsl, [string]$Distro, [string]$Serial, [string]$Dex, [string]$DataRoot)
        function Invoke-W([string[]]$Args, [int]$Ms) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $Wsl
            foreach ($a in $Args) { [void]$psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($Ms)) { try { $p.Kill() } catch { }; return @{ Out = ''; Err = 'timeout'; Code = -1 } }
            @{ Out = $o.Result; Err = $e.Result; Code = $p.ExitCode }
        }
        function Convert-LinuxPath([string]$Path) {
            $full = [System.IO.Path]::GetFullPath($Path)
            if ($full -match '^([A-Za-z]):\\(.*)$') { return '/mnt/' + $matches[1].ToLowerInvariant() + '/' + $matches[2].Replace('\', '/') }
            return $full.Replace('\', '/')
        }
        $base = @(); if ($Distro) { $base = @('-d', $Distro) }
        $check = Invoke-W ($base + @('--', 'bash', '-lc', 'command -v waydroid >/dev/null 2>&1 && echo WINOID_BACKEND_OK')) 10000
        if ($check.Out -notmatch 'WINOID_BACKEND_OK') { return @() }
        $remote = '/data/local/tmp/winoid-icon.dex'
        $state = Invoke-W ($base + @('--', 'adb', '-s', $Serial, 'get-state')) 8000
        if ($state.Out -notmatch 'device') {
            $null = Invoke-W ($base + @('--', 'adb', 'connect', $Serial)) 10000
            $state = Invoke-W ($base + @('--', 'adb', '-s', $Serial, 'get-state')) 8000
        }
        $apps = @()
        if ($state.Out -match 'device') {
            $linuxDex = Convert-LinuxPath $Dex
            $null = Invoke-W ($base + @('--', 'adb', '-s', $Serial, 'push', $linuxDex, $remote)) 15000
            $cmd = "CLASSPATH=$remote app_process /system/bin WinoidIcon --list"
            $r = Invoke-W ($base + @('--', 'adb', '-s', $Serial, 'shell', $cmd)) 20000
            foreach ($line in ($r.Out -split "`r?`n")) {
                if ($line -match '^([^\t]+)\t(\S+)$') {
                    $apps += [pscustomobject]@{ Name = $matches[1].Trim(); Package = $matches[2].Trim() }
                }
            }
        }
        if ($apps.Count -eq 0) {
            $cmd = 'export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/$(id -u); waydroid app list'
            $r = Invoke-W ($base + @('--', 'bash', '-lc', $cmd)) 30000
            foreach ($b in (($r.Out -split '(?m)^Name:\s*') | Select-Object -Skip 1)) {
                $name = (($b -split "`r?`n")[0]).Trim()
                if ($b -notmatch 'packageName:\s*(\S+)') { continue }
                if ($b -notmatch 'android\.intent\.category\.LAUNCHER') { continue }
                $apps += [pscustomobject]@{ Name = $name; Package = $matches[1].Trim() }
            }
        }
        $unique = @{}; foreach ($a in $apps) { if (-not $unique.ContainsKey($a.Package)) { $unique[$a.Package] = $a } }
        $iconsDir = Join-Path $DataRoot 'icons'
        $result = @()
        foreach ($a in @($unique.Values | Sort-Object Name)) {
            $ico = Join-Path $iconsDir ($a.Package + '.ico')
            $result += [pscustomobject]@{ Name = $a.Name; Package = $a.Package; IconPath = $(if (Test-Path -LiteralPath $ico) { $ico } else { '' }) }
        }
        $result
    } -ArgumentList @($script:wsl, $script:wslDistro, $script:adbSerial, $dexPath, $script:dataRoot)
    $script:appsJobStart = [DateTime]::UtcNow
    $appsRefreshTimer.Start()
}

# A watchdog restart leaves WSLg windows parked off-screen by the previous
# manager. Bring them back so a relaunch can find them again.
function Restore-OrphanedParkedWindows {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $threshold = $vs.Right + 100
    foreach ($proc in @(Get-Process msrdc -ErrorAction SilentlyContinue)) {
        $wins = @()
        try { $wins = @([NativeWin]::ListWindows([uint32]$proc.Id)) } catch { continue }
        foreach ($wnd in $wins) {
            if ($null -eq $wnd -or -not $wnd.Visible) { continue }
            $r = New-Object NativeWin+RECT
            [void][NativeWin]::GetWindowRect($wnd.Hwnd, [ref]$r)
            if ([int]$r.Left -lt $threshold) { continue }
            $ex = [NativeWin]::GetWindowLong($wnd.Hwnd, -20)
            $ex = ($ex -bor 0x00040000) -band (-bnot 0x00000080)
            [void][NativeWin]::SetWindowLong($wnd.Hwnd, -20, $ex)
            [void][NativeWin]::SetWindowPos($wnd.Hwnd, [IntPtr]::Zero, 0, 0, [int]$wnd.Width, [int]$wnd.Height, 0x0010)
            Write-WinoidLog "restored orphan window: $($wnd.Title)"
        }
    }
}

# Status can say RUNNING while the activity manager no longer creates WSLg
# windows ("Sending reply failed"). Restarting the user session is the only
# reliable recovery; the manager then rebuilds wrappers from scratch.
function Restart-WaydroidSession {
    Write-WinoidLog 'restarting waydroid-session.service'
    try {
        $null = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', 'systemctl --user restart waydroid-session.service')) 30000
    } catch { }
    for ($i = 0; $i -lt 50; $i++) {
        Start-Sleep -Milliseconds 1000
        if ((Get-WaydroidContainerStatus) -eq 'RUNNING') { break }
    }
    if ($script:adb) { try { $script:adb.Dispose() } catch { }; $script:adb = $null }
    try { Initialize-Adb } catch { }
    Start-Sleep -Seconds 6
    Write-WinoidLog 'waydroid session restarted'
}

# Switch phone/tablet geometry of a running wrapper without reopening it.
function Set-LiveDisplayMode($w, [string]$mode) {
    if ($null -eq $w -or $w.Closed) { return }
    if (-not (Ensure-WaydroidAwake)) {
        Set-Footer 'Android не отвечает — не могу сменить режим.'
        return
    }
    try {
        if ($mode -eq 'phone') {
            Send-Android 'wm size 720x1280'
            Send-Android 'wm density 320'
            Set-Footer 'Режим: телефон (вертикально 720 × 1280).'
        } else {
            Send-Android 'wm size 1280x800'
            Send-Android 'wm density 160'
            Set-Footer 'Режим: планшет (горизонтально 1280 × 800).'
        }
    } catch {
        Write-WinoidLog ("ERROR display mode: " + $_.Exception.ToString())
        Set-Footer "Не удалось сменить режим: $($_.Exception.Message)"
    }
}

function Get-SelectedSize {
    switch ($sizeBox.SelectedIndex) {
        # Phone: narrow portrait surface with a phone-like density.
        1 { return [pscustomobject]@{ Width = 720; Height = 1280; Density = 320; Reset = $false } }
        # Tablet: wide landscape surface with a tablet-like density.
        2 { return [pscustomobject]@{ Width = 1280; Height = 800; Density = 160; Reset = $false } }
        3 { return [pscustomobject]@{ Width = 1280; Height = 800; Density = 0; Reset = $false } }
        4 { return [pscustomobject]@{ Width = 1600; Height = 900; Density = 0; Reset = $false } }
        5 { return [pscustomobject]@{ Width = 1920; Height = 1080; Density = 0; Reset = $false } }
        default { return [pscustomobject]@{ Width = 0; Height = 0; Density = 0; Reset = $true } }
    }
}

# --- ADB input ---

function Find-AdbExe {
    $candidates = New-Object System.Collections.ArrayList
    [void]$candidates.Add((Join-Path $PSScriptRoot 'platform-tools\adb.exe'))
    [void]$candidates.Add((Join-Path $script:configDir 'platform-tools\adb.exe'))
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }
    [void]$candidates.Add("$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe")
    [void]$candidates.Add('C:\platform-tools\adb.exe')
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Invoke-AdbCli {
    param([string[]]$Arguments, [int]$TimeoutMs = 6000)
    if (-not $script:adbPath) { return $null }
    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $script:adbPath
    foreach ($a in $Arguments) { [void]$psi.ArgumentList.Add($a) }
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
        try { [void]$p.WaitForExit(2000) } catch { }
    }
    # Never touch Result on a process that survived Kill: adb connect can
    # hang on a VPN-blackholed route and would freeze the UI thread.
    if (-not $p.HasExited) { return '' }
    return (($outTask.Result + ' ' + $errTask.Result) -replace '\s+', ' ').Trim()
}

function Initialize-Adb {
    if ($script:adb -and $script:adb.Running) { return }
    if (-not $script:adbPath) { $script:adbPath = Find-AdbExe }
    $script:adbViaWsl = $false

    # Prefer the WSL-side adb server: it sees the Waydroid container even
    # when a Windows VPN blackholes 192.168.240.0/24.
    $r = $null
    try {
        $r = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'get-state')) 8000
    } catch { }
    if ($r -and $r.Out -match 'device') {
        $prefix = New-Object System.Collections.ArrayList
        if (-not [string]::IsNullOrWhiteSpace($script:wslDistro)) { [void]$prefix.Add('-d'); [void]$prefix.Add($script:wslDistro) }
        [void]$prefix.Add('--'); [void]$prefix.Add('adb')
        try {
            $script:adb = [AdbShell]::new($script:wsl, $script:adbSerial, [string[]]$prefix)
            $script:adbViaWsl = $true
        } catch { $script:adb = $null }
        return
    }

    if (-not $script:adbPath) { return }
    if ((Get-Date) -lt $script:adbNextTry) { return }
    $out = Invoke-AdbCli @('connect', $script:adbSerial)
    if ($out -match 'connected to|already connected') {
        try { $script:adb = [AdbShell]::new($script:adbPath, $script:adbSerial) } catch { $script:adb = $null }
    } else {
        $script:adbNextTry = (Get-Date).AddSeconds(60)
    }
}

function Send-Android([string]$cmd) {
    if ($null -eq $script:adb -or -not $script:adb.Running) {
        Initialize-Adb
    }
    if ($null -eq $script:adb -or -not $script:adb.Running) { return }
    try { $script:adb.Send($cmd) } catch { }
}

# Back only reaches the app that owns Android's input focus. Launching a
# second app can steal that focus while the Settings wrapper stays visible,
# and ADB key events go to the focused window, not to the one on screen.
# Tapping the freeform caption's empty middle focuses Settings without
# touching app content; then the plain Back key reaches the right window.
function Send-AndroidBack($w) {
    if ($null -eq $w) { return }
    if ($w.Package -eq 'com.android.settings') {
        # Back on the root list leaves Settings; close the wrapper instead of
        # backgrounding the app behind an orphaned window showing a still frame.
        if ([string]$w.SettingsTop -match '\.Settings$') {
            try { Write-WinoidLog 'nav back closes settings' } catch { }
            try { $w.Window.Close() } catch { }
            return
        }
        $bx = [int]$w.FrameL + [int]($w.FrameW / 2)
        $by = [int]$w.FrameT + 22
        Send-Android "input tap $bx $by"
        Start-Sleep -Milliseconds 180
        Send-Android 'input keyevent 4'
        $w.SettingsTopDue = [DateTime]::UtcNow.AddMilliseconds(1200)
        try { Write-WinoidLog "nav back focus $bx,$by + keyevent" } catch { }
        return
    }
    Send-Android 'input keyevent 4'
}

function Get-AndroidTopActivity {
    if ($null -eq $script:adb -or -not $script:adb.Running) { Initialize-Adb }
    if ($null -eq $script:adb -or -not $script:adb.Running) { return '' }
    try {
        $text = [string]$script:adb.SendQuery('dumpsys activity activities | grep topResumedActivity | head -1', 2500)
    } catch { return '' }
    if ($text -match '([\w\.]+/[\w\.\$]+)') { return $matches[1] }
    return ''
}

# Settings keeps the previous activity alive below the current one. After
# Back the old sub-surface can stay on top of the list with a stale picture,
# so Sync-SettingsSurface prefers the root window when Android reports it.

# Ask Android which activity is on top and remember it; the frame timer then
# calls Sync-SettingsSurface, which picks the matching WSLg surface. Window
# z-order alone lies after Back: the finished detail surface can stay above
# the list with a frozen picture.
function Update-SettingsActivity($w) {
    if ($null -eq $w -or $w.Closed -or $w.Package -ne 'com.android.settings') { return }
    $top = Get-AndroidTopActivity
    if ([string]::IsNullOrWhiteSpace($top)) { return }
    $w.SettingsTop = $top
    try { Write-WinoidLog "settings top $top" } catch { }
    $w.SettingsSyncAt = [DateTime]::MinValue
}

# --- wrappers ---

function Find-WrapperByPackage([string]$package) {
    foreach ($w in @($script:wrappers)) {
        if (-not $w.Closed -and $w.Package -eq $package) { return $w }
    }
    return $null
}

function Map-WrapperPoint($w, $pos) {
    $cw = $w.Image.ActualWidth; $ch = $w.Image.ActualHeight
    if ($cw -le 0 -or $ch -le 0) { return $null }
    if ([bool]$script:stretchFill) {
        $fx = $pos.X / ([double]$cw / $w.SrcW)
        $fy = $pos.Y / ([double]$ch / $w.SrcH)
    } else {
        $scale = [math]::Min($cw / $w.SrcW, $ch / $w.SrcH)
        if ($scale -le 0) { return $null }
        $ox = ($cw - $w.SrcW * $scale) / 2
        $oy = ($ch - $w.SrcH * $scale) / 2
        $fx = ($pos.X - $ox) / $scale
        $fy = ($pos.Y - $oy) / $scale
        # Taps in the black letterbox map to the nearest content edge.
        $fx = [Math]::Max(0, [Math]::Min([double]($w.SrcW - 1), $fx))
        $fy = [Math]::Max(0, [Math]::Min([double]($w.SrcH - 1), $fy))
    }
    $sx = [int][math]::Floor($fx)
    $sy = [int][math]::Floor($fy)
    foreach ($pane in @($w.Panes)) {
        $x0 = [int]$pane.VX; $y0 = [int]$pane.VY
        $x1 = $x0 + [int]$pane.W; $y1 = $y0 + [int]$pane.VisH
        if ($sx -lt $x0 -or $sx -ge $x1 -or $sy -lt $y0 -or $sy -ge $y1) { continue }
        $al = $pane.PSObject.Properties['AndroidL']
        $at = $pane.PSObject.Properties['AndroidT']
        if ($null -ne $al -and $null -ne $at) {
            $tx = [int]$al.Value
            $ty = [int]$at.Value
            $tx = $tx + $sx - $x0
            $ty = $ty + $sy - $y0
            $cp = $pane.PSObject.Properties['CaptionInset']
            if ($null -ne $cp) { $ty += [int]$cp.Value }
            $ep = $pane.PSObject.Properties['EdgeCrop']
            if ($null -ne $ep) { $tx += [int]$ep.Value; $ty += [int]$ep.Value }
            return @($tx, $ty)
        }
        $cp2 = $pane.PSObject.Properties['CaptionInset']
        $ep2 = $pane.PSObject.Properties['EdgeCrop']
        $adjY = $sy
        $adjX = $sx
        if ($null -ne $cp2) { $adjY += [int]$cp2.Value }
        if ($null -ne $ep2) { $adjX += [int]$ep2.Value; $adjY += [int]$ep2.Value }
        return @($adjX, $adjY)
    }
    return $null
}

function Get-AppDisplayName($app) {
    if ($null -eq $app) { return '' }
    if ($app.Package -eq 'com.android.settings') { return 'Настройки Android' }
    try {
        if ($app.PSObject.Properties['DisplayName'] -and -not [string]::IsNullOrWhiteSpace($app.DisplayName)) {
            return [string]$app.DisplayName
        }
    } catch { }
    return [string]$app.Name
}

# Collects the Windows windows that together make up one Android app.
# Android Settings uses two side-by-side task fragments on a large screen:
# a list and a detail pane. Both are separate WSLg windows, so they have to
# be captured and shown as one virtual screen.
function Get-AppPanes($app, [IntPtr]$source) {
    $cr = New-Object NativeWin+RECT
    [void][NativeWin]::GetClientRect($source, [ref]$cr)
    $pw = [Math]::Max(1, $cr.Right)
    $ph = [Math]::Max(1, $cr.Bottom)
    $wr = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($source, [ref]$wr)

    $procId = [uint32]0
    [void][NativeWin]::GetWindowThreadProcessId($source, [ref]$procId)
    $wins = @()
    try { $wins = @([NativeWin]::ListWindows($procId)) } catch { }

    # The Android navigation bar is a separate bottom strip. Its height is
    # cropped from the app panes and replaced by Winoid's own navigation bar.
    $navInset = 0
    $displayW = 0
    foreach ($wnd in $wins) {
        if (-not $wnd.Visible) { continue }
        $ww = $wnd.Width; $wh = $wnd.Height
        if ($ww -lt 200 -or $wh -lt 20 -or $wh -gt 140) { continue }
        if ([math]::Abs($wnd.Bottom - $ph) -gt 8) { continue }
        if ($ww -lt $pw * 0.9) { continue }
        $inset = $ph - $wnd.Top
        if ($inset -ge 20 -and $inset -le 140 -and $inset -gt $navInset) { $navInset = $inset }
        if ($ww -gt $displayW) { $displayW = $ww }
    }
    # Some games do not expose a separate nav-bar window; their surface still
    # ends with a dark decoration strip. Use a small fallback crop so it does
    # not end up as a white-bordered black band under the game.
    if ($navInset -eq 0 -and [int]$script:fallbackNavInset -gt 0) { $navInset = [int]$script:fallbackNavInset }

    $panes = New-Object System.Collections.ArrayList
    [void]$panes.Add([pscustomobject]@{ Source = $source; Left = $wr.Left; Top = $wr.Top; W = $pw; H = $ph })

    # Settings opens every sub-screen as a new Android activity in the same
    # freeform frame. WSLg gives each activity its own overlapping surface
    # instead of a side-by-side list/detail pair, so the wrapper follows the
    # topmost surface at this frame (see Sync-SettingsSurface). Capturing both
    # at once would freeze on the old list while the detail pane is showing.

    $minLeft = $wr.Left; $minTop = $wr.Top
    $maxRight = $wr.Left + $pw; $maxBottom = $wr.Top + $ph
    foreach ($p in $panes) {
        if ($p.Left -lt $minLeft) { $minLeft = $p.Left }
        if ($p.Top -lt $minTop) { $minTop = $p.Top }
        if (($p.Left + $p.W) -gt $maxRight) { $maxRight = $p.Left + $p.W }
        if (($p.Top + $p.H) -gt $maxBottom) { $maxBottom = $p.Top + $p.H }
    }
    $height = $maxBottom - $minTop - $navInset
    if ($height -lt 100) { $height = $maxBottom - $minTop; $navInset = 0 }

    return [pscustomobject]@{
        Panes = @($panes)
        Windows = $wins
        RootOwner = [NativeWin]::GetAncestor($source, 3)
        NavInset = $navInset
        MinLeft = $minLeft
        MinTop = $minTop
        Width = $maxRight - $minLeft
        Height = $height
    }
}

# Returns the Android freeform frames (window bounds) of a package. The
# WSLg window shows the app surface, but ADB input is whole-display input:
# without the frame origin every tap lands near the top-left of Android.
function Get-AndroidWindowFrames([string]$package) {
    if ([string]::IsNullOrWhiteSpace($package)) { return @() }
    $text = ''
    try {
        if ($script:adbViaWsl) {
            $r = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'shell', 'dumpsys', 'window', 'windows')) 9000
            if ($r -and $r.Code -eq 0) { $text = [string]$r.Out }
        }
    } catch { }
    if ([string]::IsNullOrWhiteSpace($text) -and $script:adbPath) {
        try { $text = [string](Invoke-AdbCli @('-s', $script:adbSerial, 'shell', 'dumpsys', 'window', 'windows') 9000) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }

    $frames = New-Object System.Collections.ArrayList
    foreach ($block in [regex]::Split($text, '(?m)^\s*Window #')) {
        if ($block -notmatch 'u\d+\s+([^\s/]+)/') { continue }
        if ($matches[1] -ne $package) { continue }
        $fm = [regex]::Match($block, 'frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]')
        if (-not $fm.Success) { continue }
        $l = [int]$fm.Groups[1].Value; $t = [int]$fm.Groups[2].Value
        $r = [int]$fm.Groups[3].Value; $b = [int]$fm.Groups[4].Value
        if ($r -le $l -or $b -le $t) { continue }
        [void]$frames.Add([pscustomobject]@{ L = $l; T = $t; W = $r - $l; H = $b - $t })
    }
    return @($frames)
}

# Matches each captured pane with its Android window frame. A pane can be
# exactly the size of its frame (it contains the freeform title bar) or
# short by that title bar (immersive windows). In both cases the app starts
# just below the title bar, so a shorter pane is shifted down by the delta.
function Set-PaneAndroidFrames($panes, $frames) {
    foreach ($pane in @($panes)) {
        $pw = [int]$pane.W; $ph = [int]$pane.H
        $best = $null; $bestDelta = 9999
        foreach ($f in @($frames)) {
            $dw = $pw - [int]$f.W
            $dh = $ph - [int]$f.H
            # WSLg adds a 12 px shadow around the app surface; immersive
            # windows omit the 48 px freeform title bar. Both stay within
            # these bounds, while unrelated windows are far larger.
            if ([math]::Abs($dw) -gt 64 -or [math]::Abs($dh) -gt 96) { continue }
            $delta = [math]::Abs($dw) + [math]::Abs($dh)
            if ($delta -lt $bestDelta) { $best = $f; $bestDelta = $delta }
        }
        if ($null -eq $best) { continue }

        $dw = $pw - [int]$best.W; $dh = $ph - [int]$best.H
        $ax = [int]$best.L; $ay = [int]$best.T
        if ($dw -gt 0) { $ax -= [int][math]::Round($dw / 2) }
        elseif ($dw -lt 0) { $ax += -$dw }
        if ($dh -gt 0) { $ay -= [int][math]::Round($dh / 2) }
        elseif ($dh -lt 0) { $ay += -$dh }

        $pane | Add-Member -NotePropertyName AndroidL -NotePropertyValue $ax -Force
        $pane | Add-Member -NotePropertyName AndroidT -NotePropertyValue $ay -Force
        # A pane as tall as the Android frame contains the freeform title bar
        # (back arrow + window buttons). An immersive pane is shorter by that
        # bar, so there is nothing to hide there.
        $titleBar = if ($dh -ge -16) { [int]$script:captionHeightPx } else { 0 }
        $pane | Add-Member -NotePropertyName TitleBar -NotePropertyValue $titleBar -Force
    }
}

# WSLg sometimes stacks an empty black sub-surface above a real Settings
# window. PrintWindow cannot tell it from content, so sample a frame before
# switching: a nearly black overlay must not replace the visible list.
function Get-WindowLuma([IntPtr]$hwnd, [int]$ww, [int]$hh) {
    $g = $null
    try {
        $g = [FrameGrabber]::new([Math]::Max(1, $ww), [Math]::Max(1, $hh))
        if (-not $g.Capture($hwnd)) { return -1 }
        return $g.MeanLuma()
    } catch { return -1 }
    finally { if ($null -ne $g) { try { $g.Dispose() } catch { } } }
}

# Locate the Android content rectangle inside a WSLg surface. Returns
# @(offsetX, offsetY) or $null when the capture failed.
function Get-WindowContentOffset([IntPtr]$hwnd, [int]$ww, [int]$hh, [int]$cw, [int]$ch) {
    $g = $null
    try {
        $g = [FrameGrabber]::new([Math]::Max(1, $ww), [Math]::Max(1, $hh))
        if (-not $g.Capture($hwnd)) { return $null }
        $ox = 0; $oy = 0
        if ($g.FindContentOffset($cw, $ch, [ref]$ox, [ref]$oy)) { return @([int]$ox, [int]$oy) }
        return $null
    } catch { return $null }
    finally { if ($null -ne $g) { try { $g.Dispose() } catch { } } }
}

# Settings switches activities inside one freeform frame (list -> "Network",
# "Apps", ...). Each activity is a separate WSLg surface stacked at the same
# place, and the previous one stays alive underneath. Follow the topmost
# surface so taps, Back and the captured image all describe the screen the
# user is actually looking at instead of freezing on the first list pane.
function Sync-SettingsSurface($w) {
    if ($null -eq $w -or $w.Closed -or $w.Package -ne 'com.android.settings') { return }
    $tw = [int]$w.SettingsW; $th = [int]$w.SettingsH
    if ($tw -lt 100 -or $th -lt 100) { return }

    $anchor = $null
    foreach ($p in @($w.Panes)) {
        if ($null -ne $p -and [NativeWin]::IsWindow($p.Source)) { $anchor = $p.Source; break }
    }
    if ($null -eq $anchor) { return }
    $procId = [uint32]0
    [void][NativeWin]::GetWindowThreadProcessId($anchor, [ref]$procId)
    $wins = @()
    try { $wins = @([NativeWin]::ListWindows($procId)) } catch { return }
    # msrdc hosts every WSLg app window in one process, so a size filter
    # alone would let another app's surface (a calculator is also 464x824)
    # hijack the Settings wrapper. Sub-surfaces are owned by their app's
    # base window; keep only the Settings root-owner family.
    $ownerRoot = [NativeWin]::GetAncestor($anchor, 3)

    # EnumWindows returns top-level windows top-to-bottom.
    $candidates = @()
    foreach ($wnd in $wins) {
        if (-not $wnd.Visible) { continue }
        if ([NativeWin]::GetAncestor($wnd.Hwnd, 3) -ne $ownerRoot) { continue }
        if ($wnd.Width -lt 240 -or $wnd.Height -lt 240) { continue }
        if ([math]::Abs($wnd.Width - $tw) -gt 48 -or [math]::Abs($wnd.Height - $th) -gt 48) { continue }
        $candidates += $wnd
    }
    if ($candidates.Count -eq 0) { return }

    $cur = $null
    foreach ($p in @($w.Panes)) { if ($null -ne $p) { $cur = $p; break } }
    $topAct = ''
    try { $topAct = [string]$w.SettingsTop } catch { }
    $rootTop = ($topAct -match 'com\.android\.settings/\.Settings$')
    # Ask Android for the real top activity when our cached value is empty.
    # Throttled: dumpsys is too heavy for every 350 ms frame.
    if ([string]::IsNullOrWhiteSpace($topAct)) {
        $probeAt = $null
        try { $probeAt = [DateTime]$w.SettingsTopProbeAt } catch { }
        if ($null -eq $probeAt -or ([DateTime]::UtcNow - $probeAt).TotalMilliseconds -ge 1500) {
            try { $w.SettingsTopProbeAt = [DateTime]::UtcNow } catch { }
            $live = Get-AndroidTopActivity
            if (-not [string]::IsNullOrWhiteSpace($live)) {
                $topAct = $live
                try { $w.SettingsTop = $live } catch { }
                $rootTop = ($live -match 'com\.android\.settings/\.Settings$')
            }
        }
    }

    $active = $candidates[0]
    if ($rootTop) {
        # Back returned to the root list. The finished detail surface often
        # stays on top with a frozen picture, so prefer the base window.
        foreach ($cand in $candidates) {
            if ($cand.Title -notmatch 'sub-surface') { $active = $cand; break }
        }
    } elseif ([string]::IsNullOrWhiteSpace($topAct) -and ($null -eq $cur -or $cur.Source -ne $active.Hwnd)) {
        # Top activity unknown (fresh launch): a blank overlay sub-surface
        # must not replace the visible list.
        $topLuma = Get-WindowLuma $active.Hwnd $active.Width $active.Height
        if ($topLuma -lt 0.5) {
            foreach ($cand in $candidates) {
                if ($cand.Title -notmatch 'sub-surface') { $active = $cand; break }
            }
        }
    }
    $parkBase = [System.Windows.Forms.SystemInformation]::VirtualScreen.Right + 200
    if ($null -ne $w.PSObject.Properties['ParkBase']) { $parkBase = [int]$w.ParkBase }

    # Android sets a 12 px surface inset on each side of the Settings base
    # window. If WSLg made it content-sized, grow it back so the full 464 px
    # content is rendered instead of clipped at the right edge. Do this even
    # when the wrapper already shows that window, hence the size check below.
    $isBaseWin = ([NativeWin]::GetWindow($active.Hwnd, 4) -eq [IntPtr]::Zero)
    if ($isBaseWin -and ([int]$active.Width -lt [int]$w.FrameW + 16 -or [int]$active.Height -lt [int]$w.FrameH + 16)) {
        $targetW = [int]$w.FrameW + 24; $targetH = [int]$w.FrameH + 24
        [void][NativeWin]::SetWindowPos($active.Hwnd, [IntPtr]::Zero, $parkBase, 0, $targetW, $targetH, 0x0016)
        [System.Threading.Thread]::Sleep(350)
        $active | Add-Member -NotePropertyName Width -NotePropertyValue $targetW -Force
        $active | Add-Member -NotePropertyName Height -NotePropertyValue $targetH -Force
    }
    $needSwitch = ($null -eq $cur -or $cur.Source -ne $active.Hwnd -or [int]$cur.W -ne [int]$active.Width -or [int]$cur.H -ne [int]$active.Height)
    if ($needSwitch) {
        try {
            $diag = @($candidates | ForEach-Object {
                $name = $_.Title
                if ($name.Length -gt 28) { $name = $name.Substring(0, 28) }
                "$('0x{0:X}' -f $_.Hwnd.ToInt64())=$name/$($_.Width)x$($_.Height)"
            }) -join '; '
            Write-WinoidLog ("settings candidates: $diag top=$topAct")
        } catch { }
    }

    # Park every other app-sized Settings surface (the old activity stays
    # alive underneath the new one and must not float over the desktop).
    foreach ($wnd in $wins) {
        if ($null -eq $wnd -or -not $wnd.Visible -or $wnd.Hwnd -eq $active.Hwnd) { continue }
        if ([NativeWin]::GetAncestor($wnd.Hwnd, 3) -ne $ownerRoot) { continue }
        if ($null -ne $cur -and $wnd.Hwnd -eq $cur.Source) { continue }
        if ($wnd.Width -lt 240 -or $wnd.Height -lt 240) { continue }
        if ([math]::Abs($wnd.Width - $tw) -gt 48 -or [math]::Abs($wnd.Height - $th) -gt 48) { continue }
        $known = $false
        foreach ($p in @($w.Parked)) { if ($null -ne $p -and $p.Source -eq $wnd.Hwnd) { $known = $true; break } }
        if ($known) { continue }
        $ex = [NativeWin]::GetWindowLong($wnd.Hwnd, -20)
        $rect = New-Object NativeWin+RECT
        [void][NativeWin]::GetWindowRect($wnd.Hwnd, [ref]$rect)
        $parkExp = (($ex -bor 0x00000080) -band (-bnot 0x00040000))
        [void][NativeWin]::SetWindowLong($wnd.Hwnd, -20, $parkExp)
        $parkX = $parkBase + [Math]::Max(0, $wnd.Left - [int]$w.Left)
        [void][NativeWin]::SetWindowPos($wnd.Hwnd, [IntPtr]::Zero, $parkX, 0, [int]$wnd.Width, [int]$wnd.Height, 0x0010)
        [void]$w.Parked.Add([pscustomobject]@{
            Source = $wnd.Hwnd
            OrigExStyle = (($ex -bor 0x00040000) -band (-bnot 0x00000080))
            OrigRect = $rect
            WasZoomed = $false
            ParkX = $parkX
            ParkY = 0
            W = [int]$wnd.Width
            H = [int]$wnd.Height
        })
    }

    if (-not $needSwitch) { return }

    if ($null -ne $cur) {
        try { $cur.Grab.Dispose() } catch { }
        if ([NativeWin]::IsWindow($cur.Source)) {
            [void]$w.Parked.Add([pscustomobject]@{
                Source = $cur.Source
                OrigExStyle = $cur.OrigExStyle
                OrigRect = $cur.OrigRect
                WasZoomed = $cur.WasZoomed
                ParkX = $cur.ParkX
                ParkY = $cur.ParkY
                W = $cur.W
                H = $cur.H
            })
        }
    }

    $ex = [NativeWin]::GetWindowLong($active.Hwnd, -20)
    $rect = New-Object NativeWin+RECT
    [void][NativeWin]::GetWindowRect($active.Hwnd, [ref]$rect)
    $zoom = [NativeWin]::IsZoomed($active.Hwnd)
    if ($zoom) {
        [void][NativeWin]::ShowWindow($active.Hwnd, 9)
        for ($i = 0; $i -lt 20 -and [NativeWin]::IsZoomed($active.Hwnd); $i++) { [System.Threading.Thread]::Sleep(25) }
    }
    $parkedEx = (($ex -bor 0x00000080) -band (-bnot 0x00040000))
    [void][NativeWin]::SetWindowLong($active.Hwnd, -20, $parkedEx)
    # Android sets a 12 px surface inset on each side of the Settings base
    # window. If WSLg made it content-sized, grow it back so the full 464 px
    # content is rendered instead of clipped at the right edge.
    $parkW = [int]$active.Width; $parkH = [int]$active.Height
    $isBaseWin = ([NativeWin]::GetWindow($active.Hwnd, 4) -eq [IntPtr]::Zero)
    if ($isBaseWin -and ($parkW -lt [int]$w.FrameW + 16 -or $parkH -lt [int]$w.FrameH + 16)) {
        $parkW = [int]$w.FrameW + 24; $parkH = [int]$w.FrameH + 24
    }
    [void][NativeWin]::SetWindowPos($active.Hwnd, [IntPtr]::Zero, $parkBase, 0, $parkW, $parkH, 0x0010)
    if ($parkW -ne [int]$active.Width -or $parkH -ne [int]$active.Height) {
        [System.Threading.Thread]::Sleep(350)
        $active | Add-Member -NotePropertyName Width -NotePropertyValue $parkW -Force
        $active | Add-Member -NotePropertyName Height -NotePropertyValue $parkH -Force
    }

    # The Android frame keeps its origin. Find the content rectangle inside
    # the WSLg surface so shadow margins never leak into the wrapper image.
    $off = Get-WindowContentOffset $active.Hwnd ([int]$active.Width) ([int]$active.Height) ([int]$w.FrameW) ([int]$w.FrameH)
    $cropX = 0; $cropY = 0
    if ($null -ne $off) {
        $cropX = [int]$off[0]; $cropY = [int]$off[1]
    } else {
        if ([int]$active.Width -ge [int]$w.FrameW + 8) { $cropX = [int][Math]::Round(([int]$active.Width - [int]$w.FrameW) / 2) }
        if ([int]$active.Height -ge [int]$w.FrameH + 8) { $cropY = [int][Math]::Round(([int]$active.Height - [int]$w.FrameH) / 2) }
    }
    $al = [int]$w.FrameL; $at = [int]$w.FrameT

    $pane = [pscustomobject]@{ Source = $active.Hwnd; Left = 0; Top = 0; W = [int]$active.Width; H = [int]$active.Height }
    $pane | Add-Member -NotePropertyName CropX -NotePropertyValue $cropX -Force
    $pane | Add-Member -NotePropertyName CropY -NotePropertyValue $cropY -Force
    $pane | Add-Member -NotePropertyName VX -NotePropertyValue 0 -Force
    $pane | Add-Member -NotePropertyName VY -NotePropertyValue 0 -Force
    $pane | Add-Member -NotePropertyName VisH -NotePropertyValue ([Math]::Min([int]$active.Height, [int]$w.SrcH)) -Force
    $pane | Add-Member -NotePropertyName OrigExStyle -NotePropertyValue (($ex -bor 0x00040000) -band (-bnot 0x00000080)) -Force
    $pane | Add-Member -NotePropertyName OrigRect -NotePropertyValue $rect -Force
    $pane | Add-Member -NotePropertyName WasZoomed -NotePropertyValue $zoom -Force
    $pane | Add-Member -NotePropertyName Grab -NotePropertyValue ([FrameGrabber]::new([int]$active.Width, [int]$active.Height)) -Force
    $pane | Add-Member -NotePropertyName ParkX -NotePropertyValue $parkBase -Force
    $pane | Add-Member -NotePropertyName ParkY -NotePropertyValue 0 -Force
    $pane | Add-Member -NotePropertyName AndroidL -NotePropertyValue $al -Force
    $pane | Add-Member -NotePropertyName AndroidT -NotePropertyValue $at -Force

    $w.Panes = @($pane)
    $w.Source = $active.Hwnd
    try { Write-WinoidLog ("settings surface $('0x{0:X}' -f $active.Hwnd.ToInt64()) $($active.Width)x$($active.Height)") } catch { }
}

function Restore-Source($w) {
    foreach ($pane in (@($w.Panes) + @($w.Parked))) {
        if ($null -eq $pane -or -not [NativeWin]::IsWindow($pane.Source)) { continue }
        [void][NativeWin]::SetWindowLong($pane.Source, -20, $pane.OrigExStyle)
        $r = $pane.OrigRect
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $x = $r.Left; $y = $r.Top
        if ($x -ge $wa.Right -or $y -ge $wa.Bottom) { $x = 0; $y = 0 }
        [void][NativeWin]::SetWindowPos($pane.Source, [IntPtr]::Zero, $x, $y, [Math]::Max(320, $r.Right - $r.Left), [Math]::Max(240, $r.Bottom - $r.Top), 0x0010)
        if ($pane.WasZoomed) { [void][NativeWin]::ShowWindow($pane.Source, 3) }
    }
}

function Remove-Wrapper($w, [bool]$closeSource) {
    if ($null -eq $w -or $w.Closed) { return }
    $w.Closed = $true
    foreach ($pane in @($w.Panes)) {
        try { $pane.Grab.Dispose() } catch { }
    }
    try { $script:wrapByImage.Remove($w.Image) } catch { }
    try { $script:wrapByWindow.Remove($w.Window) } catch { }
    try { [void]$script:wrappers.Remove($w) } catch { }
    if ($closeSource) {
        foreach ($pane in @($w.Panes)) {
            if ($null -ne $pane -and [NativeWin]::IsWindow($pane.Source)) {
                [void][NativeWin]::PostMessage($pane.Source, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        }
        # Settings keeps the previous activity alive under the current one.
        # Close those parked surfaces too, otherwise they linger off-screen.
        foreach ($extra in @($w.Parked)) {
            if ($null -ne $extra -and [NativeWin]::IsWindow($extra.Source)) {
                [void][NativeWin]::PostMessage($extra.Source, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            }
        }
    }
    try { $w.Window.Close() } catch { }
}

function Focus-Wrapper($w) {
    if ($null -eq $w -or $w.Closed) { return }
    try {
        if ($w.Window.WindowState -eq 'Minimized') { $w.Window.WindowState = 'Normal' }
        $w.Window.Activate()
        [NativeWin]::ForceForeground([System.Windows.Interop.WindowInteropHelper]::new($w.Window).Handle)
    } catch { }
}

function New-AppWrapper($app, [IntPtr]$source, $size) {
    foreach ($old in @($script:wrappers)) {
        if (-not $old.Closed -and $old.Source -eq $source) { Focus-Wrapper $old; return $old }
    }

    $spec = Get-AppPanes $app $source
    $panes = @($spec.Panes)
    $srcW = [int]$spec.Width
    $srcH = [int]$spec.Height
    if ($panes.Count -eq 0 -or $srcW -lt 100 -or $srcH -lt 60) { return $null }
    $displayName = Get-AppDisplayName $app

    # ADB input is display-wide, while the captured panes start at their
    # Android freeform frame. Record each pane's frame origin so taps are
    # translated to the right place instead of the top-left of Android.
    $androidFrames = @(Get-AndroidWindowFrames $app.Package)
    Set-PaneAndroidFrames $panes $androidFrames
    # Settings is one Android window whose height is the freeform frame, not
    # the WSLg shadowed surface. Use the frame size for the wrapper so the
    # window keeps phone-like proportions instead of a 488x848 shadow box.
    $settingsFrame = $null
    if ($app.Package -eq 'com.android.settings' -and $androidFrames.Count -gt 0) {
        $frameDelta = 99999
        foreach ($f in $androidFrames) {
            $d = [math]::Abs($srcW - [int]$f.W) + [math]::Abs($srcH - [int]$f.H)
            if ($d -lt $frameDelta) { $settingsFrame = $f; $frameDelta = $d }
        }
        if ($null -ne $settingsFrame -and [int]$settingsFrame.W -gt 100 -and [int]$settingsFrame.H -gt 100) {
            $srcW = [int]$settingsFrame.W
            $srcH = [int]$settingsFrame.H
        }
    }
    foreach ($pane in $panes) {
        $pane | Add-Member -NotePropertyName CropX -NotePropertyValue 0 -Force
        $pane | Add-Member -NotePropertyName CropY -NotePropertyValue 0 -Force
    }
    # WSLg often adds a translucent shadow around a surface, but it is not
    # always centered: unparked windows sometimes keep all 24 px on the
    # right/bottom. Locate the Android content rectangle inside the capture
    # instead of assuming a fixed margin.
    if ($app.Package -eq 'com.android.settings' -and $panes.Count -gt 0 -and $null -ne $settingsFrame) {
        $p0 = $panes[0]
        # Android asks for a 464x824 content window and a 12 px surface inset
        # on every side. WSLg occasionally creates just the content-sized
        # window and clips the right edge; restore the full surface first.
        $isBase = ([NativeWin]::GetWindow($p0.Source, 4) -eq [IntPtr]::Zero)
        try { Write-WinoidLog "settings create base=$isBase pane=$($p0.W)x$($p0.H) src=${srcW}x${srcH}" } catch { }
        if ($isBase -and ([int]$p0.W -lt $srcW + 16 -or [int]$p0.H -lt $srcH + 16)) {
            [void][NativeWin]::SetWindowPos($p0.Source, [IntPtr]::Zero, 0, 0, $srcW + 24, $srcH + 24, 0x0006)
            [System.Threading.Thread]::Sleep(350)
            $cr2 = New-Object NativeWin+RECT
            [void][NativeWin]::GetClientRect($p0.Source, [ref]$cr2)
            if ($cr2.Right -ge $srcW) { $p0.W = [int]$cr2.Right }
            if ($cr2.Bottom -ge $srcH) { $p0.H = [int]$cr2.Bottom }
        }
        $off = $null
        if ([int]$p0.W -ge $srcW -and [int]$p0.H -ge $srcH) {
            $off = Get-WindowContentOffset $p0.Source ([int]$p0.W) ([int]$p0.H) $srcW $srcH
        }
        if ($null -ne $off) {
            $p0.CropX = [int]$off[0]
            $p0.CropY = [int]$off[1]
        } else {
            if ([int]$p0.W -ge $srcW + 8) { $p0.CropX = [int][Math]::Round(([int]$p0.W - $srcW) / 2) }
            if ([int]$p0.H -ge $srcH + 8) { $p0.CropY = [int][Math]::Round(([int]$p0.H - $srcH) / 2) }
        }
        $p0 | Add-Member -NotePropertyName AndroidL -NotePropertyValue ([int]$settingsFrame.L) -Force
        $p0 | Add-Member -NotePropertyName AndroidT -NotePropertyValue ([int]$settingsFrame.T) -Force
    }
    try {
        $paneInfo = @($panes | ForEach-Object {
            $al = $_.PSObject.Properties['AndroidL']; $at = $_.PSObject.Properties['AndroidT']
            if ($null -ne $al -and $null -ne $at) { "$([int]$_.W)x$([int]$_.H)@$($al.Value),$($at.Value)" }
            else { "$([int]$_.W)x$([int]$_.H)@?" }
        }) -join ' '
    } catch { }

    # WSLg splits an Android window into a top-level frame and one or more
    # sub-surface windows (content, navigation bar, dialogs). Only the panes
    # are captured; every other surface owned by the same top-level window is
    # parked off-screen too, otherwise it stays on top of the Winoid wrapper.
    $paneSources = New-Object 'System.Collections.Generic.HashSet[System.IntPtr]'
    foreach ($pane in $panes) { [void]$paneSources.Add($pane.Source) }
    $parked = New-Object System.Collections.ArrayList

    # Park outside the whole virtual desktop. 3000 px from the primary
    # origin is still a real position when a second monitor sits to the
    # left (negative coordinates) or the desktop is wider than 3000 px.
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $parkBase = $vs.Right + 200
    foreach ($wnd in @($spec.Windows)) {
        if ($null -eq $wnd -or -not $wnd.Visible) { continue }
        if ($wnd.RootOwner -ne $spec.RootOwner) { continue }
        if ($paneSources.Contains($wnd.Hwnd)) { continue }
        if ($wnd.Width -lt 20 -or $wnd.Height -lt 20) { continue }
        $extraEx = [NativeWin]::GetWindowLong($wnd.Hwnd, -20)
        $extraZoomed = [NativeWin]::IsZoomed($wnd.Hwnd)
        $extraRect = New-Object NativeWin+RECT
        [void][NativeWin]::GetWindowRect($wnd.Hwnd, [ref]$extraRect)
        if ($extraZoomed) {
            [void][NativeWin]::ShowWindow($wnd.Hwnd, 9)
            for ($i = 0; $i -lt 20 -and [NativeWin]::IsZoomed($wnd.Hwnd); $i++) {
                [System.Threading.Thread]::Sleep(25)
            }
        }
        $extraParkedEx = (($extraEx -bor 0x00000080) -band (-bnot 0x00040000))
        [void][NativeWin]::SetWindowLong($wnd.Hwnd, -20, $extraParkedEx)
        $parkX = $parkBase + [Math]::Max(0, $wnd.Left - $spec.MinLeft)
        [void][NativeWin]::SetWindowPos($wnd.Hwnd, [IntPtr]::Zero, $parkX, 0, [int]$wnd.Width, [int]$wnd.Height, 0x0010)
        [void]$parked.Add([pscustomobject]@{
            Source = $wnd.Hwnd
            OrigExStyle = (($extraEx -bor 0x00040000) -band (-bnot 0x00000080))
            OrigRect = $extraRect
            WasZoomed = $extraZoomed
            ParkX = $parkX
            ParkY = 0
            W = [int]$wnd.Width
            H = [int]$wnd.Height
        })
    }

    # Remember where every pane was and park all of them off-screen. The
    # Android nav bar strip is cropped from the captured image, so each
    # pane keeps its full height while only the visible part is shown.
    foreach ($pane in $panes) {
        $paneOrigEx = [NativeWin]::GetWindowLong($pane.Source, -20)
        $paneZoomed = [NativeWin]::IsZoomed($pane.Source)
        $paneRect = New-Object NativeWin+RECT
        [void][NativeWin]::GetWindowRect($pane.Source, [ref]$paneRect)
        $vx = [int]($pane.Left - $spec.MinLeft)
        $vy = [int]($pane.Top - $spec.MinTop)
        $visH = [int]($pane.H - $spec.NavInset)
        if ($visH -gt ($srcH - $vy)) { $visH = $srcH - $vy }
        if ($visH -lt 1) { $visH = [int]$pane.H }
        # Hide the Android freeform title bar (back arrow + window buttons)
        # by cropping it from the captured frame. Immersive panes have no bar.
        $tb = 0
        if ($script:hideCaption) {
            $tbProp = $pane.PSObject.Properties['TitleBar']
            if ($null -ne $tbProp) { $tb = [int]$tbProp.Value } else { $tb = [int]$script:captionHeightPx }
            $tb = [Math]::Min($tb, [Math]::Max(0, $visH - 40))
        }
        $visH = [Math]::Max(1, $visH - $tb)
        [void]$pane.PSObject.Properties.Remove('Grab')
        $pane | Add-Member -NotePropertyName CaptionInset -NotePropertyValue $tb -Force
        $pane | Add-Member -NotePropertyName EdgeCrop -NotePropertyValue ([int]$script:edgeCropPx) -Force
        $pane | Add-Member -NotePropertyName VX -NotePropertyValue $vx -Force
        $pane | Add-Member -NotePropertyName VY -NotePropertyValue $vy -Force
        $pane | Add-Member -NotePropertyName VisH -NotePropertyValue $visH -Force
        $pane | Add-Member -NotePropertyName OrigExStyle -NotePropertyValue (($paneOrigEx -bor 0x00040000) -band (-bnot 0x00000080)) -Force
        $pane | Add-Member -NotePropertyName OrigRect -NotePropertyValue $paneRect -Force
        $pane | Add-Member -NotePropertyName WasZoomed -NotePropertyValue $paneZoomed -Force
        $pane | Add-Member -NotePropertyName Grab -NotePropertyValue ([FrameGrabber]::new([int]$pane.W, [int]$pane.H)) -Force
        $paneParkX = $parkBase + $vx
        $pane | Add-Member -NotePropertyName ParkX -NotePropertyValue $paneParkX -Force
        $pane | Add-Member -NotePropertyName ParkY -NotePropertyValue 0 -Force

        if ($paneZoomed) {
            [void][NativeWin]::ShowWindow($pane.Source, 9)
            for ($i = 0; $i -lt 20 -and [NativeWin]::IsZoomed($pane.Source); $i++) {
                [System.Threading.Thread]::Sleep(25)
            }
        }
        $parkedEx = (($paneOrigEx -bor 0x00000080) -band (-bnot 0x00040000))
        [void][NativeWin]::SetWindowLong($pane.Source, -20, $parkedEx)
        [void][NativeWin]::SetWindowPos($pane.Source, [IntPtr]::Zero, $paneParkX, 0, [int]$pane.W, [int]$pane.H, 0x0010)
        if ($paneZoomed) {
            [System.Threading.Thread]::Sleep(120)
            [void][NativeWin]::SetWindowPos($pane.Source, [IntPtr]::Zero, $paneParkX, 0, [int]$pane.W, [int]$pane.H, 0x0010)
        }
    }

    $capMax = 0
    foreach ($pane in $panes) {
        $cp = $pane.PSObject.Properties['CaptionInset']
        if ($null -ne $cp -and [int]$cp.Value -gt $capMax) { $capMax = [int]$cp.Value }
    }
    if ($capMax -gt 0) { $srcH = [Math]::Max(1, $srcH - $capMax) }
    try { Write-WinoidLog ("wrapper $($app.Package): frames=$($androidFrames.Count) panes=$paneInfo caption=$capMax nav=$($spec.NavInset)") } catch { }

    $w = @{}
    $w.Package = $app.Package
    $w.AppName = $displayName
    $w.Source = $source
    $w.SrcW = $srcW
    $w.SrcH = $srcH
    $w.CaptionInset = $capMax
    $w.NavInset = $spec.NavInset
    $w.Panes = @($panes)
    # Keep the ArrayList so Sync-SettingsSurface can park newly opened
    # activities; @() would turn it into a fixed-size array.
    $w.Parked = $parked
    $w.ParkBase = $parkBase
    $w.SettingsW = $srcW
    $w.SettingsH = $srcH
    $w.SettingsSyncAt = [DateTime]::MinValue
    # A new Settings wrapper always starts on the root list, even if a stale
    # sub-surface from an earlier session is still above it.
    $w.SettingsTop = 'com.android.settings/.Settings'
    $w.SettingsTopDue = $null
    $w.SettingsTopProbeAt = $null
    $w.FrameL = 0; $w.FrameT = 0; $w.FrameW = $srcW; $w.FrameH = $srcH
    if ($null -ne $settingsFrame) {
        $w.FrameL = [int]$settingsFrame.L
        $w.FrameT = [int]$settingsFrame.T
        $w.FrameW = [int]$settingsFrame.W
        $w.FrameH = [int]$settingsFrame.H
    }
    $w.Closed = $false
    $w.Settled = $false
    $w.LoadPhase = 0
    $w.LoadStart = [DateTime]::UtcNow
    $w.Frames = 0
    $w.DragX = 0; $w.DragY = 0; $w.DragT = [DateTime]::MinValue
    $w.DownX = 0; $w.DownY = 0; $w.Dragging = $false; $w.DragSent = $false
    $w.LastMoveT = [DateTime]::MinValue
    $w.LoadingIcon = $null
    $w.WheelAcc = 0
    $w.WheelLogSign = 0
    $w.ParkSweepAt = $null
    $w.GameMode = $false
    # The onboarding hint covers game UI until the first tap; hide it by
    # itself after a few seconds so screenshots and idle windows stay clean.
    $w.HintUntil = [DateTime]::UtcNow.AddSeconds(8)

    $win = [System.Windows.Markup.XamlReader]::Parse($script:wrapperXaml)
    Register-WindowText $win
    if ($script:language -eq 'en') { Apply-Language }
    $win.Title = "$displayName — Winoid"
    if ($null -ne $script:appIcon) { $win.Icon = $script:appIcon }
    $image = $win.FindName('View')
    $hint = $win.FindName('Hint')
    $loading = $win.FindName('Loading')
    $loadingText = $win.FindName('LoadingText')
    $loadingIcon = $win.FindName('LoadingIcon')
    $backBtn = $win.FindName('BackBtn')
    $homeBtn = $win.FindName('HomeBtn')
    $recentsBtn = $win.FindName('RecentsBtn')
    $navLabel = $win.FindName('NavLabel')
    $navPanel = $win.FindName('NavPanel')
    $gameModeBtn = $win.FindName('GameModeBtn')
    $phoneModeBtn = $win.FindName('PhoneModeBtn')
    $tabletModeBtn = $win.FindName('TabletModeBtn')

    $wb = New-Object System.Windows.Media.Imaging.WriteableBitmap($srcW, $srcH, 96, 96, [System.Windows.Media.PixelFormats]::Bgr32, $null)
    $image.Source = $wb

    $w.Window = $win
    $w.Image = $image
    $image.Stretch = $(if ($script:stretchFill) { 'Fill' } else { 'Uniform' })
    $w.Hint = $hint
    $w.Loading = $loading
    $w.LoadingText = $loadingText
    $w.LoadingIcon = $loadingIcon
    $w.Wb = $wb

    if ($null -ne $loadingIcon) { $loadingIcon.Source = $script:appIcon }

    $gameModeBtn.Add_Click({ Invoke-Safe 'gameMode' {
        $w.GameMode = -not [bool]$w.GameMode
        try {
            $navPanel.Visibility = $(if ($w.GameMode) { 'Collapsed' } else { 'Visible' })
            $image.Stretch = $(if ($w.GameMode) { 'Fill' } else { $(if ($script:stretchFill) { 'Fill' } else { 'Uniform' }) })
        } catch { }
        Set-Footer $(if ($w.GameMode) { 'Игровой режим включён.' } else { 'Игровой режим выключен.' })
    } })
    $phoneModeBtn.Add_Click({ Invoke-Safe 'phoneMode' { Set-LiveDisplayMode $w 'phone' } })
    $tabletModeBtn.Add_Click({ Invoke-Safe 'tabletMode' { Set-LiveDisplayMode $w 'tablet' } })

    $win.Add_SizeChanged({
        param($sender, $e)
        try { $navLabel.Visibility = $(if ($sender.ActualWidth -lt 560) { 'Collapsed' } else { 'Visible' }) } catch { }
    })

    $image.Add_MouseLeftButtonDown({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $raw = $e.GetPosition($sender)
            $p = Map-WrapperPoint $w $raw
            $pText = if ($null -ne $p) { "$($p[0]),$($p[1])" } else { "null" }
            Write-WinoidLog ("click " + $w.Package + " raw=" + [int]$raw.X + "," + [int]$raw.Y + " mapped=" + $pText)
            if ($null -eq $p) { return }
            # Defer Android input until we know whether this is a tap or a
            # drag. A zero-length motionevent DOWN/UP pair is unreliable and
            # often leaves the app seeing only a pressed row; "input tap" is
            # what a real finger click does.
            $w.DownX = $p[0]; $w.DownY = $p[1]
            $w.Dragging = $false
            $w.DragSent = $false
            $w.LastMoveT = [DateTime]::MinValue
            $w.Hint.Visibility = 'Collapsed'
            [void]$sender.CaptureMouse()
        } catch {
            Write-WinoidLog ("click error: " + $_.Exception.ToString() + " AT " + $_.ScriptStackTrace)
        }
    })
    $image.Add_MouseMove({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            if ($e.LeftButton -ne 'Pressed') { return }
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            if (-not $w.Dragging) {
                if ([math]::Abs($p[0] - $w.DownX) -lt 8 -and [math]::Abs($p[1] - $w.DownY) -lt 8) { return }
                $w.Dragging = $true
            }
            if (-not $w.DragSent) {
                Send-Android "input motionevent DOWN $($w.DownX) $($w.DownY)"
                $w.DragSent = $true
            }
            $now = [DateTime]::UtcNow
            if (($now - $w.LastMoveT).TotalMilliseconds -lt 45) { return }
            $w.LastMoveT = $now
            Send-Android "input motionevent MOVE $($p[0]) $($p[1])"
        } catch { }
    })
    $image.Add_MouseLeftButtonUp({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($w.Dragging -and $w.DragSent) {
                if ($null -eq $p) { $p = @([int]$w.DownX, [int]$w.DownY) }
                Send-Android "input motionevent UP $($p[0]) $($p[1])"
            } elseif (-not $w.Dragging) {
                Send-Android "input tap $($w.DownX) $($w.DownY)"
                if ($w.Package -eq 'com.android.settings') {
                    $w.SettingsTopDue = [DateTime]::UtcNow.AddMilliseconds(900)
                }
            }
            $w.Dragging = $false; $w.DragSent = $false
            # Hand keyboard focus to the hidden Android window only after a
            # real tap in the image. Doing this on every activation would
            # cancel title-bar drags and double clicks, so the window could
            # not be resized or maximized.
            $script:bounceWrap = $w
            $script:bounceTimer.Stop()
            $script:bounceTimer.Start()
            [void]$sender.ReleaseMouseCapture()
        } catch { }
    })
    $image.Add_MouseWheel({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            # Accumulate notch deltas: a proportional swipe is much smoother
            # than one fixed jump per notch, and slow trackpads do not get
            # ignored altogether.
            $acc = [int]$w.WheelAcc + [int]$e.Delta
            if ([Math]::Abs($acc) -lt 120) { $w.WheelAcc = $acc; return }
            $steps = [int]([Math]::Round($acc / 120.0))
            $dir = [Math]::Sign($steps)
            if ($dir -eq 0) { $dir = $(if ($acc -gt 0) { 1 } else { -1 }) }
            $mag = [Math]::Max(1, [Math]::Min(5, [Math]::Abs($steps)))
            # Wheel up (positive Delta) must swipe DOWN so the document scrolls
            # up; wheel down swipes up. The old code always swiped up.
            $dy = $dir * $mag * 150
            $w.WheelAcc = $acc - ($steps * 120)
            if ($w.WheelLogSign -ne $dir) {
                $w.WheelLogSign = $dir
                Write-WinoidLog "wheel dir=$dir delta=$($e.Delta) dy=$dy"
            }
            Send-Android "input swipe $($p[0]) $($p[1]) $($p[0]) $($p[1] + $dy) 180"
        } catch { }
    })
    $image.Add_MouseRightButtonDown({
        param($sender, $e)
        $w = $script:wrapByImage[$sender]
        if ($null -eq $w -or $w.Closed) { return }
        try {
            $p = Map-WrapperPoint $w $e.GetPosition($sender)
            if ($null -eq $p) { return }
            # A stationary long swipe is how Android sees a long press.
            Send-Android "input swipe $($p[0]) $($p[1]) $($p[0]) $($p[1]) 650"
        } catch { }
    })
    $backBtn.Add_Click({
        param($sender, $e)
        try {
            $owner = [System.Windows.Window]::GetWindow($sender)
            $w = $script:wrapByWindow[$owner]
            if ($null -eq $w -or $w.Closed) { return }
            [NativeWin]::ForceForeground($w.Source)
            [System.Threading.Thread]::Sleep(120)
            Send-AndroidBack $w
        } catch { }
    })
    $homeBtn.Add_Click({
        param($sender, $e)
        try {
            $owner = [System.Windows.Window]::GetWindow($sender)
            $w = $script:wrapByWindow[$owner]
            if ($null -eq $w -or $w.Closed) { return }
            [NativeWin]::ForceForeground($w.Source)
            [System.Threading.Thread]::Sleep(120)
            Send-Android 'input keyevent 3'
        } catch { }
    })
    $recentsBtn.Add_Click({
        param($sender, $e)
        try {
            $owner = [System.Windows.Window]::GetWindow($sender)
            $w = $script:wrapByWindow[$owner]
            if ($null -eq $w -or $w.Closed) { return }
            [NativeWin]::ForceForeground($w.Source)
            [System.Threading.Thread]::Sleep(120)
            Send-Android 'input keyevent 187'
        } catch { }
    })
    $win.Add_PreviewKeyDown({
        param($sender, $e)
        Invoke-Safe 'wrapper.key' {
            $w = $script:wrapByWindow[$sender]
            if ($null -eq $w -or $w.Closed) { return }
            $key = $e.Key.ToString()
            if ($key -eq 'System') { $key = $e.SystemKey.ToString() }
            $alt = (([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Alt) -ne 0)
            $keyCode = 0
            if ($key -eq 'Escape' -or $key -eq 'Back' -or $key -eq 'BrowserBack' -or ($key -eq 'Left' -and $alt)) { $keyCode = 4 }
            elseif ($key -eq 'Home') { $keyCode = 3 }
            elseif ($key -eq 'Apps' -or $key -eq 'LaunchApplication1') { $keyCode = 187 }
            if ($keyCode -ne 0) {
                $e.Handled = $true
                [NativeWin]::ForceForeground($w.Source)
                if ($keyCode -eq 4) { Send-AndroidBack $w }
                else { Send-Android "input keyevent $keyCode" }
            }
        }
    })
    # Focus goes back to the Android surface only after a tap in the image
    # (see MouseLeftButtonUp). Bouncing on every activation used to steal focus
    # during title-bar drags, so wrapper windows could not be resized.
    $win.Add_Closing({
        param($sender, $e)
        Invoke-Safe 'wrapper.closing' {
            $w = $script:wrapByWindow[$sender]
            if ($null -eq $w -or $w.Closed) { return }
            try {
                if ($sender.WindowState -ne 'Maximized' -and $sender.ActualWidth -gt 100) {
                    $script:appGeometry[[string]$w.Package] = [pscustomobject]@{ W = [int]$sender.ActualWidth; H = [int]$sender.ActualHeight }
                    Save-AppGeometry
                }
            } catch { }
            Remove-Wrapper $w $true
        }
    })

    $script:wrapByImage[$image] = $w
    $script:wrapByWindow[$win] = $w
    [void]$script:wrappers.Add($w)

    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    if ($null -ne $size -and [int]$size.Width -gt 0) { $cw = [int]$size.Width; $ch = [int]$size.Height }
    elseif ($script:appGeometry.ContainsKey([string]$app.Package)) {
        $g = $script:appGeometry[[string]$app.Package]
        $cw = [int]$g.W; $ch = [int]$g.H
    }
    elseif ($app.Package -eq 'com.android.settings') {
        # Settings is a two-pane 2560x1392 desktop. At full size it would be
        # wider than most monitors, so show it at a comfortable default width.
        $cw = [Math]::Min($srcW, 1600)
        $ch = [int]($cw * $srcH / $srcW)
    }
    else { $cw = $srcW; $ch = $srcH }
    $maxW = [Math]::Max(360, $wa.Width - 24)
    $maxH = [Math]::Max(300, $wa.Height - 64 - $script:wrapperNavHeight)
    if ($cw -gt $maxW) { $k = $maxW / $cw; $cw = [int]($cw * $k); $ch = [int]($ch * $k) }
    if ($ch -gt $maxH) { $k = $maxH / $ch; $cw = [int]($cw * $k); $ch = [int]($ch * $k) }
    $win.Width = $cw + 16
    $win.Height = $ch + $script:wrapperNavHeight + 39
    $win.Show()
    Set-WinoidDarkTitleBar $win
    $win.UpdateLayout()
    Focus-Wrapper $w
    try {
        $h = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
        $wcr = New-Object NativeWin+RECT
        $wwr = New-Object NativeWin+RECT
        [void][NativeWin]::GetClientRect($h, [ref]$wcr)
        [void][NativeWin]::GetWindowRect($h, [ref]$wwr)
        $bw = ($wwr.Right - $wwr.Left) - $wcr.Right
        $bh = ($wwr.Bottom - $wwr.Top) - $wcr.Bottom
        $win.Width = $cw + $bw
        $win.Height = $ch + $script:wrapperNavHeight + $bh
    } catch { }
    return $w
}

# Extract app icons one at a time in the background. The slow ADB calls no
# longer block the manager window during a refresh.
$iconTimer = [System.Windows.Threading.DispatcherTimer]::new()
$iconTimer.Interval = [TimeSpan]::FromMilliseconds(600)
$iconTimer.Add_Tick({
    Invoke-Safe 'iconTimer' {
        if ($script:iconQueue.Count -eq 0) { $iconTimer.Stop(); return }
        $pkg = [string]$script:iconQueue.Dequeue()
        $frame = Get-AppIconPath ([pscustomobject]@{ Package = $pkg })
        foreach ($item in $script:apps) {
            if ([string]$item.Package -eq $pkg) { $item.Icon = $frame }
        }
        try { $appsList.Items.Refresh() } catch { }
    }
})

$script:bounceTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:bounceTimer.Interval = [TimeSpan]::FromMilliseconds(180)
$script:bounceTimer.Add_Tick({
    try {
        $script:bounceTimer.Stop()
        $w = $script:bounceWrap
        if ($null -eq $w -or $w.Closed) { return }
        if ($w.Window.IsActive -and $w.Window.WindowState -ne 'Minimized' -and -not [NativeWin]::LeftButtonDown()) {
            [NativeWin]::ForceForeground($w.Source)
        }
    } catch {
        Write-WinoidLog ("ERROR bounceTimer: " + $_.Exception.ToString())
    }
})

$script:frameTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:frameTimer.Interval = [TimeSpan]::FromMilliseconds(50)
$script:frameTimer.Add_Tick({
    try {
        $beatNow = [DateTime]::UtcNow
        if (($beatNow - $script:lastHeartbeat).TotalSeconds -ge 10) {
            $script:lastHeartbeat = $beatNow
            try { [System.IO.File]::WriteAllText($script:heartbeatPath, $beatNow.ToString('o')) } catch { }
        }
        $list = $script:wrappers
        $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        for ($i = $list.Count - 1; $i -ge 0; $i--) {
            if ($i -ge $list.Count) { continue }
            $w = $list[$i]
            if ($w.Closed) { continue }
            $alive = $false
            foreach ($pane in @($w.Panes)) {
                if ($null -ne $pane -and [NativeWin]::IsWindow($pane.Source)) { $alive = $true; break }
            }
            if (-not $alive) { Remove-Wrapper $w $false; continue }
            if ($w.Package -eq 'com.android.settings') {
                if ($null -ne $w.SettingsTopDue -and [DateTime]::UtcNow -ge $w.SettingsTopDue) {
                    $w.SettingsTopDue = $null
                    Update-SettingsActivity $w
                }
                if (([DateTime]::UtcNow - $w.SettingsSyncAt).TotalMilliseconds -ge 350) {
                    $w.SettingsSyncAt = [DateTime]::UtcNow
                    Sync-SettingsSurface $w
                }
            }
            if ($null -ne $w.HintUntil -and [DateTime]::UtcNow -ge $w.HintUntil) {
                $w.Hint.Visibility = 'Collapsed'
                $w.HintUntil = $null
            }
            # Only grab frames for the active wrapper at full rate; inactive
            # ones refresh occasionally so switching back is not stale.
            $capture = ($w.Window.IsVisible -and $w.Window.WindowState -ne 'Minimized' -and
                        ($w.Window.IsActive -or (($w.Frames % 20) -eq 0)))
            $lumaSum = 0.0
            $lumaRows = 0
            # Start all captures first: PrintWindow runs on thread-pool threads
            # so the WPF dispatcher is free while the pixels are being read.
            if ($capture) {
                foreach ($p in @($w.Panes)) {
                    if ($null -ne $p -and [NativeWin]::IsWindow($p.Source)) { [void]$p.Grab.CaptureBegin($p.Source) }
                }
            }
            foreach ($pane in @($w.Panes)) {
                if ($null -eq $pane -or -not [NativeWin]::IsWindow($pane.Source)) { continue }
                if ([NativeWin]::IsIconic($pane.Source)) {
                    [void][NativeWin]::ShowWindow($pane.Source, 9)
                }
                $sr = New-Object NativeWin+RECT
                [void][NativeWin]::GetWindowRect($pane.Source, [ref]$sr)
                if ([math]::Abs($sr.Left - $pane.ParkX) -gt 1 -or [math]::Abs($sr.Top - $pane.ParkY) -gt 1) {
                    if ([NativeWin]::IsZoomed($pane.Source)) { [void][NativeWin]::ShowWindow($pane.Source, 9) }
                    [void][NativeWin]::SetWindowPos($pane.Source, [IntPtr]::Zero, $pane.ParkX, $pane.ParkY, $pane.W, $pane.H, 0x0010)
                }
                if (-not $capture) { continue }
                # A WSLg shadow can make the surface a few pixels larger than
                # the Android frame; crop it and never write outside the
                # wrapper bitmap.
                $cx = 0; $cy = 0
                $cxp = $pane.PSObject.Properties['CropX']; $cyp = $pane.PSObject.Properties['CropY']
                if ($null -ne $cxp) { $cx = [int]$cxp.Value }
                if ($null -ne $cyp) { $cy = [int]$cyp.Value }
                $vw = [Math]::Min([int]$pane.W - $cx, [int]$w.SrcW - [int]$pane.VX)
                $vh = [Math]::Min([int]$pane.VisH - $cy, [int]$w.SrcH - [int]$pane.VY)
                if ($vw -lt 1 -or $vh -lt 1) { continue }
                $capProp = $pane.PSObject.Properties['CaptionInset']
                $capPx = 0
                if ($null -ne $capProp) { $capPx = [int]$capProp.Value }
                $ecProp = $pane.PSObject.Properties['EdgeCrop']
                $ec = 0
                if ($null -ne $ecProp) { $ec = [int]$ecProp.Value }
                if (-not $pane.Grab.CaptureComplete()) { continue }
                $srcRect = [System.Windows.Int32Rect]::new($cx + $ec, $cy + $capPx + $ec, [Math]::Max(1, $vw - 2 * $ec), [Math]::Max(1, $vh - 2 * $ec))
                $w.Wb.WritePixels($srcRect, $pane.Grab.Bits, [int]$pane.Grab.ByteSize, $pane.Grab.Stride, [int]$pane.VX, [int]$pane.VY)
                $lumaSum += $pane.Grab.MeanLuma() * $vh
                $lumaRows += $vh
            }
            foreach ($extra in @($w.Parked)) {
                if ($null -eq $extra -or -not [NativeWin]::IsWindow($extra.Source)) { continue }
                $er = New-Object NativeWin+RECT
                [void][NativeWin]::GetWindowRect($extra.Source, [ref]$er)
                if ([math]::Abs($er.Left - $extra.ParkX) -gt 1 -or [math]::Abs($er.Top - $extra.ParkY) -gt 1) {
                    [void][NativeWin]::SetWindowPos($extra.Source, [IntPtr]::Zero, $extra.ParkX, $extra.ParkY, $extra.W, $extra.H, 0x0010)
                }
            }
            # Android can create a new base window with its own caption after
            # the wrapper exists. Park such late surfaces so the raw Android
            # window with '<' and window buttons is not visible behind Winoid.
            $sweepAt = $null
            try { $sweepAt = [DateTime]$w.ParkSweepAt } catch { }
            if ($null -eq $sweepAt -or ([DateTime]::UtcNow - $sweepAt).TotalMilliseconds -ge 700) {
                $w.ParkSweepAt = [DateTime]::UtcNow
                $rootOwner = [NativeWin]::GetAncestor($w.Source, 3)
                $known = New-Object 'System.Collections.Generic.HashSet[System.IntPtr]'
                [void]$known.Add($w.Source)
                foreach ($pane in @($w.Panes)) { [void]$known.Add($pane.Source) }
                foreach ($extra in @($w.Parked)) { [void]$known.Add($extra.Source) }
                foreach ($proc in @(Get-Process msrdc -ErrorAction SilentlyContinue)) {
                    $late = @()
                    try { $late = @([NativeWin]::ListWindows([uint32]$proc.Id)) } catch { }
                    foreach ($wnd in $late) {
                        if ($null -eq $wnd -or -not $wnd.Visible) { continue }
                        # Only park a full-size copy of the app window (the one
                        # carrying the gray caption). Small sub-surfaces belong
                        # to the game's own rendering and must stay untouched.
                        if ($wnd.Title -match 'sub-surface') { continue }
                        if ($wnd.Width -lt [int]($w.SrcW * 0.7) -or $wnd.Height -lt [int]($w.SrcH * 0.7)) { continue }
                        if ($known.Contains($wnd.Hwnd)) { continue }
                        if ([NativeWin]::GetAncestor($wnd.Hwnd, 3) -ne $rootOwner) { continue }
                        $lr = New-Object NativeWin+RECT
                        [void][NativeWin]::GetWindowRect($wnd.Hwnd, [ref]$lr)
                        if ([int]$lr.Left -ge $vs.Right - 50) { continue }
                        $oldEx = [NativeWin]::GetWindowLong($wnd.Hwnd, -20)
                        $zoomed = [NativeWin]::IsZoomed($wnd.Hwnd)
                        $px = $vs.Right + 200 + [int]$w.Parked.Count * 8
                        if ($zoomed) { [void][NativeWin]::ShowWindow($wnd.Hwnd, 9) }
                        [void][NativeWin]::SetWindowLong($wnd.Hwnd, -20, (($oldEx -bor 0x00000080) -band (-bnot 0x00040000)))
                        [void]$w.Parked.Add([pscustomobject]@{
                            Source = $wnd.Hwnd
                            OrigExStyle = (($oldEx -bor 0x00040000) -band (-bnot 0x00000080))
                            OrigRect = $lr
                            WasZoomed = $zoomed
                            ParkX = $px
                            ParkY = 0
                            W = [int]$wnd.Width
                            H = [int]$wnd.Height
                        })
                        [void][NativeWin]::SetWindowPos($wnd.Hwnd, [IntPtr]::Zero, $px, 0, [int]$wnd.Width, [int]$wnd.Height, 0x0010)
                        Write-WinoidLog "parked late surface: $($wnd.Title)"
                    }
                }
            }
            if (-not $capture -or $lumaRows -eq 0) { continue }
            $w.Frames++
            if (-not $w.Settled -and ($w.Frames % 8) -eq 0) {
                $elapsed = ([DateTime]::UtcNow - $w.LoadStart).TotalSeconds
                # Dark apps (game menus, splash screens) are still content:
                # anything but a near-black frame means we can show the app.
                # As a last resort stop covering it after a few seconds.
                if ($elapsed -ge 1.5 -and (($lumaSum / $lumaRows) -ge 1 -or $elapsed -ge 6)) {
                    $w.Settled = $true
                    $w.Loading.Visibility = 'Collapsed'
                } elseif ($elapsed -ge 10 -and $w.LoadPhase -lt 1) {
                    $w.LoadPhase = 1
                    $w.LoadingText.Text = 'Приложение ещё загружается…'
                }
            }
        }
        if (([DateTime]::UtcNow - $script:adbCheckedAt).TotalSeconds -ge 5) {
            $script:adbCheckedAt = [DateTime]::UtcNow
            if ($null -eq $script:wslKeepAlive -or $script:wslKeepAlive.HasExited) { Start-WslKeepAlive }
            if ($null -eq $script:adb -or -not $script:adb.Running) {
                if ($script:adb) { try { $script:adb.Dispose() } catch { }; $script:adb = $null }
                if ($script:sessionRunning) { Initialize-Adb }
            }
            # WSLg restarts msrdc after a Weston crash. All RAIL windows die
            # with it, so tell the user how to bring Android windows back.
            $msrdc = @(Get-Process msrdc -ErrorAction SilentlyContinue)
            if ($msrdc.Count -gt 0) {
                if ($script:msrdcId -ne 0 -and $msrdc[0].Id -ne $script:msrdcId) {
                    Set-Footer 'Графика WSL перезапустилась. Нажмите «Перезапустить Android», чтобы вернуть окна Android.'
                }
                $script:msrdcId = $msrdc[0].Id
            }
        }
    } catch {
        $now = Get-Date
        if (($now - $script:frameErrorAt).TotalSeconds -ge 30) {
            $script:frameErrorAt = $now
            Write-WinoidLog ("ERROR frameTimer: " + $_.Exception.ToString())
        }
    }
})

$launchTimer = [System.Windows.Threading.DispatcherTimer]::new()
$launchTimer.Interval = [TimeSpan]::FromSeconds(1)
$launchTimer.Add_Tick({
    Invoke-Safe 'launchTimer' {
    if (-not $script:launchState) { $launchTimer.Stop(); return }
    $st = $script:launchState
    $st.Ticks++
    $sec = $st.Ticks
    if ($sec -lt 60) { $loaderElapsed.Text = "$sec сек" } else { $loaderElapsed.Text = ('{0}:{1:00}' -f [int]($sec / 60), ($sec % 60)) }

    if ($sec -eq 5) { $loaderSub.Text = 'Приложение открывается…' }
    elseif ($sec -eq 25) { $loaderSub.Text = 'Окно пока не появилось. Если графика WSL зависла, нажмите «Перезапустить Android» в главном окне Winoid.' }
    elseif ($sec -eq 30) { $loaderSub.Text = 'Идёт первый запуск. Android распаковывает данные и транслирует ARM-код — это может занять несколько минут.' }
    elseif ($sec -eq 90) { $loaderSub.Text = 'Всё ещё загружается. Не закрывайте приложение; индикатор можно скрыть.' }

    $h = [NativeWin]::FindWindowContains($st.WindowMatch, 'Winoid')
    if ($h -ne [IntPtr]::Zero) {
        $st.Hwnd = $h
        if (-not $st.Wrapped) {
            # Settings now uses one Android frame, so there is no second
            # side-by-side pane to wait for; Sync-SettingsSurface follows
            # sub-screens after the wrapper exists. On a fresh boot Settings
            # briefly paints a wide tablet layout before Android applies the
            # freeform frame; wait for the portrait surface so the wrapper
            # is not built around the wrong geometry.
            $ready = $true
            if ($st.App.Package -eq 'com.android.settings' -and $st.SeekTicks -lt 30) {
                $cr = New-Object NativeWin+RECT
                [void][NativeWin]::GetClientRect($h, [ref]$cr)
                if ($cr.Right -le 0 -or $cr.Bottom -le 0) { $ready = $false }
                elseif (($cr.Right / $cr.Bottom) -gt 0.8) { $ready = $false }
                # Without the Android frame the tap mapping would use 0,0
                # and every click would land near the top-left of Android.
                $frames = @(Get-AndroidWindowFrames $st.App.Package)
                if ($frames.Count -eq 0) { $ready = $false }
            }
            $st.SeekTicks++
            if ($ready) {
                $w = New-AppWrapper $st.App $h $st.Size
                if ($null -ne $w) {
                    $st.Wrapped = $true
                    Set-Footer "Окно «$(Get-AppDisplayName $st.App)» открыто."
                }
            }
        }
        if ($st.Wrapped) {
            if ($autoHideCheck.IsChecked) {
                $loader.Hide()
                $launchTimer.Stop()
            } else {
                $loaderSub.Text = 'Окно открыто. Если оно чёрное — приложение ещё загружается; первый запуск может быть долгим.'
            }
        }
    }

    # No window after 30 s: the activity is usually still alive but its WSLg
    # surface is gone (msrdc restart / manager watchdog restart). Resuming it
    # never creates a window, so force-stop once and launch again.
    if ($sec -eq 35 -and -not $st.Wrapped -and -not $st.Retried) {
        $st.Retried = $true
        Write-WinoidLog "launch retry: $($st.App.Package) (no window after 35s)"
        $loaderSub.Text = 'Окно не появилось — перезапускаю Android и приложение…'
        foreach ($wr in @($script:wrappers)) {
            Invoke-Safe 'retry.wrapper' { Remove-Wrapper $wr $true }
        }
        Restart-WaydroidSession
        try { $null = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', [string]$st.LaunchCmd)) 15000 } catch { }
    }

    if ($sec -ge 180) {
        $loader.Hide()
        $launchTimer.Stop()
        Set-Footer 'Окно не появилось за 3 минуты. Проверьте состояние Android.'
    }
    }
})

function Start-AppLaunch($app) {
    if ($null -eq $app) { return }
    if (-not (Test-Backend)) {
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    if (-not $script:sessionRunning) {
        Set-PendingLaunch $app.Package
        if (-not $sessionTimer.IsEnabled) { Start-Session }
        return
    }
    $existing = Find-WrapperByPackage $app.Package
    if ($null -ne $existing) {
        Focus-Wrapper $existing
        Set-Footer "Окно «$(Get-AppDisplayName $app)» уже открыто."
        return
    }
    if ($null -ne $script:launchState -and -not $script:launchState.Wrapped -and $script:launchState.App.Package -eq $app.Package) {
        $loader.Show()
        Set-Footer "«$(Get-AppDisplayName $app)» уже запускается…"
        return
    }

    if ($app.Package -eq 'com.android.vending') {
        $answer = [System.Windows.MessageBox]::Show(
            $window,
            'Play Store в WSL2 иногда роняет графику WSL, и окна Android могут исчезнуть. Если это случится, нажмите «Перезапустить Android» в главном окне Winoid и попробуйте снова. Продолжить?',
            'Winoid — Play Store',
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Warning,
            [System.Windows.MessageBoxResult]::No)
        if ($answer -ne [System.Windows.MessageBoxResult]::Yes) {
            Set-Footer 'Play Store не запущен.'
            return
        }
    }

    $compatNote = ''
    try {
        if (-not (Sync-ArmCompatMode $app.Package)) {
            $compatNote = ' (режим совместимости ARM недоступен)'
        }
    } catch {
        $compatNote = ' (режим совместимости ARM недоступен)'
        Write-WinoidLog ("ERROR ARM compat before launch: " + $_.Exception.ToString())
    }

    $script:launchState = [pscustomobject]@{
        App = $app
        Ticks = 0
        SeekTicks = 0
        Hwnd = [IntPtr]::Zero
        Wrapped = $false
        Retried = $false
        LaunchCmd = ''
        Size = Get-SelectedSize
        # The WSLg title is the localized Android window title, e.g.
        # "Настройки (Ubuntu-24.04)" or "Infinite Magicraid (Ubuntu-24.04)".
        # Matching the English "Settings" made the launch wait forever on a
        # Russian system while the raw Android window stayed on the desktop.
        WindowMatch = $app.Name
    }
    if ($script:rememberMode -and $null -ne $app -and -not [string]::IsNullOrWhiteSpace([string]$app.Package)) {
        $script:appModes[[string]$app.Package] = [int]$sizeBox.SelectedIndex
        Save-AppModes
    }

    # Wake a frozen runtime first, otherwise wm size/density and the launch
    # itself would silently hang.
    Ensure-WaydroidAwake ([string]$app.Package) | Out-Null

    # Apply the display mode picked in the manager before the app starts:
    # phone = portrait + phone density, tablet = landscape + tablet density.
    # "Как есть" restores the Android defaults instead of leaving the last mode.
    $sizeChoice = $script:launchState.Size
    if ($null -ne $sizeChoice) {
        if ($sizeChoice.Reset) {
            try { Send-Android 'wm size reset' } catch { }
            try { Send-Android 'wm density reset' } catch { }
        } else {
            try { Send-Android "wm size $($sizeChoice.Width)x$($sizeChoice.Height)" } catch { }
            if ([int]$sizeChoice.Density -gt 0) {
                try { Send-Android "wm density $($sizeChoice.Density)" } catch { }
            }
        }
        Start-Sleep -Milliseconds 600
    }

    # A previous launch can leave the Android activity alive with no WSLg
    # surface at all (window died with msrdc or the manager was restarted).
    # Resuming such an activity never creates a window, so stop it first:
    # the launch below then creates a fresh Android/WSLg window.
    try {
        $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'shell', 'am', 'force-stop', $app.Package)) 8000
    } catch { }
    Start-Sleep -Milliseconds 350

    $displayName = Get-AppDisplayName $app
    $loaderTitle.Text = "Запуск: $displayName"
    $loaderSub.Text = 'Открываю приложение в отдельном окне.'
    $loaderElapsed.Text = '0 сек'
    if ($null -ne $loaderIcon) {
        # Never block the launch on ADB here: use the cached icon or the
        # bundled one. Missing icons are filled in by the background queue.
        try {
            $ico = Join-Path (Join-Path $script:dataRoot 'icons') ($app.Package + '.ico')
            if (Test-Path -LiteralPath $ico) {
                $loaderIcon.Source = [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico))
            } elseif ($null -ne $script:appIcon) {
                $loaderIcon.Source = $script:appIcon
            }
        } catch { }
    }
    $loader.Show()
    $loaderBar.IsIndeterminate = $true
    $launchTimer.Start()
    Set-Footer ("Запуск $displayName…" + $compatNote)

    $cmd = "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/`$(id -u); waydroid app launch $($app.Package)"
    $script:launchState.LaunchCmd = $cmd
    try {
        # waydroid app launch returns as soon as the request is accepted;
        # a bounded call is more reliable than a detached wsl.exe process.
        $null = Invoke-Wsl ((Get-WslBase) + @('--', 'bash', '-lc', $cmd)) 15000
        Write-WinoidLog "launch sent: $($app.Package)"
    } catch {
        Write-WinoidLog ("ERROR launch " + $app.Package + ": " + $_.Exception.ToString())
        $launchTimer.Stop()
        $script:launchState = $null
        $loader.Hide()
        Set-Footer "Не удалось отправить запуск в Android: $($_.Exception.Message)"
    }
}

$installTimer = [System.Windows.Threading.DispatcherTimer]::new()
$installTimer.Interval = [TimeSpan]::FromSeconds(1)
$installTimer.Add_Tick({
    Invoke-Safe 'installTimer' {
    if ($null -eq $script:installJob) { $installTimer.Stop(); $loader.Hide(); return }
    $script:installTicks++
    $sec = $script:installTicks
    if ($sec -lt 60) { $loaderElapsed.Text = "$sec сек" } else { $loaderElapsed.Text = ('{0}:{1:00}' -f [int]($sec / 60), ($sec % 60)) }
    $state = 'Unknown'
    try { $state = [string]$script:installJob.State } catch { }
    if ($state -in @('Completed', 'Failed', 'Stopped')) {
        $out = ''
        try { $out = @(Receive-Job -Job $script:installJob -ErrorAction SilentlyContinue) | Out-String } catch { }
        Write-WinoidLog "install job $state`: $out"
        Remove-Job -Job $script:installJob -Force -ErrorAction SilentlyContinue
        $script:installJob = $null
        $installTimer.Stop()
        $loader.Hide()
        Invoke-Safe 'install.refresh' { Refresh-Apps }
        $last = (($out -split "`r?`n") | Where-Object { $_.Trim().Length -gt 0 -and $_ -notmatch '^WINOID_INSTALL_EXIT=' } | Select-Object -Last 1)
        if ($out -match 'WINOID_INSTALL_EXIT=0') { Set-Footer 'APK установлен.' }
        elseif ($last) { Set-Footer "Установка не удалась: $last" }
        else { Set-Footer 'Установка не удалась. Подробности: %LOCALAPPDATA%\Winoid\install.log' }
    }
    }
})

function Install-Apk([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path -LiteralPath $path)) { return }
    if ($null -ne $script:installJob) {
        $state = 'Unknown'
        try { $state = [string]$script:installJob.State } catch { }
        if ($state -notin @('Completed', 'Failed', 'Stopped')) {
            Set-Footer 'Установка уже идёт. Дождитесь её окончания.'
            return
        }
        Remove-Job -Job $script:installJob -Force -ErrorAction SilentlyContinue
        $script:installJob = $null
    }
    if ($null -ne $script:sessionJob -and $sessionTimer.IsEnabled) {
        Set-Footer 'Дождитесь запуска Android, затем повторите установку.'
        return
    }

    $apk = (Resolve-Path -LiteralPath $path).Path
    Invoke-Safe 'install.initAdb' { Initialize-Adb }

    # Prefer WSL adb for the same reason as input: the Windows route to the
    # Waydroid subnet may be blackholed by a VPN. Windows adb is the fallback.
    $mode = ''
    $exe = ''
    $apkArg = $apk
    if ($script:adbViaWsl -and $null -ne $script:adb -and $script:adb.Running) {
        $mode = 'wsl'
        $exe = $script:wsl
        $apkArg = ConvertTo-WslPath $apk
    } elseif (-not [string]::IsNullOrWhiteSpace($script:adbPath)) {
        $mode = 'local'
        $exe = $script:adbPath
    } else {
        Set-Footer 'ADB не найден. Установите platform-tools или настройте Android заново.'
        return
    }
    Write-WinoidLog "install start ($mode): $apk"

    $script:installTicks = 0
    $loaderTitle.Text = 'Установка APK'
    $loaderSub.Text = "Отправляю $(Split-Path -Leaf $apk) в Android…"
    $loaderElapsed.Text = '0 сек'
    $loader.Show()
    $loaderBar.IsIndeterminate = $true
    Set-Footer 'Установка APK…'

    $jobExe = $exe
    $jobDistro = $script:wslDistro
    $jobSerial = $script:adbSerial
    $jobLog = Join-Path $script:dataRoot 'install.log'
    try {
        $script:installJob = Start-Job -ScriptBlock {
            param($mode, $exe, $distro, $serial, $apkPath, $logFile)
            $lines = New-Object System.Collections.ArrayList
            [void]$lines.Add("mode=$mode")
            if ($mode -eq 'wsl') {
                $wslArgs = @()
                if (-not [string]::IsNullOrWhiteSpace($distro)) { $wslArgs += @('-d', $distro) }
                $out = & $exe @wslArgs -- adb -s $serial install -r $apkPath 2>&1
            } else {
                $out = & $exe -s $serial install -r $apkPath 2>&1
            }
            $code = $LASTEXITCODE
            foreach ($l in @($out)) { [void]$lines.Add([string]$l) }
            [void]$lines.Add("install exit=$code")
            try {
                $dir = Split-Path -Parent $logFile
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                [System.IO.File]::WriteAllText($logFile, (($lines -join "`r`n") + "`r`nWINOID_INSTALL_EXIT=$code"), (New-Object System.Text.UTF8Encoding($false)))
            } catch { }
            foreach ($l in $lines) { $l }
            "WINOID_INSTALL_EXIT=$code"
        } -ArgumentList $mode, $jobExe, $jobDistro, $jobSerial, $apkArg, $jobLog
    } catch {
        Write-WinoidLog ("ERROR install job: " + $_.Exception.ToString())
        $script:installJob = $null
        $loader.Hide()
        Set-Footer "Не удалось запустить установку: $($_.Exception.Message)"
        return
    }
    $installTimer.Start()
}

function ConvertTo-WslPath([string]$path) {
    $full = [System.IO.Path]::GetFullPath($path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return '/mnt/' + $matches[1].ToLowerInvariant() + '/' + ($matches[2] -replace '\\', '/')
    }
    return ($full -replace '\\', '/')
}

function Convert-PngToIco([string]$pngPath, [string]$icoPath) {
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Image]::FromFile($pngPath)
    try {
        $sizes = @(16, 24, 32, 48, 64, 128, 256)
        $pngs = New-Object System.Collections.Generic.List[byte[]]
        foreach ($s in $sizes) {
            $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [System.Drawing.Graphics]::FromImage($bmp)
            $g.Clear([System.Drawing.Color]::Transparent)
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $scale = [Math]::Min($s / $src.Width, $s / $src.Height)
            $w = [Math]::Max(1, [int][Math]::Round($src.Width * $scale))
            $h = [Math]::Max(1, [int][Math]::Round($src.Height * $scale))
            $x = [int](($s - $w) / 2)
            $y = [int](($s - $h) / 2)
            $g.DrawImage($src, $x, $y, $w, $h)
            $ms = New-Object System.IO.MemoryStream
            $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
            $pngs.Add($ms.ToArray())
            $ms.Dispose(); $g.Dispose(); $bmp.Dispose()
        }

        $ms = New-Object System.IO.MemoryStream
        $bw = New-Object System.IO.BinaryWriter $ms
        $bw.Write([UInt16]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]$sizes.Count)
        $offset = 6 + 16 * $sizes.Count
        for ($i = 0; $i -lt $sizes.Count; $i++) {
            $s = $sizes[$i]
            $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
            $bw.Write([Byte]$(if ($s -ge 256) { 0 } else { $s }))
            $bw.Write([Byte]0)
            $bw.Write([Byte]0)
            $bw.Write([UInt16]1)
            $bw.Write([UInt16]32)
            $bw.Write([UInt32]$pngs[$i].Length)
            $bw.Write([UInt32]$offset)
            $offset += $pngs[$i].Length
        }
        foreach ($png in $pngs) { $bw.Write($png) }
        $bw.Flush()
        $dir = Split-Path -Parent $icoPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllBytes($icoPath, $ms.ToArray())
        $bw.Dispose(); $ms.Dispose()
    } finally {
        $src.Dispose()
    }
}

function Get-AppIconPath($app) {
    $generic = Join-Path $script:baseDir 'assets\android.ico'
    $dex = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    if (-not (Test-Path -LiteralPath $dex)) { return [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($generic)) }

    $iconsDir = Join-Path $script:dataRoot 'icons'
    if (-not (Test-Path -LiteralPath $iconsDir)) { New-Item -ItemType Directory -Path $iconsDir -Force | Out-Null }
    $ico = Join-Path $iconsDir ($app.Package + '.ico')
    if (Test-Path -LiteralPath $ico) {
        # Cached per-package icon: skip the ADB round-trips on repeat refreshes.
        return [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico))
    }
    # A frozen Waydroid container makes every adb call hang until its timeout.
    # Probe once per refresh: after the first failure use the bundled icon for
    # the rest of the list instead of freezing the UI for minutes.
    if ($script:iconAdbOffline) { return [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($generic)) }
    $remoteDex = '/data/local/tmp/winoid-icon.dex'
    $remotePng = '/data/local/tmp/winoid-icon-' + $app.Package + '.png'
    $localPng = Join-Path $env:TEMP ('winoid-icon-' + [Guid]::NewGuid().ToString('N') + '.png')
    $ok = $false

    # Windows ADB is preferred; WSL ADB is the fallback when a VPN swallows
    # the route to the Waydroid subnet.
    if ($script:adbPath) {
        try {
            $state = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'get-state') -TimeoutMs 6000
            if ($state -notmatch '^device') {
                $null = Invoke-AdbCli -Arguments @('connect', $script:adbSerial) -TimeoutMs 8000
                $state = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'get-state') -TimeoutMs 6000
            }
            if ($state -match '^device') {
                $null = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'push', $dex, $remoteDex) -TimeoutMs $script:adbTimeoutMs
                $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon $($app.Package) $remotePng"
                $res = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'shell', $cmd) -TimeoutMs $script:adbTimeoutMs
                if ($res -match 'OK') {
                    $null = Invoke-AdbCli -Arguments @('-s', $script:adbSerial, 'pull', $remotePng, $localPng) -TimeoutMs $script:adbTimeoutMs
                    if (Test-Path -LiteralPath $localPng) { $ok = $true }
                }
            }
        } catch { }
    }

    if (-not $ok) {
        try {
            $stateArgs = (Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'get-state')
            $r = Invoke-Wsl $stateArgs 6000
            if ($r.Out -notmatch 'device') {
                $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', 'connect', $script:adbSerial)) 8000
                $r = Invoke-Wsl $stateArgs 6000
            }
            if ($r.Code -eq 0 -and $r.Out -match 'device') {
                $linuxDex = ConvertTo-WslPath $dex
                $linuxPng = ConvertTo-WslPath $localPng
                $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'push', $linuxDex, $remoteDex)) $script:adbTimeoutMs
                $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon $($app.Package) $remotePng"
                $res = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'shell', $cmd)) $script:adbTimeoutMs
                if ($res.Out -match 'OK') {
                    $null = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'pull', $remotePng, $linuxPng)) $script:adbTimeoutMs
                    if (Test-Path -LiteralPath $localPng) { $ok = $true }
                }
            }
        } catch { }
    }

    if ($ok) {
        try {
            Convert-PngToIco $localPng $ico
            Remove-Item -LiteralPath $localPng -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $ico) { return [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($ico)) }
        } catch { }
    }
    Remove-Item -LiteralPath $localPng -Force -ErrorAction SilentlyContinue
    if (-not $ok) { $script:iconAdbOffline = $true }
    return [System.Windows.Media.Imaging.BitmapFrame]::Create([Uri]::new($generic))
}

function Update-AppShortcutIconAsync($app, [string]$lnkPath) {
    $generic = Join-Path $script:baseDir 'assets\android.ico'
    $dex = Join-Path $script:baseDir 'assets\winoid-icon.dex'
    $worker = Join-Path $script:baseDir 'assets\iconjob.ps1'
    if (-not (Test-Path -LiteralPath $dex) -or -not (Test-Path -LiteralPath $worker) -or -not (Test-Path -LiteralPath $lnkPath)) { return }
    $iconsDir = Join-Path $script:dataRoot 'icons'
    $ico = Join-Path $iconsDir ($app.Package + '.ico')

    try {
        $args = @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $worker,
            '-Package', $app.Package,
            '-Serial', $script:adbSerial,
            '-WslExe', $script:wsl,
            '-Distro', $script:wslDistro,
            '-Dex', $dex,
            '-Ico', $ico,
            '-Lnk', $lnkPath,
            '-Generic', $generic
        )
        # Start-Process joins -ArgumentList with spaces and does not quote
        # paths, and the Winoid folder can contain spaces.
        $quoted = @($args | ForEach-Object { '"' + ([string]$_) + '"' })
        Start-Process -FilePath 'pwsh.exe' -ArgumentList $quoted -WindowStyle Hidden | Out-Null
    } catch { }
}

function New-AppShortcut($app) {
    if ($null -eq $app) { return }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $safe = ($app.Name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $app.Package }
    if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64).Trim() }

    $target = Join-Path $script:baseDir 'Winoid.cmd'
    $arguments = '-Launch "' + $app.Package + '"'
    $shell = New-Object -ComObject WScript.Shell
    $lnk = Join-Path $desktop ($safe + '.lnk')
    if (Test-Path -LiteralPath $lnk) {
        try {
            $old = $shell.CreateShortcut($lnk)
            if ($old.TargetPath -ne $target) {
                $lnk = Join-Path $desktop ($safe + ' (' + $app.Package + ').lnk')
            }
        } catch { }
    }

    $generic = Join-Path $script:baseDir 'assets\android.ico'
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $target
    $sc.Arguments = $arguments
    $sc.WorkingDirectory = $script:baseDir
    if (Test-Path -LiteralPath $generic) { $sc.IconLocation = "$generic,0" }
    $sc.Description = "$($app.Name) — Android-приложение (Winoid)"
    $sc.Save()
    Set-Footer "Ярлык «$([System.IO.Path]::GetFileNameWithoutExtension($lnk))» создан. Обновляю иконку приложения…"
    Update-AppShortcutIconAsync $app $lnk
}

function Set-PendingLaunch([string]$target) {
    if ([string]::IsNullOrWhiteSpace($target)) { return }
    $script:pendingLaunch = $target
    $script:pendingLaunchTries = 0
    $script:pendingLaunchUntil = (Get-Date).AddMinutes(5)
    $script:pendingAppsAt = (Get-Date).AddSeconds(2)
    Set-Footer "Жду Android, чтобы открыть $target…"
}

# A shortcut can start Winoid while Android/Waydroid is still booting. Keep
# the request until the app list appears instead of dropping it on the floor.
function Try-PendingLaunch {
    if ([string]::IsNullOrWhiteSpace($script:pendingLaunch)) { return }
    if ((Get-Date) -gt $script:pendingLaunchUntil) {
        $target = $script:pendingLaunch
        $script:pendingLaunch = ''
        Write-WinoidLog "pending launch expired: $target"
        Set-Footer "Не удалось открыть ${target}: Android не показал приложение за 5 минут."
        return
    }
    if (-not $script:sessionRunning) { return }
    if ($null -ne $script:launchState -and -not $script:launchState.Wrapped) { return }

    $target = $script:pendingLaunch
    $app = $script:apps | Where-Object { $_.Package -eq $target -or $_.Name -eq $target } | Select-Object -First 1
    if ($null -eq $app) {
        # The package list can be incomplete for a while on a cold boot. Keep
        # refreshing until the deadline instead of giving up after a few tries.
        if ((Get-Date) -ge $script:pendingAppsAt) {
            $script:pendingAppsAt = (Get-Date).AddSeconds(5)
            $script:pendingLaunchTries++
            Invoke-Safe 'pending.refresh' { Refresh-Apps }
        }
        return
    }
    $script:pendingLaunch = ''
    Write-WinoidLog "pending launch: $target (after $($script:pendingLaunchTries) refresh(es))"
    Start-AppLaunch $app
}

function Process-Requests {
    if (-not (Test-Path -LiteralPath $script:requestDir)) { return }
    $files = @(Get-ChildItem -LiteralPath $script:requestDir -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object CreationTime)
    foreach ($file in $files) {
        $req = $null
        try { $req = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { }
        Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
        if ($null -eq $req) { continue }
        if (((Get-Date) - $file.CreationTime).TotalMinutes -gt 10) { continue }

        try {
            $target = [string]$req.target
            if ($req.action -eq 'install') {
                if ($target -and (Test-Path -LiteralPath $target)) { Install-Apk $target }
                else { Set-Footer 'Ярлык: APK-файл не найден.' }
                continue
            }

            $app = $script:apps | Where-Object { $_.Package -eq $target -or $_.Name -eq $target } | Select-Object -First 1
            if (-not $app) {
                Refresh-Apps
                $app = $script:apps | Where-Object { $_.Package -eq $target -or $_.Name -eq $target } | Select-Object -First 1
            }
            if ($app) { Start-AppLaunch $app }
            elseif ($target) { Set-PendingLaunch $target }
        } catch {
            Write-WinoidLog ("ERROR request {0}: {1}" -f $file.Name, $_.Exception.ToString())
            Show-InternalError $_.Exception.Message
        }
    }
}

$requestTimer = [System.Windows.Threading.DispatcherTimer]::new()
$requestTimer.Interval = [TimeSpan]::FromSeconds(1)
$requestTimer.Add_Tick({ Invoke-Safe 'requestTimer' { Process-Requests; Try-PendingLaunch } })

$driveTimer = [System.Windows.Threading.DispatcherTimer]::new()
$driveTimer.Interval = [TimeSpan]::FromSeconds(2)
$driveTimer.Add_Tick({
    Invoke-Safe 'driveTimer' {
        $driveTimer.Stop()
        Mount-AndroidDrive | Out-Null
    }
})

$sessionTimer = [System.Windows.Threading.DispatcherTimer]::new()
$sessionTimer.Interval = [TimeSpan]::FromSeconds(2)
$sessionTimer.Add_Tick({
    Invoke-Safe 'sessionTimer' {
    $script:sessionTicks += 2
    $loaderElapsed.Text = "$($script:sessionTicks) сек"

    if (-not $script:sessionWaiting) {
        if ($null -eq $script:sessionJob) {
            $script:sessionWaiting = $true
            $loaderSub.Text = 'Android загружается…'
            return
        }
        $state = 'Unknown'
        try { $state = [string]$script:sessionJob.State } catch { }
        if ($state -in @('Completed', 'Failed', 'Stopped')) {
            $out = ''
            try { $out = @(Receive-Job -Job $script:sessionJob -ErrorAction SilentlyContinue) | Out-String } catch { }
            Write-WinoidLog "session job $state`: $out"
            Remove-Job -Job $script:sessionJob -Force -ErrorAction SilentlyContinue
            $script:sessionJob = $null
            $script:sessionWaiting = $true
            $loaderSub.Text = 'Android загружается…'
        }
        return
    }

    if ((Get-WaydroidStatus) -eq 'RUNNING') {
        $sessionTimer.Stop()
        $loader.Hide()
        Test-Session | Out-Null
        $compatNote = ''
        try {
            if ($script:armCompat) {
                if (Set-ArmCompatMode $true) {
                    # A fresh Android session has no running apps, so nothing
                    # needs restarting even if the property was changed.
                    $script:armCompatDirty = $false
                    $script:armCompatRestarted = @{}
                } else {
                    $compatNote = ' Режим совместимости ARM включить не удалось.'
                }
            } else {
                $script:armCompatApplied = $false
                $script:armCompatDirty = $false
                $script:armCompatRestarted = @{}
            }
        } catch {
            $compatNote = ' Режим совместимости ARM включить не удалось.'
            Write-WinoidLog ("ERROR ARM compat on session: " + $_.Exception.ToString())
        }
        Refresh-Apps
        Initialize-Adb
        Set-Footer ('Android запущен.' + $compatNote)
        if ($script:pendingAndroidWindow) {
            $pending = $script:pendingAndroidWindow
            $script:pendingAndroidWindow = $null
            Start-AndroidWindow $pending.Package $pending.Title
        }
        if ($script:pendingLaunch) {
            # Give a shortcut request a fresh window once Android is really up:
            # booting can consume most of the original deadline.
            $script:pendingLaunchUntil = (Get-Date).AddMinutes(3)
            $script:pendingAppsAt = (Get-Date).AddSeconds(1)
        }
        Try-PendingLaunch
    } elseif ($script:sessionTicks -ge 90) {
        $sessionTimer.Stop()
        $loader.Hide()
        Test-Session | Out-Null
        if ($script:pendingLaunch) {
            Write-WinoidLog "pending launch cancelled: Android did not start"
            $script:pendingLaunch = ''
        }
        Set-Footer 'Android не запустился за 90 секунд. Проверьте журнал Waydroid.'
    }
    }
})

# Opens a standalone Android window (launcher or Settings). In Waydroid
# multi-window mode `show-full-ui` is a no-op, so the launcher is the
# closest thing to "Android as a whole" that still works.
function Start-AndroidWindow([string]$package, [string]$title) {
    if (-not (Test-Backend)) {
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    if (-not $script:sessionRunning) {
        $script:pendingAndroidWindow = [pscustomobject]@{ Package = $package; Title = $title }
        Start-Session
        return
    }
    $app = $script:apps | Where-Object { $_.Package -eq $package } | Select-Object -First 1
    if ($app) {
        Start-AppLaunch $app
        return
    }
    $cmd = "export DISPLAY=:0 WAYLAND_DISPLAY=wayland-0 XDG_RUNTIME_DIR=/run/user/`$(id -u); waydroid app launch $package"
    try {
        Start-WslDetached ((Get-WslBase) + @('--', 'bash', '-lc', $cmd))
        Set-Footer "Открываю $title…"
    } catch {
        Write-WinoidLog ("ERROR open " + $package + ": " + $_.Exception.ToString())
        Set-Footer "Не удалось открыть $title`: $($_.Exception.Message)"
    }
}

function Start-Session {
    param([switch]$Restart)
    if (-not (Test-Backend)) {
        $backendBtn.Visibility = 'Visible'
        Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android» или откройте README.'
        return
    }
    if ($null -ne $script:installJob -and $installTimer.IsEnabled) {
        Set-Footer 'Сначала дождитесь окончания установки APK.'
        return
    }
    if ($null -ne $script:sessionJob) {
        $state = 'Unknown'
        try { $state = [string]$script:sessionJob.State } catch { }
        if ($state -notin @('Completed', 'Failed', 'Stopped')) {
            $loader.Show()
            Set-Footer 'Android уже запускается…'
            return
        }
        Remove-Job -Job $script:sessionJob -Force -ErrorAction SilentlyContinue
        $script:sessionJob = $null
    }
    $script:sessionRunning = $false
    $script:sessionTicks = 0
    $script:sessionWaiting = $false
    $loaderTitle.Text = $(if ($Restart) { 'Перезапуск Android' } else { 'Запуск Android' })
    $loaderSub.Text = $(if ($Restart) { 'Перезапускаю сессию Waydroid, чтобы окна снова подключились к графике WSL.' } else { 'Поднимаю контейнер и сессию Waydroid. Это займёт до минуты.' })
    $loaderElapsed.Text = '0 сек'
    $loader.Show()
    $loaderBar.IsIndeterminate = $true
    Set-Footer $(if ($Restart) { 'Перезапуск Android…' } else { 'Запуск Android…' })
    $jobWsl = $script:wsl
    $jobDistro = $script:wslDistro
    $action = $(if ($Restart) { 'restart' } else { 'start' })
    try {
        $script:sessionJob = Start-Job -ScriptBlock {
            param($wslExe, $distro, $verb)
            $wslArgs = @()
            if (-not [string]::IsNullOrWhiteSpace($distro)) { $wslArgs += @('-d', $distro) }
            & $wslExe @wslArgs -- bash -lc "systemctl --user $verb waydroid-session.service" 2>&1
        } -ArgumentList $jobWsl, $jobDistro, $action
    } catch {
        Write-WinoidLog ("ERROR session start: " + $_.Exception.ToString())
        $script:sessionJob = $null
        $loader.Hide()
        Set-Footer "Не удалось запустить Android: $($_.Exception.Message)"
        return
    }
    $sessionTimer.Start()
}

# --- events ---

$searchBox.Add_TextChanged({ Invoke-Safe 'filter' { Update-AppFilter } })
$refreshBtn.Add_Click({
    Invoke-Safe 'refresh' {
        Test-Session | Out-Null
        Refresh-Apps
    }
})
$appsList.Add_SelectionChanged({
    Invoke-Safe 'selection' {
        $sel = $appsList.SelectedItem
        $launchBtn.IsEnabled = ($null -ne $sel)
        $shortcutBtn.IsEnabled = ($null -ne $sel)
        $uninstallBtn.IsEnabled = ($null -ne $sel)
        # Restore the mode remembered for this app, if any.
        if ($script:rememberMode -and $null -ne $sel) {
            $pkg = [string]$sel.Package
            if ($script:appModes.ContainsKey($pkg)) {
                $idx = [int]$script:appModes[$pkg]
                if ($idx -ge 0 -and $idx -lt $sizeBox.Items.Count) { $sizeBox.SelectedIndex = $idx }
            }
        }
    }
})
$rememberModeCheck.Add_Checked({ Invoke-Safe 'rememberMode' { $script:rememberMode = $true; Save-AppModes } })
$rememberModeCheck.Add_Unchecked({ Invoke-Safe 'rememberMode' { $script:rememberMode = $false; Save-AppModes } })
$appsList.Add_MouseDoubleClick({
    Invoke-Safe 'doubleClick' {
        if ($null -ne $appsList.SelectedItem) { Start-AppLaunch $appsList.SelectedItem }
    }
})
$launchBtn.Add_Click({ Invoke-Safe 'launchBtn' { Start-AppLaunch $appsList.SelectedItem } })
$shortcutBtn.Add_Click({ Invoke-Safe 'shortcutBtn' { New-AppShortcut $appsList.SelectedItem } })
$driveBtn.Add_Click({ Invoke-Safe 'driveBtn' { Mount-AndroidDrive -Open | Out-Null } })
$myComputerBtn.Add_Click({ Invoke-Safe 'myComputerBtn' {
    try {
        Start-Process -FilePath 'explorer.exe' -ArgumentList 'shell:MyComputerFolder'
        Set-Footer 'Открыл «Этот компьютер» в проводнике Windows.'
    } catch {
        Set-Footer "Не удалось открыть проводник: $($_.Exception.Message)"
    }
} })
$deleteApkBtn.Add_Click({ Invoke-Safe 'deleteApkBtn' {
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Выберите APK-файл для удаления'
    $dlg.Filter = 'Android package (*.apk)|*.apk'
    if ($dlg.ShowDialog($window) -eq $true) {
        $file = $dlg.FileName
        $answer = [System.Windows.MessageBox]::Show("Удалить файл?`n$file", 'Winoid — удаление APK', 'YesNo', 'Warning', 'No')
        if ($answer -eq [System.Windows.MessageBoxResult]::Yes) {
            try {
                Remove-Item -LiteralPath $file -Force
                Write-WinoidLog "deleted apk: $file"
                Set-Footer 'APK-файл удалён.'
            } catch { Set-Footer "Не удалось удалить файл: $($_.Exception.Message)" }
        }
    }
} })
$profileBox.Add_SelectionChanged({
    Invoke-Safe 'profileChange' {
        if ($script:profileLoading) { return }
        $name = [string]$profileBox.SelectedItem
        if ([string]::IsNullOrWhiteSpace($name) -or $name -eq $script:activeProfile) { return }
        $script:profiles[$script:activeProfile] = [pscustomobject]@{ wslDistro = $script:wslDistro; adbSerial = $script:adbSerial }
        $script:activeProfile = $name
        $p = $script:profiles[$name]
        if ($p.wslDistro) { $script:wslDistro = [string]$p.wslDistro }
        if ($p.adbSerial) { $script:adbSerial = [string]$p.adbSerial }
        Save-Profiles
        Set-Footer "Профиль «$name» выбран. Перезапустите Winoid."
    }
})
$newProfileBtn.Add_Click({
    Invoke-Safe 'newProfile' {
        Add-Type -AssemblyName Microsoft.VisualBasic
        $name = [string][Microsoft.VisualBasic.Interaction]::InputBox('Имя нового профиля:', 'Winoid', 'profile2')
        if ([string]::IsNullOrWhiteSpace($name)) { return }
        $script:profiles[$name] = [pscustomobject]@{ wslDistro = $script:wslDistro; adbSerial = $script:adbSerial }
        Save-Profiles
        [void]$profileBox.Items.Add($name)
        $profileBox.SelectedItem = $name
        Set-Footer "Профиль «$name» создан."
    }
})
$langBtn.Add_Click({ Invoke-Safe 'langBtn' {
    $script:language = $(if ($script:language -eq 'en') { 'ru' } else { 'en' })
    Save-ArmCompatSetting
    Apply-Language
    $langBtn.Content = $(if ($script:language -eq 'en') { 'EN / RU' } else { 'RU / EN' })
    Set-Footer $(if ($script:language -eq 'en') { 'Language: English' } else { 'Язык: русский' })
} })
$exportCfgBtn.Add_Click({ Invoke-Safe 'exportCfg' {
    $dlg = [Microsoft.Win32.SaveFileDialog]::new()
    $dlg.Title = 'Экспорт настроек Winoid'
    $dlg.Filter = 'JSON (*.json)|*.json'
    $dlg.FileName = 'winoid-settings.json'
    if ($dlg.ShowDialog($window) -eq $true) {
        $bundle = [pscustomobject]@{
            config = Read-JsonFile (Join-Path $script:dataRoot 'config.json')
            apps = Read-JsonFile (Join-Path $script:dataRoot 'apps.json')
            modes = Read-JsonFile (Join-Path $script:dataRoot 'modes.json')
        }
        $bundle | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $dlg.FileName -Encoding utf8NoBOM
        Set-Footer 'Настройки экспортированы.'
    }
} })
$importCfgBtn.Add_Click({ Invoke-Safe 'importCfg' {
    $dlg = [Microsoft.Win32.OpenFileDialog]::new()
    $dlg.Title = 'Импорт настроек Winoid'
    $dlg.Filter = 'JSON (*.json)|*.json'
    if ($dlg.ShowDialog($window) -eq $true) {
        $b = Get-Content -LiteralPath $dlg.FileName -Raw -Encoding utf8 | ConvertFrom-Json
        foreach ($name in @('config', 'apps', 'modes')) {
            $prop = $b.PSObject.Properties[$name]
            if ($null -ne $prop -and $null -ne $prop.Value) {
                $prop.Value | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $script:dataRoot ($name + '.json')) -Encoding utf8NoBOM
            }
        }
        Set-Footer 'Настройки импортированы. Перезапустите Winoid.'
    }
} })
$diagBtn.Add_Click({ Invoke-Safe 'diagBtn' { Show-Diagnostics } })
$updateBtn.Add_Click({ Invoke-Safe 'updateBtn' {
    Set-Footer 'Проверка обновлений…'
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/Sergey35853/winoid/releases/latest' -TimeoutSec 15 -Headers @{ 'User-Agent' = 'Winoid' }
        $tag = [string]$release.tag_name
        if ($tag -match '(\d+\.\d+\.\d+)') {
            $latest = [version]$matches[1]
            if ($latest -gt [version]$script:appVersion) {
                Set-Footer "Доступна версия $tag — открываю страницу релиза."
                if ($release.html_url) { Start-Process ([string]$release.html_url) }
            } else {
                Set-Footer "У вас актуальная версия $($script:appVersion)."
            }
        }
    } catch { Set-Footer "Не удалось проверить обновления: $($_.Exception.Message)" }
} })
$diagRefreshBtn.Add_Click({ Invoke-Safe 'diagRefresh' { Show-Diagnostics } })
$diagOpenLogBtn.Add_Click({ Invoke-Safe 'diagLog' {
    $log = Join-Path $script:dataRoot 'winoid.log'
    if (Test-Path -LiteralPath $log) { Start-Process -FilePath 'notepad.exe' -ArgumentList $log }
} })
$diagCloseBtn.Add_Click({ Invoke-Safe 'diagClose' { $diagWindow.Hide() } })
$window.Add_KeyDown({
    param($sender, $e)
    try {
        if ($e.Key -eq 'F1') { Show-Diagnostics; $e.Handled = $true; return }
        $ctrl = ($e.KeyboardDevice.Modifiers -band [System.Windows.Input.ModifierKeys]::Control) -ne 0
        if ($ctrl -and $e.Key -eq 'R') {
            Invoke-Safe 'hotkey.refresh' { Test-Session | Out-Null; Refresh-Apps }
            $e.Handled = $true; return
        }
        if ($e.Key -eq 'Delete' -and $appsList.SelectedItems.Count -gt 0) {
            $uninstallBtn.RaiseEvent([System.Windows.RoutedEventArgs]::new([System.Windows.Controls.ButtonBase]::ClickEvent))
            $e.Handled = $true
        }
    } catch { }
})
$uninstallBtn.Add_Click({ Invoke-Safe 'uninstallBtn' {
    $apps = @($appsList.SelectedItems)
    if ($apps.Count -eq 0) { return }
    $names = ($apps | ForEach-Object { '• ' + [string]$_.Name + ' (' + [string]$_.Package + ')' }) -join "`n"
    $answer = [System.Windows.MessageBox]::Show("Удалить выбранные приложения?`n$names`n`nПриложения и их данные будут удалены из Android.", 'Winoid — удаление приложения', 'YesNo', 'Warning', 'No')
    if ($answer -ne [System.Windows.MessageBoxResult]::Yes) { return }
    if (-not (Ensure-WaydroidAwake)) { Set-Footer 'Android не отвечает — удаление отменено.'; return }
    $done = 0; $failed = 0
    foreach ($app in $apps) {
        $name = [string]$app.Name
        $pkg = [string]$app.Package
        Set-Footer "Удаление $name…"
        try {
            $r = Invoke-Wsl ((Get-WslBase) + @('--', 'adb', '-s', $script:adbSerial, 'uninstall', $pkg)) 45000
            $out = (($r.Out + ' ' + $r.Err) -replace "`r?`n", ' ').Trim()
            Write-WinoidLog "uninstall $pkg : $out"
            if ($out -match 'Success') {
                $done++
                $ico = Join-Path (Join-Path $script:dataRoot 'icons') ($pkg + '.ico')
                Remove-Item -LiteralPath $ico -Force -ErrorAction SilentlyContinue
                $safe = ([string]$app.Name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
                if ([string]::IsNullOrWhiteSpace($safe)) { $safe = $pkg }
                if ($safe.Length -gt 64) { $safe = $safe.Substring(0, 64).Trim() }
                $desktop = [Environment]::GetFolderPath('Desktop')
                foreach ($lnkName in @(($safe + '.lnk'), ($safe + ' (' + $pkg + ').lnk'))) {
                    Remove-Item -LiteralPath (Join-Path $desktop $lnkName) -Force -ErrorAction SilentlyContinue
                }
                if ($script:appModes.ContainsKey($pkg)) { $script:appModes.Remove($pkg); Save-AppModes }
            } else { $failed++ }
        } catch {
            $failed++
            Write-WinoidLog ("ERROR uninstall: " + $_.Exception.ToString())
        }
    }
    # Drop removed packages from the cached list in one pass.
    $cache = Join-Path $script:dataRoot 'apps.json'
    if (Test-Path -LiteralPath $cache) {
        try {
            $gone = @($apps | ForEach-Object { [string]$_.Package })
            $left = @(Get-Content -LiteralPath $cache -Raw -Encoding utf8 | ConvertFrom-Json | Where-Object { $gone -notcontains [string]$_.Package })
            $left | ConvertTo-Json -Depth 3 -Compress | Set-Content -LiteralPath $cache -Encoding utf8NoBOM
        } catch { }
    }
    Set-Footer "Удалено: $done. Не удалось: $failed."
    Refresh-Apps
} })
$installBtn.Add_Click({
    Invoke-Safe 'installBtn' {
        $dlg = [Microsoft.Win32.OpenFileDialog]::new()
        $dlg.Title = 'Выберите APK'
        $dlg.Filter = 'Android package (*.apk)|*.apk|Все файлы (*.*)|*.*'
        if ($dlg.ShowDialog($window) -eq $true) { Install-Apk $dlg.FileName }
    }
})
$backendBtn.Add_Click({
    Invoke-Safe 'backendBtn' {
        $setup = Join-Path $script:baseDir 'Setup-Backend.ps1'
        if (-not (Test-Path -LiteralPath $setup)) { $setup = Join-Path $script:baseDir 'installer\Setup-Backend.ps1' }
        if (Test-Path -LiteralPath $setup) {
            Start-Process -FilePath 'pwsh.exe' -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$setup`"" -WorkingDirectory $script:baseDir
            Set-Footer 'Открыл настройку Android в отдельном окне.'
        } else {
            Start-Process 'https://github.com/Sergey35853/winoid/blob/main/README.md#как-поднять-бэкенд'
            Set-Footer 'Открыл инструкцию по настройке бэкенда в браузере.'
        }
    }
})
$fullUiBtn.Add_Click({ Invoke-Safe 'restart' { Start-Session -Restart } })
$settingsBtn.Add_Click({ Invoke-Safe 'settingsBtn' { Start-AndroidWindow 'com.android.settings' 'Настройки Android' } })
$stretchFillCheck.Add_Checked({ Invoke-Safe 'stretchOn' {
    $script:stretchFill = $true; Save-ArmCompatSetting
    foreach ($wr in @($script:wrappers)) { try { $wr.Image.Stretch = 'Fill' } catch { } }
    Set-Footer 'Картинка растягивается по окну.'
} })
$stretchFillCheck.Add_Unchecked({ Invoke-Safe 'stretchOff' {
    $script:stretchFill = $false; Save-ArmCompatSetting
    foreach ($wr in @($script:wrappers)) { try { $wr.Image.Stretch = 'Uniform' } catch { } }
    Set-Footer 'Пропорции картинки сохранены.'
} })
$navInsetCheck.Add_Checked({ Invoke-Safe 'navInsetOn' {
    $script:fallbackNavInset = 48; Save-ArmCompatSetting
    Set-Footer 'Нижняя полоса Android будет обрезаться в новых окнах.'
} })
$navInsetCheck.Add_Unchecked({ Invoke-Safe 'navInsetOff' {
    $script:fallbackNavInset = 0; Save-ArmCompatSetting
    Set-Footer 'Нижняя полоса Android будет показана в новых окнах.'
} })
$hideCaptionCheck.Add_Checked({ Invoke-Safe 'captionOn' {
    $script:hideCaption = $true; Save-ArmCompatSetting
    Set-Footer 'Заголовок Android будет скрыт в новых окнах.'
} })
$hideCaptionCheck.Add_Unchecked({ Invoke-Safe 'captionOff' {
    $script:hideCaption = $false; Save-ArmCompatSetting
    Set-Footer 'Заголовок Android будет показан в новых окнах.'
} })
$armCompatCheck.Add_Checked({
    Invoke-Safe 'armCompatOn' {
        $script:armCompat = [bool]$armCompatCheck.IsChecked
        Save-ArmCompatSetting
        if (-not $script:sessionRunning) {
            Set-Footer 'Режим совместимости ARM включён. Применится при запуске Android.'
            return
        }
        if (Set-ArmCompatMode $true) {
            Set-Footer 'Режим совместимости ARM включён. Уже открытые игры закройте и откройте заново.'
        } else {
            Set-Footer 'Не удалось включить режим ARM. Подробности: %LOCALAPPDATA%\Winoid\winoid.log'
        }
    }
})
$armCompatCheck.Add_Unchecked({
    Invoke-Safe 'armCompatOff' {
        $script:armCompat = [bool]$armCompatCheck.IsChecked
        Save-ArmCompatSetting
        if (-not $script:sessionRunning) {
            Set-Footer 'Режим совместимости ARM выключен.'
            return
        }
        if (Set-ArmCompatMode $false) {
            Set-Footer 'Режим совместимости ARM выключен. Уже открытые игры закройте и откройте заново.'
        } else {
            Set-Footer 'Не удалось выключить режим ARM. Подробности: %LOCALAPPDATA%\Winoid\winoid.log'
        }
    }
})
$showWindowBtn.Add_Click({
    Invoke-Safe 'showWindowBtn' {
        if ($script:launchState) {
            $w = Find-WrapperByPackage $script:launchState.App.Package
            if ($null -ne $w) { Focus-Wrapper $w }
        }
        $loader.Hide()
    }
})
$hideLoaderBtn.Add_Click({
    Invoke-Safe 'hideLoaderBtn' {
        $loader.Hide()
        $launchTimer.Stop()
        Set-Footer 'Индикатор скрыт. Приложение продолжает запускаться.'
    }
})
$window.Add_Drop({
    param($sender, $e)
    Invoke-Safe 'drop' {
        if ($e.Data.GetDataPresent([System.Windows.DataFormats]::FileDrop)) {
            $files = $e.Data.GetData([System.Windows.DataFormats]::FileDrop)
            foreach ($f in $files) {
                if ($f -like '*.apk') { Install-Apk $f; break }
            }
        }
    }
})
$window.Add_Closing({
    $script:exiting = $true
    Write-WinoidLog ("manager closing (user=" + $script:quitByUser + ")")
    try { if ($null -ne $script:tray) { $script:tray.Visible = $false; $script:tray.Dispose() } } catch { }
    try { if ($script:quitByUser) { [System.IO.File]::WriteAllText($script:quitPath, (Get-Date).ToString('o')) } } catch { }
    try { [System.IO.File]::WriteAllText($script:shutdownPath, (Get-Date).ToString('o')) } catch { }
    Invoke-Safe 'closing.timers' {
        $launchTimer.Stop()
        $installTimer.Stop()
        $sessionTimer.Stop()
        $requestTimer.Stop()
        $driveTimer.Stop()
        $script:frameTimer.Stop()
        $script:bounceTimer.Stop()
        $iconTimer.Stop()
        $appsRefreshTimer.Stop()
        $startupProbeTimer.Stop()
        if ($null -ne $script:startupJob) {
            try { Stop-Job -Job $script:startupJob -Force -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $script:startupJob -Force -ErrorAction SilentlyContinue } catch { }
            $script:startupJob = $null
        }
        if ($null -ne $script:appsJob) {
            try { Stop-Job -Job $script:appsJob -Force -ErrorAction SilentlyContinue } catch { }
            try { Remove-Job -Job $script:appsJob -Force -ErrorAction SilentlyContinue } catch { }
            $script:appsJob = $null
        }
    }
    Invoke-Safe 'closing.drive' { Disconnect-AndroidDrive }
    foreach ($w in @($script:wrappers)) {
        Invoke-Safe 'closing.wrapper' {
            Restore-Source $w
            $w.Closed = $true
            foreach ($pane in @($w.Panes)) { try { $pane.Grab.Dispose() } catch { } }
            try { $w.Window.Close() } catch { }
        }
    }
    Invoke-Safe 'closing.adb' {
        if ($script:adb) { try { $script:adb.Dispose() } catch { }; $script:adb = $null }
    }
    Invoke-Safe 'closing.jobs' {
        if ($script:installJob) { Remove-Job -Job $script:installJob -Force -ErrorAction SilentlyContinue }
        if ($script:sessionJob) { Remove-Job -Job $script:sessionJob -Force -ErrorAction SilentlyContinue }
        if ($script:wslKeepAlive) {
            try { if (-not $script:wslKeepAlive.HasExited) { $script:wslKeepAlive.Kill() } } catch { }
            try { $script:wslKeepAlive.Dispose() } catch { }
            $script:wslKeepAlive = $null
        }
    }
    try { $loader.Close() } catch { }
})
$window.Add_Closed({
    Invoke-Safe 'closed' {
        $script:exiting = $true
        $window.Dispatcher.InvokeShutdown()
    }
})
$script:startupJob = $null
$startupProbeTimer = [System.Windows.Threading.DispatcherTimer]::new()
$startupProbeTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$startupProbeTimer.Add_Tick({
    Invoke-Safe 'startupProbe' {
        if ($null -eq $script:startupJob) { $startupProbeTimer.Stop(); return }
        $state = 'Unknown'
        try { $state = [string]$script:startupJob.State } catch { }
        if ($state -notin @('Completed', 'Failed', 'Stopped')) { return }
        $startupProbeTimer.Stop()
        $r = $null
        try { $r = @(Receive-Job -Job $script:startupJob -ErrorAction SilentlyContinue) | Select-Object -First 1 } catch { }
        try { Remove-Job -Job $script:startupJob -Force -ErrorAction SilentlyContinue } catch { }
        $script:startupJob = $null
        if ($null -ne $r) {
            $script:sessionRunning = ([string]$r.Session -eq 'RUNNING')
            $script:containerState = [string]$r.Container
            Update-ArmCompatUi
            if ($script:sessionRunning) {
                Set-Status 'Android работает' '#3DDC84'
                $backendBtn.Visibility = 'Collapsed'
            } elseif (-not $r.Backend) {
                Set-Status 'Бэкенд не настроен' '#E5484D'
                $backendBtn.Visibility = 'Visible'
                Set-Footer 'Waydroid не найден в WSL. Нажмите «Настроить Android».'
            } else {
                Set-Status 'Android остановлен' '#F5A623'
                $backendBtn.Visibility = 'Collapsed'
            }
            # Always try to refresh the list; even a frozen Android should
            # leave the cached list visible.
            Invoke-Safe 'startup.apps' { Refresh-Apps }
            if (-not $script:sessionRunning) { Invoke-Safe 'startup.session' { Start-Session } }
        }
    }
})

function Start-StartupProbe {
    if ($null -ne $script:startupJob) { return }
    $script:startupJob = Start-Job -ScriptBlock {
        param([string]$Wsl, [string]$Distro)
        function Invoke-W([string[]]$Args, [int]$Ms) {
            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName = $Wsl
            foreach ($a in $Args) { [void]$psi.ArgumentList.Add($a) }
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
            $p = [System.Diagnostics.Process]::Start($psi)
            $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
            if (-not $p.WaitForExit($Ms)) { try { $p.Kill() } catch { }; return @{ Out = ''; Err = 'timeout' } }
            @{ Out = $o.Result; Err = $e.Result }
        }
        $base = @(); if ($Distro) { $base = @('-d', $Distro) }
        $check = Invoke-W ($base + @('--', 'bash', '-lc', 'command -v waydroid >/dev/null 2>&1 && echo WINOID_BACKEND_OK')) 10000
        $backend = ($check.Out -match 'WINOID_BACKEND_OK')
        $session = 'STOPPED'; $container = 'UNKNOWN'
        if ($backend) {
            $r = Invoke-W ($base + @('-u', 'root', '--', 'waydroid', 'status')) 15000
            if ($r.Out -match '(?m)^Session:\s*(\S+)') { $session = $matches[1] }
            if ($r.Out -match '(?m)^Container:\s*(\S+)') { $container = $matches[1] }
        }
        [pscustomobject]@{ Backend = $backend; Session = $session; Container = $container }
    } -ArgumentList @($script:wsl, $script:wslDistro)
    $startupProbeTimer.Start()
}

$window.Add_Loaded({
    # Never start with an empty list: show the last known apps immediately,
    # then replace them when the background probe finishes.
    Invoke-Safe 'loaded.cache' {
        if (@($script:apps).Count -eq 0) {
            $script:apps = @(Get-CachedLauncherApps)
            Update-AppFilter
            if (@($script:apps).Count -gt 0) { Set-Footer "Приложений: $($script:apps.Count) (кэш)" }
        }
    }
    Invoke-Safe 'loaded.keepalive' { Start-WslKeepAlive }
    Invoke-Safe 'loaded.restore' { Restore-OrphanedParkedWindows }
    Start-StartupProbe
    Invoke-Safe 'loaded.drive' { $driveTimer.Start() }
    if ($Install) {
        Invoke-Safe 'loaded.install' {
            if (Test-Path -LiteralPath $Install) { Install-Apk $Install }
            else { Set-Footer "APK не найден: $Install" }
        }
    }
    if ($Launch) {
        Invoke-Safe 'loaded.launch' {
            $app = $script:apps | Where-Object { $_.Package -eq $Launch -or $_.Name -eq $Launch } | Select-Object -First 1
            if ($app) { Start-AppLaunch $app } else { Set-PendingLaunch $Launch }
        }
    }
})
$loader.Add_Closing({
    param($sender, $e)
    if (-not $script:exiting) {
        $e.Cancel = $true
        $loader.Hide()
    }
})

$script:frameTimer.Start()
$requestTimer.Start()
$window.Show()
Set-WinoidDarkTitleBar $window
[System.Windows.Threading.Dispatcher]::Run()
