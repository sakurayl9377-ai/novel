param(
  [string]$VersionName,
  [int]$VersionCode,
  [string]$ApkPath = "build\app\outputs\flutter-apk\app-release.apk",
  [string]$OutDir = "build\release-archive"
)

$ErrorActionPreference = "Stop"

if (-not $VersionName -or -not $VersionCode) {
  $pubspec = Get-Content -Raw -Path "pubspec.yaml"
  if ($pubspec -notmatch "(?m)^version:\s*([0-9.]+)\+([0-9]+)") {
    throw "Could not read version from pubspec.yaml"
  }
  if (-not $VersionName) { $VersionName = $Matches[1] }
  if (-not $VersionCode) { $VersionCode = [int]$Matches[2] }
}

if (-not (Test-Path $ApkPath)) {
  throw "APK not found: $ApkPath. Run flutter build apk --release first."
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$archiveApk = Join-Path $OutDir "app-release-$VersionName+$VersionCode.apk"
Copy-Item -Path $ApkPath -Destination $archiveApk -Force

$sha = (Get-FileHash -Algorithm SHA256 -Path $archiveApk).Hash
$versionFile = "version-$VersionName.json"
if (Test-Path $versionFile) {
  try {
    $json = Get-Content -Raw -Encoding UTF8 -Path $versionFile | ConvertFrom-Json
  } catch {
    Write-Warning "Could not parse $versionFile, generating a minimal archive JSON instead."
    $json = [ordered]@{
      versionName = $VersionName
      versionCode = $VersionCode
      apkUrl = "http://49.232.137.85/app/app-release.apk"
      sha256 = ""
      force = $false
      notes = @()
    }
  }
} else {
  $json = [ordered]@{
    versionName = $VersionName
    versionCode = $VersionCode
    apkUrl = "http://49.232.137.85/app/app-release.apk"
    sha256 = ""
    force = $false
    notes = @()
  }
}

$json.versionName = $VersionName
$json.versionCode = $VersionCode
$json.sha256 = $sha
$archiveVersion = Join-Path $OutDir "version-$VersionName+$VersionCode.json"
$json | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 -Path $archiveVersion

Write-Host "Archived APK: $archiveApk"
Write-Host "Archived version JSON: $archiveVersion"
Write-Host "SHA256: $sha"
