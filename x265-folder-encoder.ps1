param([switch]$Headless)

$entryPoint = Join-Path $PSScriptRoot "CxN-Encoder.ps1"
if ($Headless) {
    & $entryPoint -Codec "x265"
} else {
    $launcher = Join-Path $PSScriptRoot "CxN-Encoder-GUI-Launcher.vbs"
    Start-Process -FilePath "$env:SystemRoot\System32\wscript.exe" -ArgumentList @('//nologo', ('"' + $launcher + '"'), 'x265') -WindowStyle Hidden | Out-Null
}
exit $(if ($Headless) { $LASTEXITCODE } else { 0 })
