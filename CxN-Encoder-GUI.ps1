param(
    [ValidateSet("x264", "x265")]
    [string]$DefaultCodec = "x265",
    [switch]$HideConsole
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

if ($HideConsole) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class CxNConsoleWindow {
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")]
    private static extern bool ShowWindow(IntPtr windowHandle, int command);
    public static void Hide() {
        IntPtr windowHandle = GetConsoleWindow();
        if (windowHandle != IntPtr.Zero) ShowWindow(windowHandle, 0);
    }
}
'@
    [CxNConsoleWindow]::Hide()
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:EncoderProcess = $null
$script:OutputReader = $null
$script:ErrorReader = $null
$script:StopSignalPath = $null
$script:PauseSignalPath = $null
$script:StopRequestedAt = $null
$script:StopMode = $null
$script:IsPaused = $false
$script:EnginePhase = "Stopped"
$script:IdleNoticeShown = $false
$script:StartedAt = $null
$script:AllowExit = $false
$script:ExitWhenStopped = $false
$script:CurrentEncoderLog = $null
$script:MaxLogCharacters = 200000

$enginePath = Join-Path $PSScriptRoot "CxN-Encoder.ps1"
$guiLogDirectory = Join-Path $PSScriptRoot "_gui-logs"
New-Item -ItemType Directory -Path $guiLogDirectory -Force | Out-Null

$form = New-Object System.Windows.Forms.Form
$form.Text = "CxN-Encoder Control"
$form.Size = New-Object System.Drawing.Size(980, 700)
$form.MinimumSize = New-Object System.Drawing.Size(800, 560)
$form.StartPosition = "CenterScreen"
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = "Top"
$topPanel.Height = 56
$form.Controls.Add($topPanel)

$codecLabel = New-Object System.Windows.Forms.Label
$codecLabel.Text = "Encoder:"
$codecLabel.Location = New-Object System.Drawing.Point(14, 19)
$codecLabel.AutoSize = $true
$topPanel.Controls.Add($codecLabel)

$codecBox = New-Object System.Windows.Forms.ComboBox
$codecBox.DropDownStyle = "DropDownList"
$codecBox.Items.AddRange(@("x265 (HEVC)", "x264 (H.264)"))
$codecBox.SelectedIndex = if ($DefaultCodec -eq "x264") { 1 } else { 0 }
$codecBox.Location = New-Object System.Drawing.Point(78, 15)
$codecBox.Width = 130
$topPanel.Controls.Add($codecBox)

$startButton = New-Object System.Windows.Forms.Button
$startButton.Text = "Start"
$startButton.Location = New-Object System.Drawing.Point(224, 13)
$startButton.Size = New-Object System.Drawing.Size(92, 30)
$topPanel.Controls.Add($startButton)

$stopButton = New-Object System.Windows.Forms.Button
$stopButton.Text = "Stop"
$stopButton.Location = New-Object System.Drawing.Point(324, 13)
$stopButton.Size = New-Object System.Drawing.Size(92, 30)
$stopButton.Enabled = $false
$topPanel.Controls.Add($stopButton)

$pauseButton = New-Object System.Windows.Forms.Button
$pauseButton.Text = "Pause"
$pauseButton.Location = New-Object System.Drawing.Point(432, 13)
$pauseButton.Size = New-Object System.Drawing.Size(92, 30)
$pauseButton.Enabled = $false
$topPanel.Controls.Add($pauseButton)

$openLogsButton = New-Object System.Windows.Forms.Button
$openLogsButton.Text = "Open Logs"
$openLogsButton.Location = New-Object System.Drawing.Point(532, 13)
$openLogsButton.Size = New-Object System.Drawing.Size(100, 30)
$topPanel.Controls.Add($openLogsButton)

$clearButton = New-Object System.Windows.Forms.Button
$clearButton.Text = "Clear Display"
$clearButton.Location = New-Object System.Drawing.Point(640, 13)
$clearButton.Size = New-Object System.Drawing.Size(110, 30)
$topPanel.Controls.Add($clearButton)

$statusPanel = New-Object System.Windows.Forms.TableLayoutPanel
$statusPanel.Dock = "Top"
$statusPanel.Height = 132
$statusPanel.ColumnCount = 2
$statusPanel.RowCount = 5
$statusPanel.Padding = New-Object System.Windows.Forms.Padding(14, 4, 14, 4)
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 115)))
[void]$statusPanel.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
$form.Controls.Add($statusPanel)

function Add-StatusRow {
    param([int]$Row, [string]$Caption)
    $captionLabel = New-Object System.Windows.Forms.Label
    $captionLabel.Text = $Caption
    $captionLabel.AutoSize = $true
    $captionLabel.Anchor = "Left"
    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Text = "-"
    $valueLabel.AutoEllipsis = $true
    $valueLabel.Dock = "Fill"
    $valueLabel.TextAlign = "MiddleLeft"
    $statusPanel.Controls.Add($captionLabel, 0, $Row)
    $statusPanel.Controls.Add($valueLabel, 1, $Row)
    return $valueLabel
}

$stateValue = Add-StatusRow -Row 0 -Caption "State:"
$stateValue.Text = "Stopped"
$processValue = Add-StatusRow -Row 1 -Caption "Process:"
$currentValue = Add-StatusRow -Row 2 -Caption "Current file:"
$detailsValue = Add-StatusRow -Row 3 -Caption "Media details:"
$destinationValue = Add-StatusRow -Row 4 -Caption "Last output:"

$progressPanel = New-Object System.Windows.Forms.Panel
$progressPanel.Dock = "Top"
$progressPanel.Height = 58
$form.Controls.Add($progressPanel)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(16, 7)
$progressBar.Height = 22
$progressBar.Anchor = "Top,Left,Right"
$progressBar.Width = 930
$progressPanel.Controls.Add($progressBar)

$progressValue = New-Object System.Windows.Forms.Label
$progressValue.Text = "Waiting to start"
$progressValue.Location = New-Object System.Drawing.Point(16, 33)
$progressValue.AutoSize = $true
$progressPanel.Controls.Add($progressValue)

$logBox = New-Object System.Windows.Forms.RichTextBox
$logBox.Dock = "Fill"
$logBox.ReadOnly = $true
$logBox.WordWrap = $false
$logBox.BackColor = [System.Drawing.Color]::FromArgb(24, 24, 24)
$logBox.ForeColor = [System.Drawing.Color]::Gainsboro
$logBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($logBox)
$form.Controls.SetChildIndex($logBox, 0)
$form.Controls.SetChildIndex($progressPanel, 1)
$form.Controls.SetChildIndex($statusPanel, 2)
$form.Controls.SetChildIndex($topPanel, 3)

$notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$notifyIcon.Icon = [System.Drawing.SystemIcons]::Application
$notifyIcon.Text = "CxN-Encoder Control"
$notifyIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$showMenuItem = $trayMenu.Items.Add("Show")
$startMenuItem = $trayMenu.Items.Add("Start")
$stopMenuItem = $trayMenu.Items.Add("Stop")
$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null
$exitMenuItem = $trayMenu.Items.Add("Exit")
$stopMenuItem.Enabled = $false
$notifyIcon.ContextMenuStrip = $trayMenu

function Append-GuiLog {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return }

    # FFmpeg progress is emitted with carriage returns. Keep it in the live
    # progress area instead of adding a new scrolling log line every update.
    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $displayLines = @(
        foreach ($line in ($normalized -split "`n")) {
            if ($line -match '(?i)^\s*(?:\[[^\]]+\]\s*)?Encoding (?:series|movie):\s*[0-9]+(?:\.[0-9]+)?%') {
                continue
            }
            if ($line -match '(?i)^\s*(?:\[[^\]]+\]\s*)?No media or archives found\. Sleeping') {
                if (-not $script:IdleNoticeShown) {
                    $script:IdleNoticeShown = $true
                    "No media or archives found. Waiting for new media."
                }
                continue
            }
            if ($line -match '(?i)^\s*(?:\[[^\]]+\]\s*)?Processing:') {
                $script:IdleNoticeShown = $false
            }
            $line
        }
    )
    $displayText = $displayLines -join "`r`n"
    if (-not [string]::IsNullOrWhiteSpace($displayText)) {
        $logBox.AppendText($displayText + "`r`n")
    }
    if ($logBox.TextLength -gt $script:MaxLogCharacters) {
        $logBox.Text = $logBox.Text.Substring($logBox.TextLength - $script:MaxLogCharacters)
    }
    $logBox.SelectionStart = $logBox.TextLength
    $logBox.ScrollToCaret()

    $matches = [regex]::Matches($normalized, '(?im)^.*Processing:\s*(.+?)\s*$')
    if ($matches.Count -gt 0) {
        $currentValue.Text = $matches[$matches.Count - 1].Groups[1].Value
        $script:EnginePhase = "Encoding"
        $script:IdleNoticeShown = $false
    }

    $matches = [regex]::Matches($normalized, '(?im)^.*Runtime:\s*(.+?)\s*$')
    if ($matches.Count -gt 0) { $detailsValue.Text = $matches[$matches.Count - 1].Groups[1].Value }

    $matches = [regex]::Matches($normalized, '(?im)^.*Log:\s*(.+?)\s*$')
    if ($matches.Count -gt 0) { $script:CurrentEncoderLog = $matches[$matches.Count - 1].Groups[1].Value }

    $matches = [regex]::Matches($normalized, '(?im)^.*Done\s*->\s*(.+?)\s*$')
    if ($matches.Count -gt 0) {
        $destinationValue.Text = $matches[$matches.Count - 1].Groups[1].Value
        $progressBar.Value = 100
        $progressValue.Text = "Completed current file"
        $script:EnginePhase = "Completed"
    }

    if ($normalized -match '(?im)No media or archives found\. Sleeping') {
        $progressValue.Text = "Completed current file; waiting for new media"
        $script:EnginePhase = "Waiting"
    }

    $matches = [regex]::Matches($normalized, '(?im)(Encoding (?:series|movie)):\s*([0-9]+(?:\.[0-9]+)?)%\s*(.*?)\s*$')
    if ($matches.Count -gt 0) {
        $match = $matches[$matches.Count - 1]
        $percent = [Math]::Min(100, [Math]::Max(0, [double]$match.Groups[2].Value))
        $progressBar.Value = [int][Math]::Round($percent)
        $progressValue.Text = "{0}: {1:N1}%  {2}" -f $match.Groups[1].Value, $percent, $match.Groups[3].Value
    }
}

function Close-LogReaders {
    foreach ($readerName in @("OutputReader", "ErrorReader")) {
        $reader = Get-Variable -Name $readerName -Scope Script -ValueOnly
        if ($reader) {
            try { $reader.Dispose() } catch {}
            Set-Variable -Name $readerName -Scope Script -Value $null
        }
    }
}

function Open-LogReader {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete)
    return [System.IO.StreamReader]::new($stream)
}

function Update-RunningControls {
    param([bool]$Running)
    $startButton.Enabled = -not $Running
    $startMenuItem.Enabled = -not $Running
    $codecBox.Enabled = -not $Running
    $stopButton.Enabled = $Running
    $pauseButton.Enabled = $Running -and -not $script:StopRequestedAt
    $pauseButton.Text = if ($script:IsPaused) { "Resume" } else { "Pause" }
    $stopMenuItem.Enabled = $Running
}

function Start-Encoder {
    if ($script:EncoderProcess -and -not $script:EncoderProcess.HasExited) { return }

    $otherEncoder = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.Name -in @("powershell.exe", "pwsh.exe") -and
            $_.CommandLine -match '(?i)(?:CxN-Encoder\.ps1|x26[45]-folder-encoder\.ps1)'
        } |
        Select-Object -First 1
    if ($otherEncoder) {
        $stateValue.Text = "Another encoder is already running"
        $processValue.Text = "External PID $($otherEncoder.ProcessId)"
        Append-GuiLog "Start blocked: another encoder process is already running (PID $($otherEncoder.ProcessId)).`r`n"
        [System.Windows.Forms.MessageBox]::Show(
            "Another CxN-Encoder process is already running (PID $($otherEncoder.ProcessId)). Stop it before starting a GUI-controlled encoder.",
            "CxN-Encoder",
            "OK",
            "Warning"
        ) | Out-Null
        return
    }

    Close-LogReaders
    $codec = if ($codecBox.SelectedIndex -eq 1) { "x264" } else { "x265" }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $outputPath = Join-Path $guiLogDirectory "gui-$codec-$stamp.out.log"
    $errorPath = Join-Path $guiLogDirectory "gui-$codec-$stamp.error.log"
    $script:StopSignalPath = Join-Path ([System.IO.Path]::GetTempPath()) "cxn-encoder-$PID-$stamp.stop"
    $script:PauseSignalPath = Join-Path ([System.IO.Path]::GetTempPath()) "cxn-encoder-$PID-$stamp.pause"
    Remove-Item -LiteralPath $script:StopSignalPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:PauseSignalPath -Force -ErrorAction SilentlyContinue

    $powershellExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $arguments = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", ('"' + $enginePath + '"'),
        "-Codec", $codec,
        "-StopSignalPath", ('"' + $script:StopSignalPath + '"'),
        "-PauseSignalPath", ('"' + $script:PauseSignalPath + '"')
    )

    try {
        $script:EncoderProcess = Start-Process -FilePath $powershellExe -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $outputPath -RedirectStandardError $errorPath
        $script:StartedAt = Get-Date
        $script:StopRequestedAt = $null
        $script:StopMode = $null
        $script:IsPaused = $false
        $script:EnginePhase = "Starting"
        $script:OutputPath = $outputPath
        $script:ErrorPath = $errorPath
        $script:CurrentEncoderLog = $null
        $stateValue.Text = "Running"
        $processValue.Text = "$codec, PID $($script:EncoderProcess.Id), started $($script:StartedAt.ToString('g'))"
        $progressValue.Text = "Starting encoder service..."
        $progressBar.Value = 0
        Update-RunningControls -Running $true
        Append-GuiLog "`r`n===== Started $codec at $($script:StartedAt) =====`r`n"
    } catch {
        $stateValue.Text = "Start failed"
        Append-GuiLog "Start failed: $($_.Exception.Message)`r`n"
        Update-RunningControls -Running $false
    }
}

function Stop-Encoder {
    if (-not $script:EncoderProcess -or $script:EncoderProcess.HasExited) { return }
    if ($script:StopRequestedAt) { return }

    try {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Yes: stop now, return the active file, and clean temporary output.`r`nNo: finish the current file, then stop.`r`nCancel: keep encoding.",
            "Stop CxN-Encoder?",
            "YesNoCancel",
            "Question"
        )
        if ($answer -eq [System.Windows.Forms.DialogResult]::Cancel) { return }

        $script:StopMode = if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) { "now" } else { "after" }
        if ($script:StopMode -eq "after" -and $script:IsPaused) {
            Remove-Item -LiteralPath $script:PauseSignalPath -Force -ErrorAction SilentlyContinue
            $script:IsPaused = $false
        }
        $script:StopMode | Set-Content -LiteralPath $script:StopSignalPath -Encoding Ascii
        $script:StopRequestedAt = Get-Date
        $stateValue.Text = if ($script:StopMode -eq "now") { "Stopping now safely" } else { "Finishing current file" }
        $progressValue.Text = if ($script:StopMode -eq "now") { "Returning the active file and cleaning temporary output..." } else { "Current file will finish, then the encoder will stop..." }
        $stopButton.Enabled = $false
        $pauseButton.Enabled = $false
        $stopMenuItem.Enabled = $false
        Append-GuiLog "`r`n===== Stop requested: $($script:StopMode) =====`r`n"
    } catch {
        Append-GuiLog "Unable to request stop: $($_.Exception.Message)`r`n"
    }
}

function Toggle-Pause {
    if (-not $script:EncoderProcess -or $script:EncoderProcess.HasExited -or $script:StopRequestedAt) { return }
    try {
        if ($script:IsPaused) {
            Remove-Item -LiteralPath $script:PauseSignalPath -Force -ErrorAction SilentlyContinue
            $script:IsPaused = $false
            $stateValue.Text = "Running"
            Append-GuiLog "`r`n===== Resume requested =====`r`n"
        } else {
            "pause" | Set-Content -LiteralPath $script:PauseSignalPath -Encoding Ascii
            $script:IsPaused = $true
            $stateValue.Text = "Paused"
            Append-GuiLog "`r`n===== Pause requested =====`r`n"
        }
        Update-RunningControls -Running $true
    } catch {
        Append-GuiLog "Unable to change pause state: $($_.Exception.Message)`r`n"
    }
}

function Show-MainWindow {
    $form.Show()
    $form.WindowState = "Normal"
    $form.Activate()
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
    if (-not $script:EncoderProcess) { return }

    if (-not $script:OutputReader) { $script:OutputReader = Open-LogReader -Path $script:OutputPath }
    if (-not $script:ErrorReader) { $script:ErrorReader = Open-LogReader -Path $script:ErrorPath }
    if ($script:OutputReader) { Append-GuiLog -Text $script:OutputReader.ReadToEnd() }
    if ($script:ErrorReader) { Append-GuiLog -Text $script:ErrorReader.ReadToEnd() }

    try { $script:EncoderProcess.Refresh() } catch {}
    if (-not $script:EncoderProcess.HasExited) {
        if ($script:StartedAt) {
            $elapsed = (Get-Date) - $script:StartedAt
            $stateValue.Text = if ($script:StopRequestedAt) {
                if ($script:StopMode -eq "after") { "Finishing current file" } else { "Stopping now safely" }
            } elseif ($script:IsPaused) { "Paused - elapsed $($elapsed.ToString('hh\:mm\:ss'))" }
            elseif ($script:EnginePhase -eq "Waiting") { "Waiting for new media" }
            elseif ($script:EnginePhase -eq "Completed") { "Completed current file" }
            elseif ($script:EnginePhase -eq "Starting") { "Starting service" }
            else { "Running - elapsed $($elapsed.ToString('hh\:mm\:ss'))" }
        }

        if ($script:StopRequestedAt -and (((Get-Date) - $script:StopRequestedAt).TotalSeconds -gt 30)) {
            Append-GuiLog "Safe stop timed out; terminating the process tree.`r`n"
            Start-Process -FilePath "$env:SystemRoot\System32\taskkill.exe" -ArgumentList @('/PID', $script:EncoderProcess.Id, '/T', '/F') -WindowStyle Hidden -Wait
        }
        return
    }

    if ($script:OutputReader) { Append-GuiLog -Text $script:OutputReader.ReadToEnd() }
    if ($script:ErrorReader) { Append-GuiLog -Text $script:ErrorReader.ReadToEnd() }
    $exitCode = $script:EncoderProcess.ExitCode
    Close-LogReaders
    Remove-Item -LiteralPath $script:StopSignalPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $script:PauseSignalPath -Force -ErrorAction SilentlyContinue
    $stateValue.Text = if ($script:StopRequestedAt) { "Stopped" } elseif ($exitCode -eq 0) { "Stopped" } else { "Exited with code $exitCode" }
    $progressValue.Text = "Encoder process is not running"
    Update-RunningControls -Running $false
    Append-GuiLog "`r`n===== Encoder exited with code $exitCode =====`r`n"
    $script:EncoderProcess = $null
    $script:StopRequestedAt = $null
    $script:StopMode = $null
    $script:IsPaused = $false
    $script:EnginePhase = "Stopped"

    if ($script:ExitWhenStopped) {
        $script:AllowExit = $true
        $form.Close()
    }
})
$timer.Start()

$startButton.Add_Click({ Start-Encoder })
$startMenuItem.Add_Click({ Start-Encoder })
$stopButton.Add_Click({ Stop-Encoder })
$stopMenuItem.Add_Click({ Stop-Encoder })
$pauseButton.Add_Click({ Toggle-Pause })
$clearButton.Add_Click({ $logBox.Clear() })
$openLogsButton.Add_Click({
    $path = if ($script:CurrentEncoderLog -and (Test-Path -LiteralPath $script:CurrentEncoderLog)) {
        Split-Path -Parent $script:CurrentEncoderLog
    } else {
        $guiLogDirectory
    }
    Start-Process -FilePath "explorer.exe" -ArgumentList ('"' + $path + '"')
})
$showMenuItem.Add_Click({ Show-MainWindow })
$notifyIcon.Add_DoubleClick({ Show-MainWindow })

$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
        $notifyIcon.ShowBalloonTip(1500, "CxN-Encoder", "The encoder control is still running in the notification area.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$exitMenuItem.Add_Click({
    if ($script:EncoderProcess -and -not $script:EncoderProcess.HasExited) {
        $answer = [System.Windows.Forms.MessageBox]::Show("Stop the encoder safely and exit when it has stopped?", "CxN-Encoder", "YesNo", "Question")
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        $script:ExitWhenStopped = $true
        Stop-Encoder
        $form.Hide()
        return
    }
    $script:AllowExit = $true
    $form.Close()
})

$form.Add_FormClosing({
    param($sender, $eventArgs)
    if (-not $script:AllowExit) {
        $eventArgs.Cancel = $true
        $form.Hide()
        $notifyIcon.ShowBalloonTip(1500, "CxN-Encoder", "Use the tray icon to restore or exit the application.", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$form.Add_FormClosed({
    $timer.Stop()
    Close-LogReaders
    $notifyIcon.Visible = $false
    $notifyIcon.Dispose()
})

[System.Windows.Forms.Application]::Run($form)
