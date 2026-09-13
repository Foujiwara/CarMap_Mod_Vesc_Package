param([string]$VescTool = 'vesc_tool')
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $versionText = (Get-Content -Raw version).Trim()
    $nameText = (Get-Content -Raw package_name).Trim()
    if ($nameText.Length -gt 20) { $nameText = $nameText.Substring(0, 20) }
    $qml = (Get-Content -Raw ui.qml.in).Replace('{{PACKAGE_NAME}}', $nameText).Replace('{{VERSION}}', $versionText)
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'ui.qml'), $qml)
    $readme = (Get-Content -Raw package_README.md) + "`n`n### Build Info`n- Version: $versionText`n- Build Date: $(Get-Date -Format o)`n"
    [IO.File]::WriteAllText((Join-Path $PSScriptRoot 'package_README-gen.md'), $readme)
    $outputPath = Join-Path $PSScriptRoot 'carmap_thermal_throttle.vescpkg'
    $buildStart = Get-Date
    $process = Start-Process -FilePath $VescTool -ArgumentList '--buildPkgFromDesc', 'pkgdesc.qml' -WindowStyle Hidden -PassThru -Wait
    if ($process.ExitCode -ne 0 -or !(Test-Path -LiteralPath $outputPath) -or (Get-Item -LiteralPath $outputPath).LastWriteTime -lt $buildStart) {
        throw 'VESC Tool did not produce a fresh package. Check its build output.'
    }
    Write-Output "Built $outputPath (version $versionText)"
} finally { Pop-Location }
