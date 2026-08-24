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

Open `CxN-Encoder.ps1` and review the values in the `CONFIG` section before
running it:

- `$SourceDirectory`
- `$TargetDirectory`
- `$PlexMoviesDir`
- `$LowQualityMoviesDir`
- `$PlexTVDir`
- `$CheckInterval`
- `$CustomTag`

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

Pause suspends the active FFmpeg process and Resume continues it. Stop prompts
for one of three choices: stop now and return the active source with temporary
output cleaned up, finish the current file and then stop, or cancel the stop.

The shared engine handles both stop modes and removes its progress, stdout,
stderr, and encode temp files when a stop-now request returns the source.

To use the original console-only service, add `-Headless`:

```powershell
.\x265-folder-encoder.ps1 -Headless
.\x264-folder-encoder.ps1 -Headless
```

H.264 uses `h264_nvenc`; H.265 uses `hevc_nvenc`.

Both encoder modes normalize decoded frames with `scale_cuda` before NVENC and
disable FFmpeg's automatic output scaler. This keeps format and color-property
changes inside the GPU path instead of inserting an incompatible software
scaler mid-encode.

## Important behavior

CxN-Encoder is an automated media mover as well as an encoder. After a
successful encode or move, it removes the processed source and empty source
folders. Test with disposable files and verify every configured path before
using it with a media library.

Stop a headless monitoring loop with `Ctrl+C`.
