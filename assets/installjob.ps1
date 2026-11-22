param(
    [string]$Mode = 'wsl',
    [string]$WslExe = '',
    [string]$Distro = '',
    [string]$AdbExe = '',
    [string]$Serial = '',
    [string]$ApkPath = '',
    [string]$LogFile = ''
)

$ErrorActionPreference = 'Continue'
$lines = New-Object System.Collections.ArrayList
[void]$lines.Add("mode=$Mode")
$code = -1

try {
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if ($Mode -eq 'wsl') {
            $wslArgs = @()
            if (-not [string]::IsNullOrWhiteSpace($Distro)) { $wslArgs += @('-d', $Distro) }
            $out = & $WslExe @wslArgs -- adb -s $Serial install -r $ApkPath 2>&1
        } else {
            $out = & $AdbExe -s $Serial install -r $ApkPath 2>&1
        }
        $code = $LASTEXITCODE
        foreach ($l in @($out)) { [void]$lines.Add([string]$l) }
        if ($code -eq 0) { break }
        [void]$lines.Add("attempt $attempt failed with exit=$code")
        Start-Sleep -Seconds 3
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
