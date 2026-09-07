# ==========================================================
param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("x264", "x265")]
    [string]$Codec,

    [string]$StopSignalPath = "",

    [string]$PauseSignalPath = ""
)

# Shared CxN-Encoder engine for movies and series
# ==========================================================

$EncoderTitle = "CxN-Encoder $Codec"
try { $Host.UI.RawUI.WindowTitle = $EncoderTitle } catch {}
$UseCudaDecode = $false

$VideoEncoder = if ($Codec -eq "x265") { "hevc_nvenc" } else { "h264_nvenc" }
$VideoProfileArgs = if ($Codec -eq "x265") {
    @("-profile:v", "main10")
} else {
    @("-profile:v", "high")
}
$VideoFilterArgs = if ($UseCudaDecode) {
    if ($Codec -eq "x265") {
        @("-vf", "scale_cuda=format=p010le:passthrough=0", "-noautoscale")
    } else {
        @("-vf", "scale_cuda=format=nv12:passthrough=0", "-noautoscale")
    }
} elseif ($Codec -eq "x265") {
    @("-vf", "format=p010le")
} else {
    @("-vf", "format=nv12")
}

if (-not ('CxNProcessControl' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CxNProcessControl {
    [DllImport("ntdll.dll")]
    private static extern int NtSuspendProcess(IntPtr processHandle);
    [DllImport("ntdll.dll")]
    private static extern int NtResumeProcess(IntPtr processHandle);
    public static int Suspend(IntPtr processHandle) { return NtSuspendProcess(processHandle); }
    public static int Resume(IntPtr processHandle) { return NtResumeProcess(processHandle); }
}
'@
}

# --- ENVIRONMENT RELOAD ---
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
            [System.Environment]::GetEnvironmentVariable("Path","User")

# --- CONFIG ---
$SourceDirectory = "V:\encode"
$TargetDirectory = "C:\Movies\convert"
$WorkDirectory   = Join-Path $TargetDirectory "_work"
$LogDirectory    = Join-Path $TargetDirectory "_logs"
$StatusDirectory  = Join-Path $TargetDirectory "_status"
$PendingDirectory = Join-Path $TargetDirectory "_pending"
$StatusFile       = Join-Path $StatusDirectory ("CxN-{0}.json" -f $Codec)
$PlexMoviesDir   = "V:\Plex\Shared Movies"
$LowQualityMoviesDir = "U:\Plex\Shared Movies"
$PlexTVDir       = "U:\Plex\TV Shows"
$CheckInterval   = 120
$FFmpegDecodeThreads = 0
$ExtraHWFrames   = 0
$MoveRetryDelaySeconds = 10
$MoveRetryAttempts = 2
$CustomTag       = "-CxN"
$MovieExtensions = ".mkv",".mp4",".avi",".mov",".wmv",".flv",".webm",".m4v",".3gp",".ogv",".mpg",".mpeg",".ts",".mts"

# Movie-only smart skip thresholds
$MaxGBPerHour = 1.6
$MaxVideoKbps = 4200

$DecodeArgs = if ($UseCudaDecode) {
    @(
        "-threads:v", "$FFmpegDecodeThreads",
        "-extra_hw_frames", "$ExtraHWFrames",
        "-hwaccel", "cuda",
        "-hwaccel_output_format", "cuda"
    )
} else {
    @("-threads:v", "$FFmpegDecodeThreads")
}

function Install-FFmpegPackage {
    Install-RequiredPackage -DisplayName "FFmpeg" -PackageId "Gyan.FFmpeg"
}
function Install-MKVToolNixPackage {
    Install-RequiredPackage -DisplayName "MKVToolNix" -PackageId "MoritzBunkus.MKVToolNix"
}
function Install-RequiredPackage {
    param(
        [Parameter(Mandatory=$true)][string]$DisplayName,
        [Parameter(Mandatory=$true)][string]$PackageId
    )

    $winget = Get-Command winget -ErrorAction SilentlyContinue
    if (-not $winget) {
        throw "winget is required to download $DisplayName but was not found."
    }

    $answer = Read-Host "$DisplayName is missing. Allow CxN-Encoder to download and install it with winget? [Y/N]"
    if ($answer -notmatch '^(?i)y(?:es)?$') {
        throw "Permission to download $DisplayName was declined."
    }

    Write-Host "Downloading and installing $DisplayName..." -ForegroundColor Cyan
    & $winget.Source install --id $PackageId --exact --accept-source-agreements --accept-package-agreements --silent
    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $DisplayName (exit code $LASTEXITCODE)."
    }

    $env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" +
                [System.Environment]::GetEnvironmentVariable("Path","User")
    Write-Host "$DisplayName install complete." -ForegroundColor Green
}

function Find-ToolPath {
    param([Parameter(Mandatory=$true)][string]$Name)

    $candidatePaths = @(
        (Join-Path $env:WINDIR "System32\$Name.exe"),
        $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "$Name.exe" }),
        $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "bin\$Name.exe" })
    ) | Where-Object { $_ }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetRoot) {
        $wingetExe = Get-ChildItem -LiteralPath $wingetRoot -Directory -Filter "Gyan.FFmpeg*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter "$Name.exe" -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            } |
            Select-Object -First 1

        if ($wingetExe -and $wingetExe.FullName) { return $wingetExe.FullName }
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }

    return $null
}
function Find-MKVToolPath {
    param([Parameter(Mandatory=$true)][string]$Name)

    $candidatePaths = @(
        $(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles "MKVToolNix\$Name.exe" }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "MKVToolNix\$Name.exe" }),
        $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "$Name.exe" }),
        $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "bin\$Name.exe" })
    ) | Where-Object { $_ }

    foreach ($candidate in $candidatePaths) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }

    $wingetRoot = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages"
    if (Test-Path -LiteralPath $wingetRoot) {
        $wingetExe = Get-ChildItem -LiteralPath $wingetRoot -Directory -Filter "MoritzBunkus.MKVToolNix*" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            ForEach-Object {
                Get-ChildItem -LiteralPath $_.FullName -Filter "$Name.exe" -File -Recurse -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending |
                    Select-Object -First 1
            } |
            Select-Object -First 1

        if ($wingetExe -and $wingetExe.FullName) { return $wingetExe.FullName }
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if ($command -and $command.Source) { return $command.Source }

    return $null
}

function Resolve-ToolPath {
    param([Parameter(Mandatory=$true)][string]$Name)

    $resolved = Find-ToolPath -Name $Name
    if ($resolved) { return $resolved }

    Install-FFmpegPackage

    $resolved = Find-ToolPath -Name $Name
    if ($resolved) { return $resolved }

    throw "$Name.exe was not found after attempting FFmpeg installation."
}
function Resolve-MKVToolPath {
    param([Parameter(Mandatory=$true)][string]$Name)

    $resolved = Find-MKVToolPath -Name $Name
    if ($resolved) { return $resolved }

    Install-MKVToolNixPackage

    $resolved = Find-MKVToolPath -Name $Name
    if ($resolved) { return $resolved }

    throw "$Name.exe was not found after attempting MKVToolNix installation."
}

try {
    $FFmpegExe  = Resolve-ToolPath -Name "ffmpeg"
    $FFprobeExe = Resolve-ToolPath -Name "ffprobe"
} catch {
    Write-Host "CxN-Encoder cannot start: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$script:MKVMergeExe = $null
$script:MKVMergeResolutionAttempted = $false

# --- ENSURE DIRS ---
foreach ($p in @(
    $SourceDirectory,$TargetDirectory,$WorkDirectory,
    $LogDirectory,$StatusDirectory,$PendingDirectory,
    $PlexMoviesDir,$LowQualityMoviesDir,$PlexTVDir
)) {
    if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Path $p | Out-Null }
}

$script:EncoderInstanceId = [guid]::NewGuid().ToString('N')
$script:EncoderStartedAt = Get-Date
$script:EncoderCurrentFile = ""
$script:LastStatusWriteAt = [datetime]::MinValue
$script:LastStatusState = ""
$script:LastStatusFile = ""

function Write-EncoderStatus {
    param([string]$State = "running")

    $now = Get-Date
    if (($script:LastStatusState -eq $State) -and
        ($script:LastStatusFile -eq $script:EncoderCurrentFile) -and
        (($now - $script:LastStatusWriteAt).TotalSeconds -lt 5)) {
        return
    }

    $status = [ordered]@{
        instance_id = $script:EncoderInstanceId
        pid = $PID
        codec = $Codec
        state = $State
        started_at = $script:EncoderStartedAt.ToUniversalTime().ToString('o')
        heartbeat_at = $now.ToUniversalTime().ToString('o')
        current_file = $script:EncoderCurrentFile
        status_file = $StatusFile
    }
    $temporaryStatusFile = "$StatusFile.$($script:EncoderInstanceId).tmp"
    try {
        $status | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $temporaryStatusFile -Encoding utf8
        Move-Item -LiteralPath $temporaryStatusFile -Destination $StatusFile -Force
        $script:LastStatusWriteAt = $now
        $script:LastStatusState = $State
        $script:LastStatusFile = $script:EncoderCurrentFile
    } catch {
        Remove-Item -LiteralPath $temporaryStatusFile -Force -ErrorAction SilentlyContinue
    }
}

function Remove-EncoderStatus {
    try {
        if (Test-Path -LiteralPath $StatusFile) {
            $existing = Get-Content -LiteralPath $StatusFile -Raw -ErrorAction Stop | ConvertFrom-Json
            if ([string]$existing.instance_id -eq $script:EncoderInstanceId) {
                Remove-Item -LiteralPath $StatusFile -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

Write-EncoderStatus -State "starting"
Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Remove-EncoderStatus } | Out-Null

# ==========================================================
# HELPERS
# ==========================================================
function Test-SeriesEpisodeFile {
    param([Parameter(Mandatory=$true)][string]$Name)
    return ($Name -match '(?i)(?:^|[.\s_-])S\d{1,4}E\d{1,3}(?=$|[.\s_-])')
}
function Test-StopRequested {
    return (-not [string]::IsNullOrWhiteSpace($StopSignalPath)) -and (Test-Path -LiteralPath $StopSignalPath)
}
function Get-StopRequest {
    if (-not (Test-StopRequested)) { return "" }
    try {
        $request = (Get-Content -LiteralPath $StopSignalPath -Raw -ErrorAction Stop).Trim().ToLowerInvariant()
        if ($request -eq "after") { return "after" }
    } catch {}
    return "now"
}
function Test-PauseRequested {
    return (-not [string]::IsNullOrWhiteSpace($PauseSignalPath)) -and (Test-Path -LiteralPath $PauseSignalPath)
}
function Wait-WhilePaused {
    while (Test-PauseRequested) {
        if (Test-StopRequested) { return $false }
        Write-StatusLine "Paused - waiting for resume"
        Write-EncoderStatus -State "paused"
        Start-Sleep -Milliseconds 500
    }
    return $true
}
function Wait-ForNextCheck {
    param([Parameter(Mandatory=$true)][int]$Seconds)

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($stopwatch.Elapsed.TotalSeconds -lt $Seconds) {
        if (Test-StopRequested) { return $false }
        Write-EncoderStatus -State "idle"
        Start-Sleep -Milliseconds 500
    }
    return $true
}
function Test-LowQualityMovieFile {
    param([Parameter(Mandatory=$true)][string]$Name)
    return ($Name -match '(?i)(?:^|[.\s_-])(screener|cam|hdcam|camhd|ts|telesync)(?:[.\s_-]|$)')
}
function Test-ConfidentMovieFile {
    param([Parameter(Mandatory=$true)][string]$Name)

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    return ($base -match '(?i)(?<!\d)(?:19\d{2}|20\d{2})(?!\d)') -or
        ($base -match '(?i)(?:2160p|1080p|720p|480p|4k|bluray|brrip|webrip|web[-. ]?dl|remux|hdr|dv|x264|x265|h264|h265|hevc|avc|aac|dts|proper|repack|extended|theatrical)')
}
function Get-PendingPath {
    param([Parameter(Mandatory=$true)][string]$Name)

    $candidate = Join-Path $PendingDirectory $Name
    if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($Name)
    $extension = [System.IO.Path]::GetExtension($Name)
    return (Join-Path $PendingDirectory ("{0}-pending-{1}{2}" -f $stem, [guid]::NewGuid().ToString('N'), $extension))
}
function Get-SeasonTag {
    param([Parameter(Mandatory=$true)][string]$Name)
    if ($Name -match '(?i)(?:^|[.\s_-])S(\d{1,4})E\d{1,3}(?=$|[.\s_-])') {
        return ("S{0:D2}" -f [int]$Matches[1])
    }
    return "S00"
}
function Get-ShowNameFromFilename {
    param([Parameter(Mandatory=$true)][string]$Name)
    if ($Name -match '(?i)^(.*?)[.\s_-]+S\d{1,4}E\d{1,3}\b') {
        return ((($Matches[1] -replace '[._-]',' ') -replace '\s+',' ').Trim())
    }
    return ((($Name -split '\.')[0]).Trim())
}
function Format-SeriesEpisodeTag {
    param([Parameter(Mandatory=$true)][string]$Name)
    $match = [regex]::Match($Name, '(?i)S(\d{1,4})E(\d{1,3})(?=$|[.\s_-])')
    if (-not $match.Success) { return $Name }

    $normalizedTag = "S{0:D2}E{1:D3}" -f [int]$match.Groups[1].Value, [int]$match.Groups[2].Value
    return $Name.Substring(0, $match.Index) + $normalizedTag + $Name.Substring($match.Index + $match.Length)
}
function Get-TaggedBaseName {
    param([Parameter(Mandatory=$true)][string]$Base)
    $normalized = ($Base -replace '(?i)(^|[.\s_-])(?:h|x)(?:\.?)26[45](?=$|[.\s_-])', "`${1}$Codec")
    if ($normalized -match [regex]::Escape($CustomTag) + '$') { return $normalized }
    $clean = $normalized.Trim()
    return ($clean + $CustomTag)
}
function Get-QPForMinutes {
    param([double]$Min)
    if     ($Min -le  90) { return 21 }
    elseif ($Min -le 150) { return 22 }
    else                  { return 23 }
}
function Get-MediaInfo {
    param([Parameter(Mandatory=$true)][string]$Path)

    $json = & $FFprobeExe -v error -print_format json -show_format -show_streams -show_entries stream=index,codec_name,codec_type,codec_tag_string,bit_rate,tags "$Path" 2>$null
    if (-not $json) { return $null }
    try { $o = $json | ConvertFrom-Json } catch { return $null }

    $dur = 0.0
    if (-not [double]::TryParse([string]$o.format.duration, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$dur)) { return $null }
    if ($dur -lt 1) { return $null }

    $streams = @($o.streams)
    $v = $streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
    $codec = if ($v) { [string]$v.codec_name } else { "" }

    $kbps = 0.0
    if ($v -and $v.bit_rate) {
        $br = 0.0
        if ([double]::TryParse([string]$v.bit_rate, [ref]$br) -and $br -gt 0) { $kbps = [math]::Round(($br / 1000), 0) }
    }
    if ($kbps -le 0) {
        $bytes = (Get-Item -LiteralPath $Path).Length
        $kbps  = [math]::Round(((($bytes * 8) / $dur) / 1000), 0)
    }

    # Subtitle detection and handling plan
    $hasWebVTT = $false
    $hasMovText = $false
    $hasUnsupportedSubtitle = $false
    $subtitleCount = 0
    $subtitleStreams = @()
    foreach ($s in $streams) {
        if ($null -eq $s.index) { continue }

        $cn = if ($s.codec_name) { [string]$s.codec_name } else { "" }
        $tag = if ($s.codec_tag_string) { [string]$s.codec_tag_string } else { "" }
        $codecId = if ($s.tags -and $s.tags."codec_id") { [string]$s.tags."codec_id" } else { "" }

        $isWebVTT = ($cn -eq "webvtt" -or $tag -eq "S_TEXT/WEBVTT" -or $codecId -eq "S_TEXT/WEBVTT")
        $isMovText = ($cn -eq "mov_text" -or $tag -eq "text" -or $tag -eq "tx3g" -or $codecId -eq "text" -or $codecId -eq "tx3g")
        $isUnsupportedSubtitle = ($s.codec_type -eq "subtitle" -and [string]::IsNullOrWhiteSpace($cn)) -or $cn -eq "none" -or $cn -eq "unknown"
        $isSubtitleLike = ($s.codec_type -eq "subtitle" -or $isWebVTT -or $isMovText)

        if (-not $isSubtitleLike) { continue }

        $subtitleCount++
        if ($isWebVTT) { $hasWebVTT = $true }
        if ($isMovText) { $hasMovText = $true }
        if ($isUnsupportedSubtitle) { $hasUnsupportedSubtitle = $true }

        $subtitleStreams += [pscustomobject]@{
            Index  = [int]$s.index
            Action = $(if ($isUnsupportedSubtitle) { "unsupported" } elseif ($isWebVTT -or $isMovText) { "srt" } else { "copy" })
        }
    }

    return [pscustomobject]@{
        DurationSeconds        = $dur
        Minutes                = [math]::Round($dur / 60, 1)
        Codec                  = $codec
        AvgKbps                = $kbps
        SubtitleCount          = $subtitleCount
        HasWebVTT              = $hasWebVTT
        HasMovText             = $hasMovText
        HasUnsupportedSubtitle = $hasUnsupportedSubtitle
        SubtitleStreams        = @($subtitleStreams)
    }
}
function Add-SubtitleStreamArgs {
    param(
        [Parameter(Mandatory=$true)][ref]$Args,
        [Parameter(Mandatory=$true)]$Info
    )

    $outputSubtitleIndex = 0
    foreach ($subtitle in @($Info.SubtitleStreams | Sort-Object Index)) {
        if ($subtitle.Action -eq "skip" -or $subtitle.Action -eq "unsupported") { continue }

        $Args.Value += @("-map", "0:$($subtitle.Index)")
        $Args.Value += @("-c:s:$outputSubtitleIndex", $(if ($subtitle.Action -eq "srt") { "srt" } else { "copy" }))
        $outputSubtitleIndex++
    }
}
function Get-MKVmergePath {
    if ($script:MKVMergeExe) { return $script:MKVMergeExe }
    if ($script:MKVMergeResolutionAttempted) { return $null }

    $script:MKVMergeResolutionAttempted = $true
    try {
        $script:MKVMergeExe = Resolve-MKVToolPath -Name "mkvmerge"
    } catch {
        Write-Host "  MKVToolNix auto-install failed: $($_.Exception.Message)" -ForegroundColor Yellow
        $script:MKVMergeExe = $null
    }

    return $script:MKVMergeExe
}
function ConvertTo-NativeArgumentString {
    param([Parameter(Mandatory=$true)][string[]]$Args)

    $quotedArgs = foreach ($arg in $Args) {
        if ($arg -notmatch '[\s"]' -and $arg.Length -gt 0) {
            $arg
            continue
        }

        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('"')
        $backslashes = 0

        foreach ($char in $arg.ToCharArray()) {
            if ($char -eq '\') {
                $backslashes++
                continue
            }

            if ($char -eq '"') {
                [void]$builder.Append('\' * (($backslashes * 2) + 1))
                [void]$builder.Append('"')
                $backslashes = 0
                continue
            }

            if ($backslashes -gt 0) {
                [void]$builder.Append('\' * $backslashes)
                $backslashes = 0
            }
            [void]$builder.Append($char)
        }

        if ($backslashes -gt 0) {
            [void]$builder.Append('\' * ($backslashes * 2))
        }

        [void]$builder.Append('"')
        $builder.ToString()
    }

    return ($quotedArgs -join ' ')
}
function Invoke-NativeLogged {
    param(
        [Parameter(Mandatory=$true)][string]$Exe,
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$true)][string]$LogFile
    )

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $Exe
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.Arguments = ConvertTo-NativeArgumentString -Args $Args

    [void]$process.Start()
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()

    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()

    foreach ($text in @($stdout, $stderr)) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $text | Out-File -FilePath $LogFile -Append -Encoding utf8
        Write-Host $text
    }

    return $process.ExitCode
}
function Get-FFmpegProgress {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $null }

    $lines = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $lines) { return $null }

    $progress = @{}
    foreach ($line in $lines) {
        $parts = $line -split '=', 2
        if ($parts.Count -eq 2) {
            $progress[$parts[0]] = $parts[1]
        }
    }

    return $progress
}
function Invoke-FFmpegProgressLogged {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][double]$DurationSeconds,
        [string]$Activity = "Encoding",
        [string]$MediaName = ""
    )

    $progressFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ffmpeg-progress-{0}.txt" -f ([guid]::NewGuid()))
    $stdoutFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ffmpeg-stdout-{0}.txt" -f ([guid]::NewGuid()))
    $stderrFile = Join-Path ([System.IO.Path]::GetTempPath()) ("ffmpeg-stderr-{0}.txt" -f ([guid]::NewGuid()))
    $ffmpegArgs = @("-nostats", "-progress", $progressFile) + ($Args | Where-Object { $_ -ne "-stats" -and $_ -ne "-nostats" })

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo.FileName = $FFmpegExe
    $process.StartInfo.UseShellExecute = $false
    $process.StartInfo.RedirectStandardOutput = $true
    $process.StartInfo.RedirectStandardError = $true
    $process.StartInfo.CreateNoWindow = $true
    $process.StartInfo.Arguments = ConvertTo-NativeArgumentString -Args $ffmpegArgs

    $stdoutStream = [System.IO.StreamWriter]::new($stdoutFile, $false, [System.Text.Encoding]::UTF8)
    $stderrStream = [System.IO.StreamWriter]::new($stderrFile, $false, [System.Text.Encoding]::UTF8)
    $encodeStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastProgressReportSeconds = -5.0
    $paused = $false

    try {
        [void]$process.Start()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()

        while (-not $process.HasExited) {
            if (Test-PauseRequested) {
                if (-not $paused) {
                    try {
                        $suspendStatus = [CxNProcessControl]::Suspend($process.Handle)
                        if ($suspendStatus -ne 0) { throw "NtSuspendProcess returned $suspendStatus" }
                        $paused = $true
                        Write-StatusLineBreak
                        Write-Host "Encoding paused." -ForegroundColor Yellow
                    } catch {
                        Write-Host "Unable to pause FFmpeg: $($_.Exception.Message)" -ForegroundColor Yellow
                    }
                }

                if ($paused) {
                    if ((Get-StopRequest) -eq "now") {
                        try { [void][CxNProcessControl]::Resume($process.Handle) } catch {}
                        $paused = $false
                        Write-StatusLineBreak
                        Write-Host "Stop requested; ending the active FFmpeg process safely..." -ForegroundColor Yellow
                        try { $process.Kill() } catch {}
                        break
                    }
                    Start-Sleep -Milliseconds 500
                    continue
                }
            } elseif ($paused) {
                try { [void][CxNProcessControl]::Resume($process.Handle) } catch {}
                $paused = $false
                Write-StatusLineBreak
                Write-Host "Encoding resumed." -ForegroundColor Cyan
            }

            if ((Get-StopRequest) -eq "now") {
                Write-StatusLineBreak
                Write-Host "Stop requested; ending the active FFmpeg process safely..." -ForegroundColor Yellow
                try { $process.Kill() } catch {}
                break
            }

            $progress = Get-FFmpegProgress -Path $progressFile
            if ($progress -and $progress.ContainsKey("out_time_ms")) {
                $outTimeMs = 0.0
                if ([double]::TryParse($progress["out_time_ms"], [ref]$outTimeMs)) {
                    $seconds = $outTimeMs / 1000000.0
                    $percent = [math]::Min(100, [math]::Max(0, ($seconds / $DurationSeconds) * 100))
                    $secondsRemaining = -1
                    $etaText = "calculating"
                    if ($seconds -gt 0 -and $percent -gt 0.1 -and $encodeStopwatch.Elapsed.TotalSeconds -gt 1) {
                        $estimatedTotalSeconds = $encodeStopwatch.Elapsed.TotalSeconds * ($DurationSeconds / $seconds)
                        $secondsRemaining = [int][math]::Max(0, [math]::Ceiling($estimatedTotalSeconds - $encodeStopwatch.Elapsed.TotalSeconds))
                        $etaText = ([TimeSpan]::FromSeconds($secondsRemaining)).ToString("hh\:mm\:ss")
                    }

                    $elapsedText = $encodeStopwatch.Elapsed.ToString("hh\:mm\:ss")
                    $status = "elapsed={0} speed={1} ETA={2}" -f $elapsedText, $progress["speed"], $etaText
                    if (($encodeStopwatch.Elapsed.TotalSeconds - $lastProgressReportSeconds) -ge 5) {
                        Write-StatusLine ("{0}: {1:N1}%  {2}" -f $Activity, $percent, $status)
                        $lastProgressReportSeconds = $encodeStopwatch.Elapsed.TotalSeconds
                    }
                }
            }

            Write-EncoderStatus -State "encoding"
            Start-Sleep -Milliseconds 500
        }

        $process.WaitForExit()
        $stdoutStream.Write($stdoutTask.GetAwaiter().GetResult())
        $stderrStream.Write($stderrTask.GetAwaiter().GetResult())
        $stdoutStream.Flush()
        $stderrStream.Flush()

        Write-StatusLineBreak
        $activityText = if ([string]::IsNullOrWhiteSpace($MediaName)) { $Activity } else { "$Activity [$MediaName]" }
        if ($process.ExitCode -eq 0) {
            Write-Host ("{0}: 100.0% complete in {1}" -f $activityText, $encodeStopwatch.Elapsed.ToString("hh\:mm\:ss")) -ForegroundColor Green
        } else {
            Write-Host ("{0}: ended before completion (exit {1})" -f $activityText, $process.ExitCode) -ForegroundColor Yellow
        }

        foreach ($file in @($stdoutFile, $stderrFile)) {
            if ((Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file).Length -gt 0)) {
                Get-Content -LiteralPath $file | Out-File -FilePath $LogFile -Append -Encoding utf8
            }
        }

        return $process.ExitCode
    } finally {
        if ($paused) {
            try { [void][CxNProcessControl]::Resume($process.Handle) } catch {}
        }
        $encodeStopwatch.Stop()
        $stdoutStream.Dispose()
        $stderrStream.Dispose()
        Remove-Item -LiteralPath $progressFile,$stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
    }
}
function Invoke-MKVmergeLogged {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$true)][string]$LogFile
    )

    $mkvmergeExe = Get-MKVmergePath
    if (-not $mkvmergeExe) { return -1 }

    ""                                                     | Out-File -FilePath $LogFile -Append -Encoding utf8
    "===== $(Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt') =====" | Out-File -FilePath $LogFile -Append -Encoding utf8
    ($mkvmergeExe + " " + ($Args -join " "))              | Out-File -FilePath $LogFile -Append -Encoding utf8
    ""                                                     | Out-File -FilePath $LogFile -Append -Encoding utf8
    return (Invoke-NativeLogged -Exe $mkvmergeExe -Args $Args -LogFile $LogFile)
}
function Merge-OriginalTracksWithMKVmerge {
    param(
        [Parameter(Mandatory=$true)][string]$EncodedPath,
        [Parameter(Mandatory=$true)][string]$SourcePath,
        [Parameter(Mandatory=$true)][string]$MergedPath,
        [Parameter(Mandatory=$true)][string]$LogFile
    )

    $mkvmergeExe = Get-MKVmergePath
    if (-not $mkvmergeExe) { return $false }

    Remove-Item -LiteralPath $MergedPath -Force -ErrorAction SilentlyContinue
    $mkvmergeArgs = @(
        "-o", $MergedPath,
        $EncodedPath,
        "--no-video",
        "--no-audio",
        $SourcePath
    )

    $exit = Invoke-MKVmergeLogged -Args $mkvmergeArgs -LogFile $LogFile
    return ($exit -eq 0 -and (Test-Path -LiteralPath $MergedPath))
}
function Test-AlreadyCompressed {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)]$Info
    )
    $bytes = (Get-Item -LiteralPath $Path).Length
    $hours = $Info.DurationSeconds / 3600.0
    if ($hours -le 0) { return $false }
    $gbph = ($bytes / 1GB) / $hours
    return ($gbph -le $MaxGBPerHour -and [double]$Info.AvgKbps -le $MaxVideoKbps)
}
function Remove-EmptyParentFolders {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$Stop
    )
    $cur = $Path
    while ($cur -and $cur -ne $Stop -and (Test-Path -LiteralPath $cur)) {
        if ((Get-ChildItem -LiteralPath $cur -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            try { Remove-Item -LiteralPath $cur -Force -ErrorAction Stop } catch { break }
            $cur = Split-Path $cur
        } else { break }
    }
}
function Move-ItemWithRetry {
    param(
        [Parameter(Mandatory=$true)][string]$Source,
        [Parameter(Mandatory=$true)][string]$Destination,
        [int]$RetryDelaySeconds = $MoveRetryDelaySeconds,
        [int]$MaxAttempts = $MoveRetryAttempts
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        if (-not (Test-Path -LiteralPath $Source)) {
            Write-Host "  Skipping (source file no longer exists: $Source)" -ForegroundColor Yellow
            return $false
        }

        try {
            Move-Item -LiteralPath $Source -Destination $Destination -Force -ErrorAction Stop
            return $true
        } catch {
            if (-not (Test-Path -LiteralPath $Source)) {
                Write-Host "  Skipping (source file disappeared while moving: $Source)" -ForegroundColor Yellow
                return $false
            }

            if ($attempt -lt $MaxAttempts) {
                Write-Host "  Move failed. Waiting $RetryDelaySeconds seconds before retry... ($($_.Exception.Message))" -ForegroundColor Yellow
                Start-Sleep -Seconds $RetryDelaySeconds
                continue
            }

            Write-Host "  Skipping (unable to move file after $MaxAttempts attempts: $($_.Exception.Message))" -ForegroundColor Yellow
            return $false
        }
    }

    return $false
}
function Invoke-FFmpegLogged {
    param(
        [Parameter(Mandatory=$true)][string[]]$Args,
        [Parameter(Mandatory=$true)][string]$LogFile,
        [Parameter(Mandatory=$true)][double]$DurationSeconds,
        [string]$Activity = "Encoding",
        [string]$MediaName = ""
    )
    "===== $(Get-Date -Format 'yyyy-MM-dd hh:mm:ss tt') =====" | Out-File -FilePath $LogFile -Encoding utf8
    ($FFmpegExe + " " + ($Args -join " "))               | Out-File -FilePath $LogFile -Append -Encoding utf8
    ""                                                     | Out-File -FilePath $LogFile -Append -Encoding utf8
    return (Invoke-FFmpegProgressLogged -Args $Args -LogFile $LogFile -DurationSeconds $DurationSeconds -Activity $Activity -MediaName $MediaName)
}

function Write-StatusLine {
    param([Parameter(Mandatory=$false)][string]$Message)

    $text = if ([string]::IsNullOrWhiteSpace($Message)) { "" } else { "[{0}] {1}" -f (Get-Date -Format 'hh:mm:ss tt'), $Message }
    $padding = ' ' * [Math]::Max(0, 120 - $text.Length)
    [Console]::Write("`r" + $text + $padding)
    Write-EncoderStatus -State $(if ([string]::IsNullOrWhiteSpace($script:EncoderCurrentFile)) { "idle" } else { "encoding" })
}

function Write-StatusLineBreak {
    [Console]::WriteLine()
}

function Test-FileLocked {
    param([Parameter(Mandatory=$true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }

    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $stream.Close()
        $stream.Dispose()
        return $false
    } catch {
        return $true
    }
}

function Get-ArchiveVideoCandidates {
    param([Parameter(Mandatory=$true)][string]$ExtractionDirectory)

    $videoExtensions = @('.mkv', '.mp4', '.avi', '.mov', '.wmv', '.flv', '.webm', '.m4v', '.3gp', '.ogv', '.mpg', '.mpeg', '.ts', '.mts')
    $ancillaryPattern = '(?i)(sample|preview|trailer|teaser|bonus|extras|alt|variant)'
    $skipPattern = '(?i)(sample|preview|trailer|teaser|bonus|extras|part\s*\d+|disc\s*\d+|alt|variant)'

    $candidates = @(Get-ChildItem -LiteralPath $ExtractionDirectory -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object {
            $ext = $_.Extension.ToLowerInvariant()
            $videoExtensions -contains $ext
        } |
        Sort-Object FullName)

    if ($candidates.Count -eq 0) { return @() }

    $episodeCandidates = @($candidates | Where-Object {
        (Test-SeriesEpisodeFile -Name $_.Name) -and ($_.Name -notmatch $ancillaryPattern)
    })
    if ($episodeCandidates.Count -gt 0) {
        return $episodeCandidates
    }

    # A movie archive may contain samples or extras. Preserve the previous
    # behavior of selecting its largest primary video.
    return @($candidates |
        Where-Object { $_.Name -notmatch $skipPattern } |
        Sort-Object Length -Descending |
        Select-Object -First 1)
}

function Move-MisclassifiedSeriesEpisodes {
    param(
        [Parameter(Mandatory=$true)][string[]]$MovieRoots,
        [Parameter(Mandatory=$true)][string]$TvRoot
    )

    foreach ($movieRoot in @($MovieRoots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $movieRoot)) { continue }

        $episodeFiles = @(Get-ChildItem -LiteralPath $movieRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object {
                ($MovieExtensions -contains $_.Extension.ToLowerInvariant()) -and
                (Test-SeriesEpisodeFile -Name $_.Name)
            })

        foreach ($episodeFile in $episodeFiles) {
            if (Test-StopRequested) { return }

            $show = Get-ShowNameFromFilename -Name $episodeFile.Name
            $season = Get-SeasonTag -Name $episodeFile.Name
            $destinationDir = Join-Path (Join-Path $TvRoot $show) $season
            $destinationBase = Format-SeriesEpisodeTag -Name $episodeFile.BaseName
            $destination = Join-Path $destinationDir ($destinationBase + $episodeFile.Extension)

            if (Test-Path -LiteralPath $destination) {
                Write-Host "  TV destination already exists; leaving movie copy in place: $destination" -ForegroundColor Yellow
                continue
            }

            try {
                New-Item -ItemType Directory -Path $destinationDir -Force | Out-Null
                Move-Item -LiteralPath $episodeFile.FullName -Destination $destination -ErrorAction Stop
                Remove-EmptyParentFolders -Path $episodeFile.DirectoryName -Stop $movieRoot
                Write-Host "  Moved misplaced TV episode -> $destination" -ForegroundColor Green
            } catch {
                Write-Host "  Unable to move misplaced TV episode '$($episodeFile.FullName)': $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }
}

# ==========================================================
# MAIN LOOP
# ==========================================================
Write-Host "`n--- $EncoderTitle Service Started (RTX 5080 - Multipass Quality Mode) ---`n" -ForegroundColor Cyan

Move-MisclassifiedSeriesEpisodes -MovieRoots @($PlexMoviesDir, $LowQualityMoviesDir) -TvRoot $PlexTVDir

$script:ZipStabilityState = @{}
while ($true) {
    $script:EncoderCurrentFile = ""
    Write-EncoderStatus -State "idle"
    if (Test-StopRequested) {
        Write-StatusLineBreak
        Write-Host "Stop requested. Encoder service stopped." -ForegroundColor Yellow
        Write-EncoderStatus -State "stopping"
        break
    }
    if (-not (Wait-WhilePaused)) {
        Write-StatusLineBreak
        Write-Host "Stop requested while paused. Encoder service stopped." -ForegroundColor Yellow
        Write-EncoderStatus -State "stopping"
        break
    }

    $waitingZipCount = 0
    $zipFiles = Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -Filter *.zip -ErrorAction SilentlyContinue | Sort-Object LastWriteTime
    foreach ($ZipFile in $zipFiles) {
        if (-not $script:ZipStabilityState.ContainsKey($ZipFile.FullName)) {
            $script:ZipStabilityState[$ZipFile.FullName] = [pscustomobject]@{ LastSize = $ZipFile.Length }
            $waitingZipCount++
            continue
        }

        $zipState = $script:ZipStabilityState[$ZipFile.FullName]
        if ($ZipFile.Length -ne $zipState.LastSize) {
            $zipState.LastSize = $ZipFile.Length
            $waitingZipCount++
            continue
        }

        if (Test-FileLocked -Path $ZipFile.FullName) {
            $waitingZipCount++
            continue
        }

        Write-Host
        Write-Host ("-" * 120) -ForegroundColor DarkGray
        Write-Host "Stable archive detected: $($ZipFile.Name)" -ForegroundColor Cyan
        $extractionDir = Join-Path $WorkDirectory ("zip_" + [System.IO.Path]::GetFileNameWithoutExtension($ZipFile.Name) + "_" + [guid]::NewGuid().ToString('N'))
        $archiveQueueDir = $null
        New-Item -ItemType Directory -Path $extractionDir -Force | Out-Null

        try {
            Expand-Archive -LiteralPath $ZipFile.FullName -DestinationPath $extractionDir -Force
            $archiveVideos = @(Get-ArchiveVideoCandidates -ExtractionDirectory $extractionDir)
            if ($archiveVideos.Count -eq 0) {
                Write-Host "  No usable video files found in archive. Skipping zip." -ForegroundColor Yellow
                Remove-Item -LiteralPath $extractionDir -Recurse -Force -ErrorAction SilentlyContinue
                $script:ZipStabilityState.Remove($ZipFile.FullName)
                continue
            }

            $archiveQueueDir = Join-Path $SourceDirectory ("_archive_" + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $archiveQueueDir -Force | Out-Null

            $queuedCount = 0
            foreach ($archiveVideo in $archiveVideos) {
                $itemQueueDir = Join-Path $archiveQueueDir ("{0:D4}" -f ($queuedCount + 1))
                New-Item -ItemType Directory -Path $itemQueueDir -Force | Out-Null
                Copy-Item -LiteralPath $archiveVideo.FullName -Destination (Join-Path $itemQueueDir $archiveVideo.Name) -Force -ErrorAction Stop
                $queuedCount++
                $classification = if (Test-SeriesEpisodeFile -Name $archiveVideo.Name) { "series episode" } else { "movie" }
                Write-Host ("  Queued {0}: {1}" -f $classification, $archiveVideo.Name) -ForegroundColor Cyan
            }

            Remove-Item -LiteralPath $ZipFile.FullName -Force -ErrorAction Stop
            Remove-Item -LiteralPath $extractionDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:ZipStabilityState.Remove($ZipFile.FullName)
            Write-Host ("  Archive queued for normal classification: {0} file(s)" -f $queuedCount) -ForegroundColor Green
        } catch {
            Write-Host "  Archive processing failed: $($_.Exception.Message)" -ForegroundColor Red
            if ($archiveQueueDir -and (Test-Path -LiteralPath $archiveQueueDir)) {
                Remove-Item -LiteralPath $archiveQueueDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath $extractionDir -Recurse -Force -ErrorAction SilentlyContinue
            $script:ZipStabilityState.Remove($ZipFile.FullName)
        }
    }

    $files = Get-ChildItem -LiteralPath $SourceDirectory -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $MovieExtensions -contains $_.Extension.ToLowerInvariant() }
    if (-not $files) {
        if ($waitingZipCount -gt 0) {
            Write-StatusLine ("Waiting for {0} archive(s) to remain stable. Checking again in {1} seconds..." -f $waitingZipCount, $CheckInterval)
        } else {
            Write-StatusLine "No media or archives found. Sleeping $CheckInterval seconds..."
        }
        if (-not (Wait-ForNextCheck -Seconds $CheckInterval)) { continue }
        continue
    }

    foreach ($File in $files) {
        if (Test-StopRequested) { break }
        $script:EncoderCurrentFile = $File.FullName
        Write-EncoderStatus -State "processing"
        Write-StatusLineBreak
        Write-Host ("-" * 120) -ForegroundColor DarkGray
        Write-Host ("[{0}] Processing: {1}" -f (Get-Date -Format 'hh:mm:ss tt'), $File.Name) -ForegroundColor Cyan
        $OriginalParent = $File.DirectoryName
        $IsSeries = Test-SeriesEpisodeFile -Name $File.Name

        if (-not $IsSeries -and -not (Test-ConfidentMovieFile -Name $File.Name)) {
            $pendingPath = Get-PendingPath -Name $File.Name
            if (Move-ItemWithRetry -Source $File.FullName -Destination $pendingPath) {
                Remove-EmptyParentFolders -Path $OriginalParent -Stop $SourceDirectory
                Write-StatusLineBreak
                Write-Host "  Uncertain classification -> pending: $pendingPath" -ForegroundColor Yellow
            }
            continue
        }

        $WorkInput = Join-Path $WorkDirectory $File.Name
        if (-not (Move-ItemWithRetry -Source $File.FullName -Destination $WorkInput)) {
            continue
        }

        $Info = Get-MediaInfo -Path $WorkInput
        if (-not $Info -or $Info.DurationSeconds -lt 60) {
            Write-Host "  Skipping (ffprobe failed or <60s)" -ForegroundColor Yellow
            Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
            continue
        }

        Write-StatusLine ("Runtime: {0}m  Codec: {1}  Avg: {2} kbps  Subs: {3}" -f $Info.Minutes, $Info.Codec, $Info.AvgKbps, $Info.SubtitleCount)
        if ($Info.HasWebVTT)  { Write-StatusLineBreak; Write-Host "  -> WebVTT subtitles will be converted to SRT" -ForegroundColor Yellow }
        if ($Info.HasMovText) { Write-StatusLineBreak; Write-Host "  -> mov_text subtitles will be converted to SRT" -ForegroundColor Yellow }
        $UseMKVMergeForSubtitleRemux = $false
        if ($Info.HasUnsupportedSubtitle) {
            if (Get-MKVmergePath) {
                $UseMKVMergeForSubtitleRemux = $true
                Write-StatusLineBreak; Write-Host "  -> Unsupported embedded subtitles detected; preserving them with mkvmerge remux" -ForegroundColor Yellow
            } else {
                Write-StatusLineBreak; Write-Host "  -> Unsupported embedded subtitles detected; they will be skipped" -ForegroundColor Yellow
            }
        }

        # ==================================================
        # SERIES
        # ==================================================
        if ($IsSeries) {
            $Show  = Get-ShowNameFromFilename -Name $File.Name
            $Season = Get-SeasonTag -Name $File.Name
            $FinalSeasonDir = Join-Path (Join-Path $PlexTVDir $Show) $Season

            $TaggedBase = Format-SeriesEpisodeTag -Name (Get-TaggedBaseName -Base $File.BaseName)
            $FinalOut   = Join-Path $FinalSeasonDir ($TaggedBase + ".mkv")

            if (Test-Path -LiteralPath $FinalOut) {
                Write-Host "  TV destination file already exists -> skipping: $FinalOut" -ForegroundColor Red
                Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
                continue
            }

            $TempOut = Join-Path $TargetDirectory ($TaggedBase + ".temp.mkv")
            $RemuxOut = $null
            $stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
            $safe    = ($TaggedBase -replace '[\\\/:\*?"<>|]', '_')
            $LogFile = Join-Path $LogDirectory "$safe-$stamp.log"

            Write-StatusLine "Series detected ($Show $Season) -> encoding QP 23 (multipass)"
            Write-StatusLineBreak
            Write-StatusLine "Log: $LogFile"
            Write-StatusLineBreak

            $ffmpegArgs = @(
                "-y", "-hide_banner", "-nostats", "-loglevel", "info",
                "-ignore_unknown"
            ) + $DecodeArgs + @(
                "-i", $WorkInput,
                "-map", "0:V",
                "-map", "0:a?",
                "-c:v", $VideoEncoder,
                "-rc", "constqp",
                "-qp", "23",
                "-preset", "p7",
                "-tune", "hq",
                "-multipass", "2",
                "-c:a", "copy"
            )
            $ffmpegArgs += $VideoFilterArgs
            $ffmpegArgs += $VideoProfileArgs
            if (-not $UseMKVMergeForSubtitleRemux) {
                Add-SubtitleStreamArgs -Args ([ref]$ffmpegArgs) -Info $Info
                $ffmpegArgs += @(
                    "-map", "0:t?",
                    "-c:t", "copy"
                )
            }
            $ffmpegArgs += @($TempOut)

            Write-Host ("Encoding: {0}" -f $File.Name) -ForegroundColor Cyan
            $exit = Invoke-FFmpegLogged -Args $ffmpegArgs -LogFile $LogFile -DurationSeconds $Info.DurationSeconds -Activity "Encoding series" -MediaName $File.Name
            if ($exit -ne 0 -or -not (Test-Path -LiteralPath $TempOut)) {
                Write-StatusLineBreak; Write-Host "  Conversion failed! exit=$exit" -ForegroundColor Red
                if (Test-Path -LiteralPath $LogFile) {
                    Write-StatusLineBreak; Write-Host "--- ffmpeg tail ---" -ForegroundColor DarkYellow
                    Get-Content -LiteralPath $LogFile -Tail 80 | ForEach-Object { Write-Host $_ }
                    Write-StatusLineBreak; Write-Host "--- end tail ---" -ForegroundColor DarkYellow
                }
                Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
                Remove-Item -LiteralPath $TempOut -Force -ErrorAction SilentlyContinue
                continue
            }

            $CompletedTempOut = $TempOut
            if ($UseMKVMergeForSubtitleRemux) {
                $RemuxOut = Join-Path $TargetDirectory ($TaggedBase + ".remux.temp.mkv")
                Write-StatusLineBreak; Write-Host "  Remuxing original subtitle tracks with mkvmerge..." -ForegroundColor Cyan
                if (Merge-OriginalTracksWithMKVmerge -EncodedPath $TempOut -SourcePath $WorkInput -MergedPath $RemuxOut -LogFile $LogFile) {
                    Remove-Item -LiteralPath $TempOut -Force -ErrorAction SilentlyContinue
                    $CompletedTempOut = $RemuxOut
                } else {
                    Write-StatusLineBreak; Write-Host "  mkvmerge remux failed; continuing without unsupported subtitles" -ForegroundColor Yellow
                    Remove-Item -LiteralPath $RemuxOut -Force -ErrorAction SilentlyContinue
                }
            }

            if ((Get-StopRequest) -eq "now") {
                Remove-Item -LiteralPath $TempOut,$RemuxOut -Force -ErrorAction SilentlyContinue
                Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
                continue
            }

            # Success: create folder if needed and move
            New-Item -ItemType Directory -Path $FinalSeasonDir -Force | Out-Null
            Move-Item -LiteralPath $CompletedTempOut -Destination $FinalOut -Force -ErrorAction Stop
            Remove-Item -LiteralPath $WorkInput -Force -ErrorAction SilentlyContinue
            Remove-EmptyParentFolders -Path $OriginalParent -Stop $SourceDirectory
            Write-StatusLineBreak
            Write-Host "  Done -> $FinalOut" -ForegroundColor Green
            try { Invoke-Item $FinalSeasonDir } catch {}
            continue
        }

        # ==================================================
        # MOVIES
        # ==================================================
        $TaggedBase = Get-TaggedBaseName -Base $File.BaseName
        $MovieRootDir = if (Test-LowQualityMovieFile -Name $File.BaseName) { $LowQualityMoviesDir } else { $PlexMoviesDir }
        if ($MovieRootDir -eq $LowQualityMoviesDir) {
            Write-Host "  Low-quality source tag detected -> routing to: $LowQualityMoviesDir" -ForegroundColor DarkYellow
        }
        $UseFlatMovieOutput = ($MovieRootDir -eq $LowQualityMoviesDir)
        if ($UseFlatMovieOutput) {
            $MovieDir      = $MovieRootDir
            $FinalOut      = Join-Path $MovieDir ($TaggedBase + ".mkv")
            $AsIsMovieOut  = Join-Path $MovieDir ($TaggedBase + $File.Extension)
        } else {
            $MovieDir      = Join-Path $MovieRootDir $TaggedBase
            $FinalOut      = Join-Path $MovieDir ($TaggedBase + ".mkv")
            $AsIsMovieOut  = Join-Path $MovieDir ($TaggedBase + $File.Extension)
        }

        # Destination check (movies only): skip if output already exists
        if ($UseFlatMovieOutput) {
            if ((Test-Path -LiteralPath $FinalOut) -or (Test-Path -LiteralPath $AsIsMovieOut)) {
                Write-Host "  Destination file already exists -> skipping: $MovieDir" -ForegroundColor Red
                Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
                continue
            }
        } elseif (Test-Path -LiteralPath $MovieDir) {
            $items = Get-ChildItem -LiteralPath $MovieDir -Force -ErrorAction SilentlyContinue
            if ($items.Count -gt 0) {
                Write-Host "  Destination folder exists and is NOT empty -> skipping: $MovieDir" -ForegroundColor Red
                Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
                continue
            }
            # Folder exists but empty: proceed
        }

        if (Test-AlreadyCompressed -Path $WorkInput -Info $Info) {
            Write-Host "  MOVIE already compressed -> moving as-is" -ForegroundColor Magenta
            if (-not $UseFlatMovieOutput) { New-Item -ItemType Directory -Path $MovieDir -Force | Out-Null }
            Move-Item -LiteralPath $WorkInput -Destination $AsIsMovieOut -Force -ErrorAction Stop
            Remove-EmptyParentFolders -Path $OriginalParent -Stop $SourceDirectory
            Write-StatusLineBreak
            Write-Host "  Done -> $AsIsMovieOut" -ForegroundColor Green
            continue
        }

        # Encode (movies)
        $QP = Get-QPForMinutes -Min $Info.Minutes
        $TempOut = Join-Path $TargetDirectory ($TaggedBase + ".temp.mkv")
        $RemuxOut = $null
        $stamp   = Get-Date -Format "yyyyMMdd-HHmmss"
        $safe    = ($TaggedBase -replace '[\\\/:\*?"<>|]', '_')
        $LogFile = Join-Path $LogDirectory "$safe-$stamp.log"

        Write-StatusLine "Movie encoding -> QP $QP (multipass)"
        Write-StatusLineBreak
        Write-StatusLine "Log: $LogFile"
        Write-StatusLineBreak
        $ffmpegArgs = @(
            "-y", "-hide_banner", "-nostats", "-loglevel", "info",
            "-ignore_unknown"
        ) + $DecodeArgs + @(
            "-i", $WorkInput,
            "-map", "0:V",
            "-map", "0:a?",
            "-c:v", $VideoEncoder,
            "-rc", "constqp",
            "-qp", "$QP",
            "-preset", "p7",
            "-tune", "hq",
            "-multipass", "2",
            "-c:a", "copy"
        )
        $ffmpegArgs += $VideoFilterArgs
        $ffmpegArgs += $VideoProfileArgs
        if (-not $UseMKVMergeForSubtitleRemux) {
            Add-SubtitleStreamArgs -Args ([ref]$ffmpegArgs) -Info $Info
            $ffmpegArgs += @(
                "-map", "0:t?",
                "-c:t", "copy"
            )
        }
        $ffmpegArgs += @($TempOut)

        Write-Host ("Encoding: {0}" -f $File.Name) -ForegroundColor Cyan
        $exit = Invoke-FFmpegLogged -Args $ffmpegArgs -LogFile $LogFile -DurationSeconds $Info.DurationSeconds -Activity "Encoding movie" -MediaName $File.Name
        if ($exit -ne 0 -or -not (Test-Path -LiteralPath $TempOut)) {
            Write-Host "  Conversion failed! exit=$exit" -ForegroundColor Red
            if (Test-Path -LiteralPath $LogFile) {
                Write-Host "`n--- ffmpeg tail ---" -ForegroundColor DarkYellow
                Get-Content -LiteralPath $LogFile -Tail 80 | ForEach-Object { Write-Host $_ }
                Write-Host "--- end tail ---`n" -ForegroundColor DarkYellow
            }
            Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
            Remove-Item -LiteralPath $TempOut -Force -ErrorAction SilentlyContinue
            continue
        }

        $CompletedTempOut = $TempOut
        if ($UseMKVMergeForSubtitleRemux) {
            $RemuxOut = Join-Path $TargetDirectory ($TaggedBase + ".remux.temp.mkv")
            Write-Host "  Remuxing original subtitle tracks with mkvmerge..." -ForegroundColor Cyan
            if (Merge-OriginalTracksWithMKVmerge -EncodedPath $TempOut -SourcePath $WorkInput -MergedPath $RemuxOut -LogFile $LogFile) {
                Remove-Item -LiteralPath $TempOut -Force -ErrorAction SilentlyContinue
                $CompletedTempOut = $RemuxOut
            } else {
                Write-Host "  mkvmerge remux failed; continuing without unsupported subtitles" -ForegroundColor Yellow
                Remove-Item -LiteralPath $RemuxOut -Force -ErrorAction SilentlyContinue
            }
        }

        if ((Get-StopRequest) -eq "now") {
            Remove-Item -LiteralPath $TempOut,$RemuxOut -Force -ErrorAction SilentlyContinue
            Move-ItemWithRetry -Source $WorkInput -Destination $File.FullName | Out-Null
            continue
        }

        # Success: create folder if needed and move
        if (-not $UseFlatMovieOutput) { New-Item -ItemType Directory -Path $MovieDir -Force | Out-Null }
        Move-Item -LiteralPath $CompletedTempOut -Destination $FinalOut -Force -ErrorAction Stop
        Remove-Item -LiteralPath $WorkInput -Force -ErrorAction SilentlyContinue
        Remove-EmptyParentFolders -Path $OriginalParent -Stop $SourceDirectory
        Write-StatusLineBreak
        Write-Host "  Done -> $FinalOut" -ForegroundColor Green
    }
}

Remove-EncoderStatus
