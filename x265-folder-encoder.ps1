$engine = Join-Path $PSScriptRoot "CxN-Encoder.ps1"
& $engine -Codec "x265"
exit $LASTEXITCODE
