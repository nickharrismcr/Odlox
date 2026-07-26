# PowerShell version of setenv
$env:LOX_PATH = $PWD.Path
$env:PATH = "$($env:LOX_PATH)\bin;$($env:PATH)"

Write-Host "Environment set:"
Write-Host "LOX_PATH = $($env:LOX_PATH)"
Write-Host "PATH includes: $($env:LOX_PATH)\bin"
