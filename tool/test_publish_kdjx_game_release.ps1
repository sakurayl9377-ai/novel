$ErrorActionPreference = "Stop"

$publisher = Join-Path $PSScriptRoot "publish_kdjx_game_release.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "novel-kdjx-release-$([Guid]::NewGuid().ToString('N'))"
$apkPath = Join-Path $testRoot "fixture.apk"
$approvedSigner = "1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
$legacySigner = "a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"
$downloadBaseUrls = @("https://novel.kxhub.xyz/games/kdjx")
$previousBypass = $env:KDJX_ALLOW_TEST_METADATA_BYPASS

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) {
        throw "$Message. Expected '$Expected', got '$Actual'."
    }
}

function Assert-Rejected([scriptblock]$Action, [string]$ExpectedMessage) {
    $message = ""
    try {
        & $Action | Out-Null
    } catch {
        $message = $_.Exception.Message
    }
    if ([string]::IsNullOrWhiteSpace($message)) {
        throw "Expected release operation to be rejected."
    }
    if (-not $message.Contains($ExpectedMessage)) {
        throw "Unexpected rejection: $message"
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
        -SigningCertificateSha256 $approvedSigner `
        -ApprovedSigningCertificateSha256 $approvedSigner `
        -OutDir $outDir `
        -DownloadBaseUrls $downloadBaseUrls `
        -SkipApkMetadataCheck `
        -Notes "offline validation"
    if ($generation -notcontains "KDJX release generated offline.") {
        throw "Publisher did not report a completed offline release."
    }
    $sha = (Get-FileHash -LiteralPath $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $apkName = "kdjx-$VersionCode-$($sha.Substring(0, 12)).apk"
    $manifestPath = Join-Path $outDir "manifest.json"
    $releaseApkPath = Join-Path $outDir $apkName
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $manifestPath | ConvertFrom-Json
    Assert-Equal "com.kd.kdjxcs" $manifest.packageName "Unexpected packageName"
    Assert-Equal $VersionName $manifest.versionName "Unexpected versionName"
    Assert-Equal $VersionCode ([int]$manifest.versionCode) "Unexpected versionCode"
    Assert-Equal `
        ([int64](Get-Item -LiteralPath $releaseApkPath).Length) `
        ([int64]$manifest.sizeBytes) `
        "Unexpected sizeBytes"
    Assert-Equal $sha $manifest.sha256 "Unexpected APK digest"
    Assert-Equal $approvedSigner $manifest.signingCertificateSha256 "Unexpected signer"
    Assert-Equal `
        "https://novel.kxhub.xyz/games/kdjx/$apkName" `
        $manifest.apkUrl `
        "Unexpected APK URL"
    Assert-Equal `
        (($downloadBaseUrls | ForEach-Object { "$_/$apkName" }) -join ",") `
        (@($manifest.apkUrls) -join ",") `
        "Unexpected APK mirror URLs"

    $validation = & $publisher `
        -ValidateOnly `
        -ManifestPath $manifestPath `
        -ApkPath $releaseApkPath `
        -ApprovedSigningCertificateSha256 $approvedSigner `
        -DownloadBaseUrls $downloadBaseUrls `
        -SkipApkMetadataCheck
    if (($validation -join "`n") -notmatch "Validated KDJX manifest") {
        throw "ValidateOnly did not report success."
    }

    $manifest.apkUrls = @(
        "https://mirror.kxhub.xyz/games/kdjx/$apkName"
    )
    $reorderedManifestPath = Join-Path $outDir "manifest-unverified-mirror.json"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content `
        -LiteralPath $reorderedManifestPath `
        -Encoding UTF8
    Assert-Rejected {
        & $publisher `
            -ValidateOnly `
            -ManifestPath $reorderedManifestPath `
            -ApkPath $releaseApkPath `
            -ApprovedSigningCertificateSha256 $approvedSigner `
            -DownloadBaseUrls $downloadBaseUrls `
            -SkipApkMetadataCheck
    } "apkUrl and apkUrls must match"
    Remove-Item -LiteralPath $reorderedManifestPath -Force

    $manifestHash = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    $historyPath = Join-Path $outDir "manifest-$VersionName+$VersionCode.json"
    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName $VersionName `
            -VersionCode $VersionCode `
            -SigningCertificateSha256 $approvedSigner `
            -ApprovedSigningCertificateSha256 $approvedSigner `
            -OutDir $outDir `
            -DownloadBaseUrls $downloadBaseUrls `
            -SkipApkMetadataCheck `
            -Notes "changed immutable history"
    } "immutable versioned manifest"
    Assert-Equal `
        $manifestHash `
        (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash `
        "Current manifest changed after a rejected history rewrite"
    Assert-Equal `
        $manifestHash `
        (Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash `
        "Versioned manifest changed after a rejected history rewrite"
}

$null = New-Item -ItemType Directory -Path $testRoot
try {
    $env:KDJX_ALLOW_TEST_METADATA_BYPASS = "1"
    New-FixtureApk $apkPath
    Test-Version "2.1.0.0" 3
    Test-Version "2.1.1" 4

    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "2.1.0.0" `
            -VersionCode 3 `
            -SigningCertificateSha256 $approvedSigner `
            -OutDir (Join-Path $testRoot "no-policy") `
            -SkipApkMetadataCheck
    } "ApprovedSigningCertificateSha256 is required"

    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "2.1.0.0" `
            -VersionCode 3 `
            -SigningCertificateSha256 $legacySigner `
            -ApprovedSigningCertificateSha256 $legacySigner `
            -OutDir (Join-Path $testRoot "legacy-signer") `
            -SkipApkMetadataCheck
    } "legacy Android test certificate"

    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "2.1.0.0" `
            -VersionCode 3 `
            -SigningCertificateSha256 ("2" * 64) `
            -ApprovedSigningCertificateSha256 $approvedSigner `
            -OutDir (Join-Path $testRoot "wrong-signer") `
            -SkipApkMetadataCheck
    } "not the approved production certificate"

    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "2.1.0.0" `
            -VersionCode 3 `
            -SigningCertificateSha256 $approvedSigner `
            -ApprovedSigningCertificateSha256 $approvedSigner `
            -DownloadBaseUrls "https://47.88.26.14/games/kdjx" `
            -OutDir (Join-Path $testRoot "raw-ip") `
            -SkipApkMetadataCheck
    } "TLS DNS hosts"

    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "2.1.0.0" `
            -VersionCode 3 `
            -SigningCertificateSha256 $approvedSigner `
            -ApprovedSigningCertificateSha256 $approvedSigner `
            -DownloadBaseUrls "https://novel.kxhub.xyz/games/kdjx,https://mirror.kxhub.xyz/games/kdjx" `
            -OutDir (Join-Path $testRoot "unverified-mirror") `
            -SkipApkMetadataCheck
    } "must contain only https://novel.kxhub.xyz/games/kdjx"

    $env:KDJX_ALLOW_TEST_METADATA_BYPASS = "0"
    Assert-Rejected {
        & $publisher `
            -ApkPath $apkPath `
            -VersionName "2.1.0.0" `
            -VersionCode 3 `
            -SigningCertificateSha256 $approvedSigner `
            -ApprovedSigningCertificateSha256 $approvedSigner `
            -OutDir (Join-Path $testRoot "bypass-disabled") `
            -SkipApkMetadataCheck
    } "restricted to the publisher unit test"
    Write-Output "KDJX release publisher tests passed."
} finally {
    if ($null -eq $previousBypass) {
        Remove-Item Env:KDJX_ALLOW_TEST_METADATA_BYPASS -ErrorAction SilentlyContinue
    } else {
        $env:KDJX_ALLOW_TEST_METADATA_BYPASS = $previousBypass
    }
    if (Test-Path -LiteralPath $testRoot) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}
