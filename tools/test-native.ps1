param([string]$Flutter = 'flutter')
$ErrorActionPreference = 'Stop'
$appRoot = Split-Path $PSScriptRoot
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'Visual Studio C++ workload is required.' }
$cmake = Join-Path $vsRoot 'Common7/IDE/CommonExtensions/Microsoft/CMake/CMake/bin/cmake.exe'
& $cmake -S "$PSScriptRoot/native-tests" -B "$appRoot/build/native-tests" -A x64
if ($LASTEXITCODE) { throw 'Native CMake configure failed.' }
& $cmake --build "$appRoot/build/native-tests" --config Release
if ($LASTEXITCODE) { throw 'Native build failed.' }
Push-Location $appRoot
try {
  & $Flutter test --no-pub test/windows_wic_webp_thumbnail_backend_test.dart
  if ($LASTEXITCODE) { throw 'Native contract test failed.' }
} finally { Pop-Location }
