param(
    [ValidateSet("x264", "x265")]
    [string]$Codec
)

$statusDirectory = Join-Path $PSScriptRoot "_status"
$files = Get-ChildItem -LiteralPath $statusDirectory -Filter "CxN-*.json" -File -ErrorAction SilentlyContinue
if ($Codec) { $files = $files | Where-Object { $_.BaseName -eq "CxN-$Codec" } }

if (-not $files) {
    Write-Host "No encoder status files found."
    exit 1
}

foreach ($file in $files) {
    try {
        $status = Get-Content -LiteralPath $file.FullName -Raw -ErrorAction Stop | ConvertFrom-Json
        $process = Get-CimInstance Win32_Process -Filter "ProcessId = $($status.pid)" -ErrorAction SilentlyContinue
        $isEncoder = $false
        if ($process -and ($process.CommandLine -match '(?i)CxN-Encoder\.ps1') -and ($process.CommandLine -match "(?i)-Codec\s+$($status.codec)\b")) {
            try {
                $statusStart = [datetime]::Parse($status.started_at).ToUniversalTime()
                $processStart = ([datetime]$process.CreationDate).ToUniversalTime()
                $isEncoder = $processStart -ge $statusStart.AddSeconds(-5)
            } catch {
                $isEncoder = $false
            }
        }
        $heartbeat = [datetime]::Parse($status.heartbeat_at).ToLocalTime()
        $ageMinutes = ((Get-Date) - $heartbeat).TotalMinutes
        $state = if ($isEncoder -and $ageMinutes -lt 10) { "ACTIVE" } else { "STALE" }

        [pscustomobject]@{
            Status = $state
            Codec = $status.codec
            PID = $status.pid
            InstanceId = $status.instance_id
            State = $status.state
            CurrentFile = $status.current_file
            LastHeartbeat = $heartbeat.ToString("yyyy-MM-dd HH:mm:ss")
            HeartbeatAgeMinutes = [math]::Round($ageMinutes, 1)
        }
    } catch {
        [pscustomobject]@{
            Status = "INVALID"
            Codec = "?"
            PID = "?"
            InstanceId = "?"
            State = $_.Exception.Message
            CurrentFile = ""
            LastHeartbeat = ""
            HeartbeatAgeMinutes = ""
        }
    }
}
