# CxN-Encoder

CxN-Encoder is a Windows PowerShell folder-monitoring service for NVIDIA NVENC
video encoding. The x264 and x265 launchers use the same shared engine, so both
variants have the same movie, TV series, archive, subtitle, logging, and routing
behavior.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7
- An NVIDIA GPU with NVENC support
- Windows Package Manager (`winget`) if an app must be installed

CxN-Encoder checks for FFmpeg and FFprobe when it starts. MKVToolNix is checked
only when it is needed to preserve an unsupported embedded subtitle format.
Before downloading either package, the script asks for permission. Answering
`N` cancels that installation.

## Configure

Open the GUI `Settings` page to configure the end locations. The settings are
saved in `CxN-Encoder-settings.json` next to the scripts and are shared by both
the GUI and the encoder process. The page controls:

- Movies end location
- Low-quality movies end location
- TV end location

The source, working, logging, pending, check interval, and tag settings remain
in the `CONFIG` section of `CxN-Encoder.ps1`. If no settings file exists, the
original paths are used as defaults.

The included paths are specific to the original environment and may not exist
on another computer.

## Run

For H.264, open the GUI with H.264 selected:

```powershell
.\x264-folder-encoder.ps1
```

For H.265/HEVC, open the GUI with H.265 selected:

```powershell
.\x265-folder-encoder.ps1
```

The GUI opens without a shell window and runs the encoder in a separate hidden
process, so the window remains responsive and the encoder retains full NVENC
throughput. It displays the current file, media details, percentage, elapsed
time, speed, ETA, last output, and live encoder messages. Minimize the window to
keep it in the Windows notification area. Use its tray menu or double-click the
tray icon to restore it.

When Start detects another CxN encoder process, the GUI asks whether to
terminate that process tree. Choosing No leaves the existing process running.

Pause suspends the active FFmpeg process and Resume continues it. Stop prompts
for one of three choices: stop now and return the active source with temporary
output cleaned up, finish the current file and then stop, or cancel the stop.

The shared engine handles both stop modes and removes its progress, stdout,
stderr, and encode temp files when a stop-now request returns the source.

If a final move fails, the encoder removes a newly created incomplete
destination, deletes the temporary encode, and returns the source file to its
original location for a later retry.

When a destination volume is out of space, files for that destination are
temporarily skipped while files for other destinations continue. The blocked
destination is checked again after each successful file and resumes when it
has enough free space for the failed output.

At startup, stale files left in `_work` are checked by filename and restored to
the source folder. Series files are restored under their detected show and
season folders. Stale `.temp.mkv` files are moved to `_recovery` so they do
not get mistaken for completed output.

To use the original console-only service, add `-Headless`:

```powershell
.\x265-folder-encoder.ps1 -Headless
.\x264-folder-encoder.ps1 -Headless
```

H.264 uses `h264_nvenc`; H.265 uses `hevc_nvenc`.

Both encoder modes use NVENC for encoding. CUDA decoding is disabled by default
because NVDEC decoder creation was failing with CUDA out-of-memory errors on the
current system. x265 converts to `p010le` and x264 converts to `nv12` with a
software format filter before NVENC. Set `$UseCudaDecode` to `$true` in the
configuration section to test the all-GPU path again.

## Important behavior

CxN-Encoder is an automated media mover as well as an encoder. After a
successful encode or move, it removes the processed source and empty source
folders. Test with disposable files and verify every configured path before
using it with a media library.

Stop a headless monitoring loop with `Ctrl+C`.

To check for a running or stale encoder when the GUI is not open:

```powershell
.\Get-CxN-Encoder-Status.ps1
.\Get-CxN-Encoder-Status.ps1 -Codec x265
```

Each codec has a status file in `_status` containing the process ID, unique
instance ID, current file, and heartbeat time. A status is marked stale when
the matching encoder process is gone or its heartbeat is more than 10 minutes
old. The instance ID also prevents an older process from deleting a newer
status file during cleanup.

Files without a confident TV episode or movie naming indicator are moved to
`C:\Movies\convert\_pending`. Encoding continues with the remaining files.
The GUI lists pending files, flashes its taskbar icon when they arrive, and
provides a button to choose a destination folder for each file.
