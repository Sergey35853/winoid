param(
    [Parameter(Mandatory = $true)][string]$Package,
    [string]$Serial = '192.168.240.112:5555',
    [string]$WslExe = "$env:SystemRoot\System32\wsl.exe",
    [string]$Distro = '',
    [Parameter(Mandatory = $true)][string]$Dex,
    [Parameter(Mandatory = $true)][string]$Ico,
    [string]$Lnk = '',
    [string]$Generic = ''
)

# Extracts an Android package icon into a multi-size .ico and points an
# existing desktop shortcut at it. Runs in a separate hidden pwsh process so
# the Winoid window never blocks on adb or WSL.
$ErrorActionPreference = 'Stop'
$logPath = Join-Path $env:LOCALAPPDATA 'Winoid\iconjob.log'

function Write-Log([string]$Message) {
    try {
        $dir = Split-Path -Parent $logPath
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        Add-Content -LiteralPath $logPath -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $Message) -Encoding UTF8
    } catch { }
}

function Convert-ToWslPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -match '^([A-Za-z]):\\(.*)$') {
        return '/mnt/' + $matches[1].ToLowerInvariant() + '/' + ($matches[2] -replace '\\', '/')
    }
    return ($full -replace '\\', '/')
}

function Invoke-Tool([string]$Exe, [string[]]$Arguments, [int]$TimeoutMs) {
    $p = [Diagnostics.Process]::new()
    $p.StartInfo.FileName = $Exe
    foreach ($a in $Arguments) { [void]$p.StartInfo.ArgumentList.Add([string]$a) }
    $p.StartInfo.UseShellExecute = $false
    $p.StartInfo.RedirectStandardOutput = $true
    $p.StartInfo.RedirectStandardError = $true
    $p.StartInfo.CreateNoWindow = $true
    [void]$p.Start()
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    if (-not $p.WaitForExit($TimeoutMs)) {
        try { $p.Kill($true) } catch { try { $p.Kill() } catch { } }
        try { [void]$p.WaitForExit(2000) } catch { }
    }
    if (-not $p.HasExited) { return '' }
    return (($outTask.Result + "`n" + $errTask.Result))
}

function Convert-PngToIco([string]$PngPath, [string]$IcoPath) {
    Add-Type -AssemblyName System.Drawing
    $src = [Drawing.Image]::FromFile($PngPath)
    try {
        $sizes = @(16, 24, 32, 48, 64, 128, 256)
        $pngs = [Collections.Generic.List[byte[]]]::new()
        foreach ($s in $sizes) {
            $bmp = New-Object Drawing.Bitmap $s, $s, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [Drawing.Graphics]::FromImage($bmp)
            try {
                $g.Clear([Drawing.Color]::Transparent)
                $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
                $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                $scale = [Math]::Min($s / $src.Width, $s / $src.Height)
                $w = [Math]::Max(1, [int][Math]::Round($src.Width * $scale))
                $h = [Math]::Max(1, [int][Math]::Round($src.Height * $scale))
                $x = [int](($s - $w) / 2)
                $y = [int](($s - $h) / 2)
                $g.DrawImage($src, $x, $y, $w, $h)
                $ms = New-Object IO.MemoryStream
                $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
                $pngs.Add($ms.ToArray())
                $ms.Dispose()
            } finally {
                $g.Dispose()
                $bmp.Dispose()
            }
        }

        $ms = New-Object IO.MemoryStream
        $bw = New-Object IO.BinaryWriter $ms
        try {
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
            $dir = Split-Path -Parent $IcoPath
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
            [IO.File]::WriteAllBytes($IcoPath, $ms.ToArray())
        } finally {
            $bw.Dispose()
            $ms.Dispose()
        }
    } finally {
        $src.Dispose()
    }
}

function Invoke-WslAdb([string[]]$Arguments, [int]$TimeoutMs = 15000) {
    return Invoke-Tool $WslExe ($script:Base + @('--', 'adb') + $Arguments) $TimeoutMs
}

$localPng = $null
try {
    Write-Log "start $Package"

    if (-not (Test-Path -LiteralPath $Dex)) { throw "dex missing: $Dex" }
    if (-not [string]::IsNullOrWhiteSpace($Lnk) -and -not (Test-Path -LiteralPath $Lnk)) { throw "shortcut missing: $Lnk" }

    $script:Base = @()
    if (-not [string]::IsNullOrWhiteSpace($Distro)) { $script:Base = @('-d', $Distro) }

    $state = Invoke-WslAdb @('-s', $Serial, 'get-state') 15000
    if ($state -notmatch 'device') {
        $null = Invoke-WslAdb @('connect', $Serial) 15000
        $state = Invoke-WslAdb @('-s', $Serial, 'get-state') 15000
    }
    if ($state -notmatch 'device') { throw "adb not connected: $(($state -replace '\s+', ' ').Trim())" }

    $remoteDex = '/data/local/tmp/winoid-icon.dex'
    $remotePng = "/data/local/tmp/winoid-$Package.png"
    $localPng = Join-Path $env:TEMP ("winoid-$Package-" + [Guid]::NewGuid().ToString('N') + '.png')
    $linuxDex = Convert-ToWslPath $Dex
    $linuxPng = Convert-ToWslPath $localPng

    $null = Invoke-WslAdb @('-s', $Serial, 'push', $linuxDex, $remoteDex) 20000
    $cmd = "CLASSPATH=$remoteDex app_process /system/bin WinoidIcon $Package $remotePng"
    $res = Invoke-WslAdb @('-s', $Serial, 'shell', $cmd) 30000
    if ($res -notmatch 'OK') { throw "extract failed: $(($res -replace '\s+', ' ').Trim())" }

    $pull = Invoke-WslAdb @('-s', $Serial, 'pull', $remotePng, $linuxPng) 20000
    if (-not (Test-Path -LiteralPath $localPng)) { throw "pull failed: $(($pull -replace '\s+', ' ').Trim())" }

    Convert-PngToIco $localPng $Ico
    if (-not (Test-Path -LiteralPath $Ico)) { throw 'ico not created' }

    $ws = New-Object -ComObject WScript.Shell
    if (-not [string]::IsNullOrWhiteSpace($Lnk)) {
        $sc = $ws.CreateShortcut($Lnk)
        $sc.IconLocation = "$Ico,0"
        $sc.Save()
    }
    Write-Log "ok $Package -> $Ico"
} catch {
    Write-Log "error $Package : $($_.Exception.Message)"
    exit 1
} finally {
    if ($localPng) { Remove-Item -LiteralPath $localPng -Force -ErrorAction SilentlyContinue }
}
