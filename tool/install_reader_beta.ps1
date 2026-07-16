param(
  [Parameter(Mandatory = $true)]
  [string]$DeviceSerial,
  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 999999)]
  [int]$BetaNumber,
  [int]$BackendPort = 3010
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$apk = Join-Path $repoRoot `
  "build\test-artifacts\sakura-reader-beta-$BetaNumber-arm64-v8a.apk"
$verify = Join-Path $PSScriptRoot 'verify_reader_beta_apk.ps1'

if (-not (Test-Path -LiteralPath $apk)) {
  throw "Beta APK not found: $apk"
}

& $verify -ApkPath $apk -BetaNumber $BetaNumber -ExpectedAbi 'arm64-v8a'
if ($LASTEXITCODE -ne 0) {
  throw 'Beta APK verification failed; refusing to install.'
}

$devices = @(& adb devices | Select-String "^$([regex]::Escape($DeviceSerial))\s+device$")
if ($devices.Count -ne 1) {
  throw "Android device is not ready: $DeviceSerial"
}

& adb -s $DeviceSerial reverse "tcp:$BackendPort" "tcp:$BackendPort"
if ($LASTEXITCODE -ne 0) { throw 'ADB reverse failed.' }

& adb -s $DeviceSerial install -r $apk
if ($LASTEXITCODE -ne 0) { throw 'Beta APK installation failed.' }

& adb -s $DeviceSerial shell monkey `
  -p com.novel.novel_app.beta `
  -c android.intent.category.LAUNCHER 1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Beta app launch failed.' }

Write-Host "Installed Sakura Reader Beta $BetaNumber on $DeviceSerial"
