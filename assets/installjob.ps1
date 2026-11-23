param(
    [string]$Mode = 'wsl',
    [string]$WslExe = '',
    [string]$Distro = '',
    [string]$AdbExe = '',
    [string]$Serial = '',
    [string]$ApkPath = '',
    [string]$LogFile = ''
)

# Installs an APK in its own hidden process. It must not run inside
# Start-Job: wsl.exe launched from a PowerShell job hangs indefinitely on
# this machine, while the same call works from a normal process.
$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("mode=$Mode")
$code = -1

function Invoke-Adb([string[]]$AdbArgs) {
    if ($Mode -eq 'wsl') {
        $wslArgs = @()
        if (-not [string]::IsNullOrWhiteSpace($Distro)) { $wslArgs += @('-d', $Distro) }
        $out = @(& $WslExe @wslArgs -- adb @AdbArgs 2>&1)
        return @{ Out = $out; Code = $LASTEXITCODE }
    }
    $out = @(& $AdbExe @AdbArgs 2>&1)
    return @{ Out = $out; Code = $LASTEXITCODE }
}

try {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $r = Invoke-Adb @('-s', $Serial, 'install', '-r', $ApkPath)
        $code = [int]$r.Code
        foreach ($l in @($r.Out)) { [void]$lines.Add([string]$l) }
        if ($code -eq 0) { break }
        [void]$lines.Add("attempt $attempt failed with exit=$code")
        if ($attempt -lt 2) {
            # A restarted Waydroid session leaves the adb transport offline;
            # repeating install without reconnecting fails the same way.
            [void]$lines.Add('reconnecting adb')
            $null = Invoke-Adb @('disconnect', $Serial)
            Start-Sleep -Seconds 1
            $null = Invoke-Adb @('connect', $Serial)
            for ($i = 0; $i -lt 10; $i++) {
                Start-Sleep -Milliseconds 700
                $st = Invoke-Adb @('-s', $Serial, 'get-state')
                if ((([string]($st.Out -join ' ')).Trim()) -eq 'device') { break }
            }
        }
    }
} catch {
    [void]$lines.Add("ERROR: " + $_.Exception.ToString())
    $code = -1
}

[void]$lines.Add("install exit=$code")
try {
    $dir = Split-Path -Parent $LogFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($LogFile, (($lines -join "`r`n") + "`r`nWINOID_INSTALL_EXIT=$code"), (New-Object System.Text.UTF8Encoding($false)))
} catch { }
exit $code
