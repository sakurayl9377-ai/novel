param(
    [int]$MaxSizeMiB = 128
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & flutter clean
    if ($LASTEXITCODE -ne 0) { throw "flutter clean failed." }

    & flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

    # Do not add --no-pub here. Flutter must regenerate the plugin registrant
    # in release mode so dev-only plugins are excluded from the APK build.
    & flutter build apk --release
    if ($LASTEXITCODE -ne 0) { throw "Flutter release build failed." }

    & "$PSScriptRoot/verify_android_release.ps1" -MaxSizeMiB $MaxSizeMiB
} finally {
    Pop-Location
}
