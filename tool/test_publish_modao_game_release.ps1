$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $PSScriptRoot
$publisher = Join-Path $PSScriptRoot "publish_modao_game_release.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "novel-modao-release-$([Guid]::NewGuid().ToString('N'))"
$apkPath = Join-Path $testRoot "fixture.apk"
$signer = "c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c"

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}
function New-FixtureApk([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $fileStream = [IO.File]::Open($Path, [IO.FileMode]::CreateNew)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new(
            $fileStream,
            [IO.Compression.ZipArchiveMode]::Create,
            $false
        )
        foreach ($name in @("AndroidManifest.xml", "classes.dex")) {
            $entry = $archive.CreateEntry($name)
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes("offline fixture: $name")
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $fileStream.Dispose()
    }
}

function Test-Version([string]$VersionName, [int]$VersionCode) {
    $outDir = Join-Path $testRoot "release-$VersionCode"
    $generation = & $publisher `
        -ApkPath $apkPath `
        -VersionName $VersionName `
        -VersionCode $VersionCode `
        -SigningCertificateSha256 $signer `
        -OutDir $outDir `
        -SkipApkMetadataCheck `
        -Notes "offline validation"
    if ($generation -notcontains "Modao release generated offline.") {
        throw "Publisher did not report a completed offline release."
    }
    $sha = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $apkName = "modao-$VersionCode-$($sha.Substring(0, 12)).apk"
    $manifestPath = Join-Path $outDir "manifest.json"
    $releaseApkPath = Join-Path $outDir $apkName
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    Assert-Equal "com.you91.fish.lucky" $manifest.packageName "Unexpected packageName"
    Assert-Equal $VersionName $manifest.versionName "Unexpected versionName"
    Assert-Equal $VersionCode ([int]$manifest.versionCode) "Unexpected versionCode"
    Assert-Equal ([int64](Get-Item -LiteralPath $releaseApkPath).Length) ([int64]$manifest.sizeBytes) "Unexpected sizeBytes"
    Assert-Equal $sha $manifest.sha256 "Unexpected APK digest"
    Assert-Equal $signer $manifest.signingCertificateSha256 "Unexpected signer digest"
    Assert-Equal "https://novel.kxhub.xyz/games/modao/$apkName" $manifest.apkUrl "Unexpected APK URL"

    $validation = & $publisher `
        -ValidateOnly `
        -ManifestPath $manifestPath `
        -ApkPath $releaseApkPath `
        -SkipApkMetadataCheck
    if (($validation -join "`n") -notmatch "Validated Modao manifest") {
        throw "ValidateOnly did not report success."
    }

    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $historyPath = Join-Path $outDir "manifest-$VersionName+$VersionCode.json"
    $historyRejected = $false
    try {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName $VersionName `
            -VersionCode $VersionCode `
            -SigningCertificateSha256 $signer `
            -OutDir $outDir `
            -SkipApkMetadataCheck `
            -Notes "changed history" | Out-Null
    } catch {
        $historyRejected = $true
    }
    if (-not $historyRejected) {
        throw "Publisher overwrote an immutable versioned manifest."
    }
    Assert-Equal $manifestHash (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash `
        "Current manifest changed after a rejected history rewrite"
    Assert-Equal $manifestHash (Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash `
        "Versioned manifest changed after a rejected history rewrite"
}

$null = New-Item -ItemType Directory -Path $testRoot
try {
    New-FixtureApk $apkPath
    Test-Version "1.2.3" 123
    Test-Version "10.0.0.0" 2023981000

    $rejected = $false
    try {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "1.2.3.4.5" `
            -VersionCode 124 `
            -SigningCertificateSha256 $signer `
            -OutDir (Join-Path $testRoot "invalid") `
            -SkipApkMetadataCheck | Out-Null
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "A five-segment versionName was not rejected." }

    $rejected = $false
    try {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "10.0.0.0" `
            -VersionCode 2100000001 `
            -SigningCertificateSha256 $signer `
            -OutDir (Join-Path $testRoot "invalid-version-code") `
            -SkipApkMetadataCheck | Out-Null
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "An Android-unsupported versionCode was not rejected." }

    $rejected = $false
    try {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "10.0.0.0" `
            -VersionCode 2023981001 `
            -SigningCertificateSha256 ("1" * 64) `
            -OutDir (Join-Path $testRoot "unapproved-signer") `
            -SkipApkMetadataCheck | Out-Null
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "An unapproved signing certificate was not rejected." }
    Write-Output "Modao release publisher tests passed."
} finally {
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
