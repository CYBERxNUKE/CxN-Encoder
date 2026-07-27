$engine = Join-Path $PSScriptRoot "CxN-Encoder.ps1"
& $engine -Codec "x264"
exit $LASTEXITCODE
