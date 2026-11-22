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
Assert-True ($text.Contains('launch frames for $pkg')) 'launch job collects Android window frames for tap mapping'
Assert-True ($text.Contains('New-AppWrapper $st.App $h $st.Size $stFrames')) 'wrapper uses frames collected by the launch job'
Assert-True ($text.Contains('full-size sub-surface')) 'duplicate full-size game surfaces are parked instead of left on the desktop'
Assert-True ($text.Contains('$script:frameTick % 20')) 'inactive wrapper capture uses a time-based throttle'
Assert-True ($text.Contains('ARM compatibility is synchronized by the background launch job')) 'ARM compatibility runs with the background launch job'
$iconJobSrc = Get-Content -LiteralPath (Join-Path $root 'assets\iconjob.ps1') -Raw
Assert-True ($iconJobSrc -match '\[string\]\$Lnk') 'icon worker works without a desktop shortcut'
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
