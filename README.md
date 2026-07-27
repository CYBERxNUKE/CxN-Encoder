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

For H.264:

```powershell
.\x264-folder-encoder.ps1
```

The console title is `CxN-Encoder x264`, and FFmpeg uses `h264_nvenc`.

For H.265/HEVC:

```powershell
.\x265-folder-encoder.ps1
```

The console title is `CxN-Encoder x265`, and FFmpeg uses `hevc_nvenc`.

## Important behavior

CxN-Encoder is an automated media mover as well as an encoder. After a
successful encode or move, it removes the processed source and empty source
folders. Test with disposable files and verify every configured path before
using it with a media library.

Stop the continuous monitoring loop with `Ctrl+C`.
