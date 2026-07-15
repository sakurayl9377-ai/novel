param(
    [string]$VersionName,
    [int]$VersionCode,
    [string]$ApkPath = "build/app/outputs/flutter-apk/app-release.apk",
    [string]$OutDir = "build/release-archive",
    [string]$ApkUrl,
    [string[]]$Notes = @(),
    [switch]$Force,
    [int]$MaxSizeMiB = 120
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$lockStream = $null
$temporaryFiles = [System.Collections.Generic.List[string]]::new()
Push-Location $projectRoot
try {
    if (-not $VersionName -or -not $VersionCode) {
        $pubspec = Get-Content -Raw -LiteralPath "pubspec.yaml"
        if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') {
            throw "Could not read a semantic version and build number from pubspec.yaml."
        }
        if (-not $VersionName) { $VersionName = $Matches[1] }
        if (-not $VersionCode) { $VersionCode = [int]$Matches[2] }
    }

    $expectedApkPath = "/app3/app-release-$VersionName+$VersionCode.apk"
    if (-not $ApkUrl) {
        $ApkUrl = "https://novel.kxhub.xyz$expectedApkPath"
    }

    $apkUri = $null
    if (-not [Uri]::TryCreate($ApkUrl, [UriKind]::Absolute, [ref]$apkUri) -or
        $apkUri.Scheme -ne "https" -or
        $apkUri.Host -ne "novel.kxhub.xyz" -or
        $apkUri.AbsolutePath -ne $expectedApkPath -or
        $apkUri.Query -or
        $apkUri.Fragment) {
        throw "ApkUrl must be the versioned HTTPS URL https://novel.kxhub.xyz$expectedApkPath."
    }

    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
    $resolvedOutDir = (Resolve-Path -LiteralPath $OutDir).Path
    $lockPath = Join-Path $resolvedOutDir ".archive-release.lock"
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch {
        throw "Another release archive process is already using '$resolvedOutDir'."
    }

    # Copy the mutable build output exactly once. Every verification, hash, and
    # published artifact below is derived from this immutable snapshot.
    $snapshotApk = Join-Path $resolvedOutDir ".apk-snapshot-$([Guid]::NewGuid().ToString('N')).tmp"
    $temporaryFiles.Add($snapshotApk)
    Copy-Item -LiteralPath $ApkPath -Destination $snapshotApk

    $verifyArguments = @{
        ApkPath = $snapshotApk
        MaxSizeMiB = $MaxSizeMiB
        ExpectedVersionName = $VersionName
        ExpectedVersionCode = $VersionCode
    }
    & "$PSScriptRoot/verify_android_release.ps1" @verifyArguments

    $sha = (Get-FileHash -LiteralPath $snapshotApk -Algorithm SHA256).Hash.ToLowerInvariant()
    $archiveApk = Join-Path $resolvedOutDir "app-release-$VersionName+$VersionCode.apk"
    $latestApk = Join-Path $resolvedOutDir "app-release.apk"
    $writeArchiveApk = $true
    if (Test-Path -LiteralPath $archiveApk) {
        $existingArchiveSha = (Get-FileHash -LiteralPath $archiveApk -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingArchiveSha -ne $sha) {
            throw "Version $VersionName+$VersionCode already has a different archived APK. Increase the version code instead of overwriting an immutable release."
        }
        $writeArchiveApk = $false
    }

    $latestApkTemp = "$latestApk.$([Guid]::NewGuid().ToString('N')).tmp"
    $temporaryFiles.Add($latestApkTemp)
    Copy-Item -LiteralPath $snapshotApk -Destination $latestApkTemp

    $apkCandidates = [System.Collections.Generic.List[string]]::new()
    $apkCandidates.Add($latestApkTemp)
    if ($writeArchiveApk) {
        $archiveApkTemp = "$archiveApk.$([Guid]::NewGuid().ToString('N')).tmp"
        $temporaryFiles.Add($archiveApkTemp)
        $apkCandidates.Add($archiveApkTemp)
        Copy-Item -LiteralPath $snapshotApk -Destination $archiveApkTemp
    }

    foreach ($candidate in $apkCandidates) {
        $candidateSha = (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($candidateSha -ne $sha) {
            throw "Release APK copy failed integrity verification: $candidate"
        }
    }

    if ($writeArchiveApk) {
        Move-Item -LiteralPath $archiveApkTemp -Destination $archiveApk
        $temporaryFiles.Remove($archiveApkTemp) | Out-Null
    }
    Move-Item -LiteralPath $latestApkTemp -Destination $latestApk -Force
    $temporaryFiles.Remove($latestApkTemp) | Out-Null

    $metadata = [ordered]@{
        versionName = $VersionName
        versionCode = $VersionCode
        apkUrl = $ApkUrl
        sha256 = $sha
        force = [bool]$Force
        notes = @($Notes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    }
    $json = $metadata | ConvertTo-Json -Depth 8
    $utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    $archiveVersion = Join-Path $resolvedOutDir "version-$VersionName+$VersionCode.json"
    $latestVersion = Join-Path $resolvedOutDir "version.json"
    [IO.File]::WriteAllText($archiveVersion, "$json`n", $utf8WithoutBom)
    [IO.File]::WriteAllText($latestVersion, "$json`n", $utf8WithoutBom)

    Write-Output "Archived APK: $archiveApk"
    Write-Output "Archived version JSON: $archiveVersion"
    Write-Output "Versioned deployment APK: $archiveApk"
    Write-Output "Compatibility APK copy: $latestApk"
    Write-Output "Deployment version JSON: $latestVersion"
    Write-Output "SHA256: $sha"
} finally {
    foreach ($temporaryFile in $temporaryFiles) {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
    if ($null -ne $lockStream) {
        $lockStream.Dispose()
    }
    Pop-Location
}
