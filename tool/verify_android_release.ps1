param(
    [string]$ApkPath = "build/app/outputs/flutter-apk/app-release.apk",
    [int]$MaxSizeMiB = 128,
    [string]$ExpectedApplicationId = "com.novel.novel_app",
    [string]$ExpectedVersionName,
    [int]$ExpectedVersionCode,
    [string]$ExpectedSignerSha256 = "e474b2417755696df260fb73d8965c4a254ea103bb772f9599dca406147488c7",
    [switch]$SkipFreshnessCheck
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
$apk = Get-Item -LiteralPath $resolvedApk

if (-not $ExpectedVersionName -or -not $ExpectedVersionCode) {
    $pubspecPath = Join-Path $projectRoot "pubspec.yaml"
    $pubspec = Get-Content -Raw -LiteralPath $pubspecPath
    if ($pubspec -notmatch '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+)\+([0-9]+)\s*$') {
        throw "Could not read a semantic version and build number from pubspec.yaml."
    }
    if (-not $ExpectedVersionName) { $ExpectedVersionName = $Matches[1] }
    if (-not $ExpectedVersionCode) { $ExpectedVersionCode = [int]$Matches[2] }
}

if (-not $SkipFreshnessCheck) {
    $inputPaths = @(
        (Join-Path $projectRoot "pubspec.yaml"),
        (Join-Path $projectRoot "pubspec.lock"),
        (Join-Path $projectRoot "android"),
        (Join-Path $projectRoot "lib"),
        (Join-Path $projectRoot "assets"),
        (Join-Path $projectRoot "vendor")
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $excludedGeneratedRoots = @(
        (Join-Path $projectRoot "android/.gradle"),
        (Join-Path $projectRoot "android/.kotlin"),
        (Join-Path $projectRoot "android/build"),
        (Join-Path $projectRoot "android/app/build")
    ) | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar }
    $newerInput = Get-ChildItem -LiteralPath $inputPaths -Recurse -File |
        Where-Object {
            $fullPath = $_.FullName
            $_.Name -ne "GeneratedPluginRegistrant.java" -and
            -not ($excludedGeneratedRoots | Where-Object { $fullPath.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }) -and
            $_.LastWriteTimeUtc -gt $apk.LastWriteTimeUtc.AddSeconds(1)
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
    if ($null -ne $newerInput) {
        throw "Release APK is stale; $($newerInput.FullName) is newer than the APK. Rebuild before archiving."
    }
}

$maxBytes = $MaxSizeMiB * 1MB
if ($apk.Length -gt $maxBytes) {
    throw "Release APK is $([math]::Round($apk.Length / 1MB, 2)) MiB; limit is $MaxSizeMiB MiB."
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($resolvedApk)
try {
    $abis = @(
        $archive.Entries |
            Where-Object { $_.FullName -match '^lib/[^/]+/[^/]+\.so$' } |
            ForEach-Object { ($_.FullName -split '/')[1] } |
            Sort-Object -Unique
    )
} finally {
    $archive.Dispose()
}

$requiredAbis = @("arm64-v8a", "armeabi-v7a")
$unexpectedAbis = @($abis | Where-Object { $_ -notin $requiredAbis })
$missingAbis = @($requiredAbis | Where-Object { $_ -notin $abis })
if ($unexpectedAbis.Count -gt 0) {
    throw "Release APK contains unsupported ABI(s): $($unexpectedAbis -join ', ')."
}
if ($missingAbis.Count -gt 0) {
    throw "Release APK is missing required ABI(s): $($missingAbis -join ', ')."
}

$localProperties = Join-Path $projectRoot "android/local.properties"
$sdkRoot = $env:ANDROID_SDK_ROOT
if (-not $sdkRoot) { $sdkRoot = $env:ANDROID_HOME }
if (-not $sdkRoot -and (Test-Path -LiteralPath $localProperties)) {
    $sdkLine = Get-Content -LiteralPath $localProperties |
        Where-Object { $_ -match '^sdk\.dir=' } |
        Select-Object -First 1
    if ($sdkLine) {
        $sdkRoot = ($sdkLine -replace '^sdk\.dir=', '') -replace '\\\\', '\'
    }
}

$apkAnalyzer = (Get-Command apkanalyzer -ErrorAction SilentlyContinue).Source
if (-not $apkAnalyzer -and $sdkRoot) {
    $candidate = Join-Path $sdkRoot "cmdline-tools/latest/bin/apkanalyzer.bat"
    if (Test-Path -LiteralPath $candidate) { $apkAnalyzer = $candidate }
}
if (-not $apkAnalyzer) { throw "apkanalyzer was not found in PATH or the Android SDK." }

$buildTools = @()
if ($sdkRoot) {
    $buildToolsRoot = Join-Path $sdkRoot "build-tools"
    if (Test-Path -LiteralPath $buildToolsRoot) {
        $buildTools = Get-ChildItem -LiteralPath $buildToolsRoot -Directory |
            Sort-Object { [version]$_.Name } -Descending
    }
}
$apkSigner = (Get-Command apksigner -ErrorAction SilentlyContinue).Source
if (-not $apkSigner) {
    $apkSigner = $buildTools |
        ForEach-Object { Join-Path $_.FullName "apksigner.bat" } |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
}
if (-not $apkSigner) { throw "apksigner was not found in PATH or the Android SDK." }

$actualApplicationId = (& $apkAnalyzer manifest application-id $resolvedApk).Trim()
$actualVersionName = (& $apkAnalyzer manifest version-name $resolvedApk).Trim()
$actualVersionCode = (& $apkAnalyzer manifest version-code $resolvedApk).Trim()
if ($LASTEXITCODE -ne 0) { throw "apkanalyzer failed to inspect the release APK." }
if ($actualApplicationId -ne $ExpectedApplicationId) {
    throw "Unexpected applicationId: $actualApplicationId."
}
if ($actualVersionName -ne $ExpectedVersionName) {
    throw "Unexpected versionName: $actualVersionName; expected $ExpectedVersionName."
}
if ($actualVersionCode -ne "$ExpectedVersionCode") {
    throw "Unexpected versionCode: $actualVersionCode; expected $ExpectedVersionCode."
}

$signatureOutput = & $apkSigner verify --print-certs $resolvedApk
if ($LASTEXITCODE -ne 0) { throw "APK signature verification failed." }
$signerMatch = [regex]::Match(
    ($signatureOutput -join "`n"),
    '(?im)certificate SHA-256 digest:\s*([0-9a-f]{64})'
)
if (-not $signerMatch.Success) { throw "Could not read the APK signer certificate digest." }
$actualSignerSha256 = $signerMatch.Groups[1].Value.ToLowerInvariant()
if ($ExpectedSignerSha256 -and
    $actualSignerSha256 -ne $ExpectedSignerSha256.ToLowerInvariant()) {
    throw "Unexpected APK signer certificate: $actualSignerSha256."
}

$digest = (Get-FileHash -LiteralPath $resolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "APK: $resolvedApk"
Write-Output "SizeMiB: $([math]::Round($apk.Length / 1MB, 2))"
Write-Output "ApplicationId: $actualApplicationId"
Write-Output "Version: $actualVersionName+$actualVersionCode"
Write-Output "ABIs: $($abis -join ', ')"
Write-Output "SignerSHA256: $actualSignerSha256"
Write-Output "SHA256: $digest"
