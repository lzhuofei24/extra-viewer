param(
    [string]$Flutter = 'D:\program\dev\flutter\bin\flutter.bat',
    [string]$JavaHome = $(if ($env:JAVA_HOME) { $env:JAVA_HOME } else { 'C:\Program Files\Java\jdk-21' }),
    [string]$OutputDirectory = ''
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot 'dist'
}
$signingProperties = if ($env:EXTRA_VIEWER_SIGNING_PROPERTIES) {
    $env:EXTRA_VIEWER_SIGNING_PROPERTIES
} else {
    Join-Path $env:USERPROFILE '.extra-viewer\signing\key.properties'
}

if (-not (Test-Path -LiteralPath $Flutter -PathType Leaf)) {
    throw "Flutter executable not found: $Flutter"
}
if (-not (Test-Path -LiteralPath (Join-Path $JavaHome 'bin\java.exe') -PathType Leaf)) {
    throw "Java runtime not found: $JavaHome"
}
if (-not (Test-Path -LiteralPath $signingProperties -PathType Leaf)) {
    throw "Extra Viewer signing properties not found: $signingProperties"
}

New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$env:JAVA_HOME = $JavaHome
$javaTemp = Join-Path $repoRoot 'build\java-tmp'
New-Item -ItemType Directory -Force -Path $javaTemp | Out-Null
$env:JAVA_TOOL_OPTIONS = "-Djdk.net.unixdomain.tmpdir=$($javaTemp.Replace('\', '/'))"
Push-Location $repoRoot
try {
    & $Flutter pub get
    if ($LASTEXITCODE -ne 0) { throw 'flutter pub get failed' }

    & $Flutter build apk --release --split-per-abi --no-pub
    if ($LASTEXITCODE -ne 0) { throw 'arm64 APK build failed' }
    $apkTarget = Join-Path $OutputDirectory 'extra-viewer-1.0.0-arm64.apk'
    $splitApk = 'build\app\outputs\flutter-apk\app-arm64-v8a-release.apk'
    if (-not (Test-Path -LiteralPath $splitApk -PathType Leaf)) {
        throw "Expected arm64 APK was not produced: $splitApk"
    }
    Copy-Item -Force $splitApk $apkTarget

    & $Flutter build appbundle --release --no-pub
    if ($LASTEXITCODE -ne 0) {
        # Native symbol stripping can fail transiently after the ABI split build.
        & $Flutter build appbundle --release --no-pub
        if ($LASTEXITCODE -ne 0) { throw 'AAB build failed after retry' }
    }
    $aabTarget = Join-Path $OutputDirectory 'extra-viewer-1.0.0.aab'
    Copy-Item -Force 'build\app\outputs\bundle\release\app-release.aab' $aabTarget

    $checksums = @($apkTarget, $aabTarget) | ForEach-Object {
        $hash = Get-FileHash -Algorithm SHA256 -LiteralPath $_
        "$($hash.Hash.ToLowerInvariant())  $([IO.Path]::GetFileName($_))"
    }
    Set-Content -LiteralPath (Join-Path $OutputDirectory 'SHA256SUMS.txt') `
        -Value $checksums -Encoding ascii
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead((Resolve-Path $apkTarget))
    try {
        $abis = @($zip.Entries |
            Where-Object { $_.FullName -like 'lib/*/*.so' } |
            ForEach-Object { $_.FullName.Split('/')[1] } |
            Sort-Object -Unique)
    } finally {
        $zip.Dispose()
    }
    if ($abis.Count -ne 1 -or $abis[0] -ne 'arm64-v8a') {
        throw "APK ABI verification failed: $($abis -join ', ')"
    }
    $checksums
} finally {
    Pop-Location
}
