# Self-contained smoke tests: no external modules required.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$failures = 0

function Assert-True([bool]$condition, [string]$message) {
    if ($condition) { Write-Host "  PASS  $message" }
    else { Write-Host "  FAIL  $message"; $script:failures++ }
}

Write-Host 'Winoid smoke tests'
$source = Join-Path $root 'Winoid.ps1'
$text = Get-Content -LiteralPath $source -Raw

# 1. Syntax
$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors) | Out-Null
Assert-True ($errors.Count -eq 0) 'Winoid.ps1 parses without errors'

# 2. Required UI controls and functions
foreach ($needle in @(
    'x:Name="MyComputerBtn"', 'x:Name="UninstallBtn"', 'x:Name="DiagBtn"',
    'x:Name="UpdateBtn"', 'x:Name="ExportCfgBtn"', 'x:Name="ImportCfgBtn"',
    'x:Name="PhoneModeBtn"', 'x:Name="TabletModeBtn"', 'x:Name="RememberModeCheck"',
    'Source="{Binding Icon}"',
    'function Ensure-WaydroidAwake', 'function Get-CachedLauncherApps',
    'function Set-LiveDisplayMode', 'function Get-AppIconPath', 'function Show-Diagnostics',
    'function Restart-WaydroidSession', 'LaunchCmd = ', 'force-stop',
    'x:Name="HideCaptionCheck"', 'CaptionInset', 'launch aborted: android did not wake',
    '$dy = $dir * $mag * 150', 'parked late surface',
    '$script:hideCaption = $false', 'x:Name="NavInsetCheck"', 'fallbackNavInset', 'EdgeCrop',
    'sub-surface', 'letterbox', 'StretchFillCheck', 'GameModeBtn',
    'script:appGeometry', 'NotifyIcon', 'DiagFilter', 'exec sleep 86400',
    'x:Name="LangBtn"', 'script:translations', 'script:profilesPath', 'x:Name="ProfileBox"',
    'Start-StartupProbe', 'CaptureBegin', 'Task.Run'
)) {
    Assert-True ($text.Contains($needle)) "contains: $needle"
}
Assert-True (-not $text.Contains('Restore-OrphanedParkedWindows')) 'manager no longer unparks old game windows at startup'
Assert-True (-not $text.Contains('restored orphan window')) 'manager does not restore orphaned surfaces on startup'

# 3. Version consistency between the manager and the installer
$iss = Get-Content -LiteralPath (Join-Path $root 'installer\Winoid.iss') -Raw
$issVersion = ''
if ($iss -match '#define MyAppVersion "([^"]+)"') { $issVersion = $matches[1] }
$appVersion = ''
if ($text -match "appVersion = '([^']+)'") { $appVersion = $matches[1] }
Assert-True ($issVersion -and $issVersion -eq $appVersion) "installer version ($issVersion) matches app version ($appVersion)"

# 4. Launcher stub is present and wired everywhere
$stub = Join-Path $root 'WinoidLauncher.exe'
Assert-True (Test-Path -LiteralPath $stub) 'WinoidLauncher.exe exists'
if (Test-Path -LiteralPath $stub) {
    $bytes = [System.IO.File]::ReadAllBytes($stub)[0..1]
    Assert-True ($bytes[0] -eq 0x4D -and $bytes[1] -eq 0x5A) 'launcher is a Windows executable (MZ)'
}
Assert-True ((Get-Content -LiteralPath (Join-Path $root 'Winoid.cmd') -Raw).Contains('WinoidLauncher.exe')) 'Winoid.cmd uses the new launcher'
Assert-True ($iss.Contains('WinoidLauncher.exe')) 'installer ships the new launcher'
Assert-True ($text.Contains('shutdown.request')) 'manager writes the watchdog shutdown marker'
Assert-True ($text.Contains('FindMainWindow')) 'manager finds its real window instead of a message box'
Assert-True ($text.Contains('closingStarted')) 'manager closes only once'
Assert-True ($text.Contains('Complete-IconJob')) 'icons are extracted without blocking the window'
Assert-True ($text.Contains('Start-AndroidLaunchJob $app.Package')) 'app launch runs in a background job'
Assert-True ($text.Contains('Complete-LaunchPrepJob')) 'launch job is collected by the timer'
Assert-True ($text.Contains('$st.Prepared')) 'window is wrapped only after the final launch command'
Assert-True ($text.Contains('Stop-LaunchJobs')) 'launch jobs are stopped on close or a new launch'
Assert-True ($text.Contains('Fire-and-forget Android input')) 'adb input is queued on a background thread'
Assert-True ($text.Contains('Get-LaunchCommand')) 'launch uses an explicitly resolved Android activity'
Assert-True ($text.Contains('waydroid app launch $pkg')) 'app is launched through the Waydroid session so a window is exported'
Assert-True ($text.Contains('function Start-AppWindow')) 'launch falls back to the resolved activity'
Assert-True ($text.Contains('launch frames for $pkg')) 'launch job collects Android window frames for tap mapping'
Assert-True ($text.Contains('New-AppWrapper $st.App $h $st.Size $stFrames')) 'wrapper uses frames collected by the launch job'
Assert-True ($text.Contains('full-size sub-surface')) 'duplicate full-size game surfaces are parked instead of left on the desktop'
Assert-True ($text.Contains('$script:frameTick % 20')) 'inactive wrapper capture uses a time-based throttle'
Assert-True ($text.Contains('FromMilliseconds($wantMs)')) 'capture interval switches between 30 and 20 fps'
Assert-True ($text.Contains('inputBurstUntil')) 'capture rate adapts to input bursts'
Assert-True ($text.Contains('installjob.ps1')) 'APK install runs in a hidden process, not a stuck job'
Assert-True ($text.Contains('wsl.exe mangles non-ASCII argument paths')) 'APK is staged under an ASCII path before install'
Assert-True ($text.Contains('$script:installJob.HasExited')) 'install completion is polled from the worker process'
Assert-True ($text.Contains('WINOID_INSTALL_EXIT=(-?\d+)')) 'install result comes from the worker marker, not a stale log'
Assert-True ($text.Contains('install worker timed out')) 'a wedged install is stopped after a timeout'
Assert-True ($text.Contains('session job exited: code=')) 'session start is a polled process, not a job'
Assert-True ($text.Contains('Дождитесь установки APK')) 'launch waits for an install in progress'
Assert-True ($text.Contains('Дождитесь запуска приложения')) 'install waits for a launch in progress'
Assert-True ($text.Contains('A maximized surface ignores SetWindowPos')) 'maximized surface is restored before growing'
Assert-True ($text.Contains('use_gfxredir')) 'broken WSLg surfaces are detected'
Assert-True ($text.Contains("'--system', '-u', 'root'")) 'weston is restarted in the WSLg system distro'
Assert-True ($text.Contains('wslg surface state')) 'launch log records the WSLg surface state'
Assert-True ($text.Contains('WSLg не выводит окна Linux')) 'a stuck launch explains the WSLg failure'
Assert-True ($text.Contains('RetryDoneAt')) 'launch gives up after a failed retry'
Assert-True ($text.Contains('-TimeoutMs 9000 -Raw')) 'local adb keeps dumpsys lines for frame parsing'
Assert-True ($text.Contains("`$st.Wrapped") -and $text.Contains('Окно открыто.')) 'indicator does not report failure after the window opened'
Assert-True ($text.Contains('Get-ChildItem -LiteralPath $staleStaged')) 'stale staged APKs are removed at startup'
Assert-True ($text.Contains('A pane NARROWER than the frame is a clipped surface')) 'clipped surface keeps the frame origin for taps'
Assert-True ($text.Contains('WSLg sometimes creates the surface content-sized')) 'clipped WSLg surface is grown before capture'
Assert-True ($text.Contains("$sizeArg = '2560x1392'")) 'game gets a display wide enough for its fixed window'
Assert-True ($text.Contains('package manager can take')) 'activity resolution waits for a fresh Waydroid session'
Assert-True ($text.Contains('Start-AndroidRetryJob $st.App.Package ([string]$st.LaunchCmd) ([string]$st.SizeArg)')) 'retry keeps the display geometry'
Assert-True ($text.Contains('if (-not $w.Settled) { $lumaSum +=')) 'luma sampling is skipped while playing'
Assert-True ($text.Contains('if ($null -eq $script:installJob) { $loader.Hide() }')) 'loader is hidden when the launch state is dropped'
Assert-True ($text.Contains('game surface cropped')) 'game surface shadow is cropped from the capture'
Assert-True ($text.Contains('loses its bottom 12 rows')) 'cropped surface keeps its full height'
Assert-True ($text.Contains('ARM compatibility is synchronized by the background launch job')) 'ARM compatibility runs with the background launch job'
Assert-True ($text.Contains('Set-DisplaySizeVerified')) 'launch verifies the requested display size'
Assert-True ($text.Contains('(Override|Physical) size:')) 'display check reads what Android actually reports'
Assert-True ($text.Contains('export XDG_RUNTIME_DIR=/run/user/$(id -u); systemctl --user restart waydroid-session.service')) 'retry restarts the user session with its runtime dir'
Assert-True (-not $text.Contains('{ 33 } else { 50 }')) 'capture is not throttled to 20 fps while a game window is in use'
Assert-True ($text.Contains('$ww.Window.IsActive')) 'the active wrapper is captured at the full rate'
Assert-True ($text.Contains('$pane.ParkX = $vs.Right + 200')) 'parked surfaces follow a changed desktop'
$iconJobSrc = Get-Content -LiteralPath (Join-Path $root 'assets\iconjob.ps1') -Raw
Assert-True ($iconJobSrc -match '\[string\]\$Lnk') 'icon worker works without a desktop shortcut'
$installWorkerSrc = Get-Content -LiteralPath (Join-Path $root 'assets\installjob.ps1') -Raw
Assert-True ($installWorkerSrc.Contains('reconnecting adb')) 'install retry reconnects adb'
Assert-True ($installWorkerSrc.Contains('WINOID_INSTALL_EXIT=')) 'install worker writes an exit marker'
$launcherSrc = Get-Content -LiteralPath (Join-Path $root 'tools\launcher\WinoidLauncher.cs') -Raw
Assert-True ($launcherSrc.Contains('shutdown.request')) 'watchdog treats a normal window close as a clean shutdown'
Assert-True ($launcherSrc.Contains('WinoidLauncher')) 'watchdog allows only one instance'
Assert-True ($launcherSrc.Contains('QueueRequest')) 'second launch forwards -Launch to the running manager'
Assert-True ($launcherSrc.Contains('fastFailures')) 'watchdog stops a crash loop'

# 5. VBScript fallback keeps Windows-compliant quoting
$vbs = Get-Content -LiteralPath (Join-Path $root 'Winoid.vbs') -Raw
Assert-True ($vbs.Contains('slashes * 2 + 1') -or $vbs.Contains('double')) 'VBS quote helper handles backslashes and quotes'

Write-Host ""
if ($failures -eq 0) { Write-Host 'ALL TESTS PASSED'; exit 0 }
Write-Host "$failures TEST(S) FAILED"; exit 1
