param(
    [Parameter(Mandatory = $false)]
    [string]$ApkPath,
    [Parameter(Mandatory = $false)]
    [string]$ManifestPath,
    [Parameter(Mandatory = $false)]
    [string]$VersionName,
    [Parameter(Mandatory = $false)]
    [int]$VersionCode,
    [Parameter(Mandatory = $false)]
    [string]$SigningCertificateSha256,
    [string]$ApprovedSigningCertificateSha256 = $env:KDJX_APPROVED_SIGNING_CERTIFICATE_SHA256,
    [string]$OutDir = "build/kdjx-release",
    [Alias("BaseUrl")]
    [string[]]$DownloadBaseUrls = @("https://novel.kxhub.xyz/games/kdjx"),
    [string[]]$Notes = @(),
    [switch]$ValidateOnly,
    [switch]$SkipApkMetadataCheck
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$maximumApkBytes = [int64]4 * 1024 * 1024 * 1024
$maximumVersionCode = 2100000000
$expectedPackageName = "com.kd.kdjxcs"
$legacyAndroidTestCertificateSha256 =
    "a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"
$primaryDownloadBaseUrl = "https://novel.kxhub.xyz/games/kdjx"
$temporaryFiles = [System.Collections.Generic.List[string]]::new()
$lockStream = $null

function Fail([string]$Message) {
    throw "KDJX release validation failed: $Message"
}

function Normalize-Hash([string]$Value) {
    if ($null -eq $Value) { return "" }
    return ($Value -replace ":", "" -replace "\s", "").ToLowerInvariant()
}

function Assert-Sha256([string]$Value, [string]$FieldName) {
    $normalized = Normalize-Hash $Value
    if ($normalized -notmatch '^[a-f0-9]{64}$') {
        Fail "$FieldName must be a SHA-256 hex digest"
    }
    return $normalized
}

function Get-ApprovedSigner {
    if ([string]::IsNullOrWhiteSpace($ApprovedSigningCertificateSha256)) {
        Fail "ApprovedSigningCertificateSha256 is required after the APK is signed with the production key"
    }
    $approved = Assert-Sha256 `
        $ApprovedSigningCertificateSha256 `
        "ApprovedSigningCertificateSha256"
    if ($approved -eq ("0" * 64)) {
        Fail "ApprovedSigningCertificateSha256 must not be a placeholder"
    }
    if ($approved -eq $legacyAndroidTestCertificateSha256) {
        Fail "the legacy Android test certificate is not approved for production"
    }
    return $approved
}

function Assert-Version([string]$Name, [int]$Code) {
    if ($Name -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        Fail "versionName must contain 3 or 4 numeric segments"
    }
    if ($Code -le 0 -or $Code -gt $maximumVersionCode) {
        Fail "versionCode must be between 1 and $maximumVersionCode"
    }
}

function Resolve-DownloadBaseUrls([string[]]$Values) {
    $resolved = [System.Collections.Generic.List[string]]::new()
    foreach ($rawValue in $Values) {
        foreach ($value in ([string]$rawValue -split ',')) {
            $uri = $null
            if (-not [Uri]::TryCreate($value.Trim(), [UriKind]::Absolute, [ref]$uri) -or
                $uri.Scheme -ne "https" -or
                ($uri.Port -ne -1 -and $uri.Port -ne 443) -or
                $uri.UserInfo -or
                $uri.Query -or
                $uri.Fragment -or
                $uri.AbsolutePath.TrimEnd('/') -ne "/games/kdjx") {
                Fail "DownloadBaseUrls must use HTTPS /games/kdjx base URLs"
            }
            $downloadHost = $uri.Host.ToLowerInvariant()
            $address = $null
            if ([Net.IPAddress]::TryParse($downloadHost, [ref]$address) -or
                $downloadHost -notmatch '^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$') {
                Fail "DownloadBaseUrls must use TLS DNS hosts, not raw IP addresses"
            }
            $normalized = "https://$downloadHost/games/kdjx"
            if (-not $resolved.Contains($normalized)) { $resolved.Add($normalized) }
        }
    }
    if ($resolved.Count -ne 1 -or $resolved[0] -ne $primaryDownloadBaseUrl) {
        Fail "DownloadBaseUrls must contain only $primaryDownloadBaseUrl"
    }
    return $resolved.ToArray()
}

function Assert-ApkArchive([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        if ($null -eq $archive.GetEntry("AndroidManifest.xml") -or
            $null -eq $archive.GetEntry("classes.dex")) {
            Fail "APK must contain AndroidManifest.xml and classes.dex"
        }
        foreach ($entry in $archive.Entries) {
            $stream = $null
            try {
                $stream = $entry.Open()
                $buffer = New-Object byte[] 1048576
                while ($stream.Read($buffer, 0, $buffer.Length) -gt 0) { }
            } finally {
                if ($null -ne $stream) { $stream.Dispose() }
            }
        }
    } catch [IO.InvalidDataException] {
        Fail "APK is not a valid ZIP archive"
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
    }
}

function Find-AndroidTool([string]$FileName) {
    $command = Get-Command $FileName -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, "G:\Android\Sdk")) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            -not $roots.Contains($candidate)) {
            $roots.Add($candidate)
        }
    }
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $matches = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $FileName `
            -ErrorAction SilentlyContinue | Sort-Object FullName -Descending)
        if ($matches.Count -gt 0) { return $matches[0].FullName }
    }
    return $null
}

function Invoke-AndroidTool([string]$ToolPath, [string[]]$Arguments) {
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & $ToolPath @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0) {
        Fail "Android SDK tool rejected the APK: $ToolPath`n$($output -join "`n")"
    }
    return ($output | Out-String).Trim()
}

function Assert-ApkMetadata(
    [string]$Path,
    [string]$ExpectedVersionName,
    [int]$ExpectedVersionCode,
    [string]$ExpectedSigner
) {
    if ($SkipApkMetadataCheck) {
        if ($env:KDJX_ALLOW_TEST_METADATA_BYPASS -ne "1") {
            Fail "SkipApkMetadataCheck is restricted to the publisher unit test"
        }
        return
    }
    $apkanalyzer = Find-AndroidTool "apkanalyzer.bat"
    if ($null -eq $apkanalyzer) { $apkanalyzer = Find-AndroidTool "apkanalyzer" }
    $apksigner = Find-AndroidTool "apksigner.bat"
    if ($null -eq $apksigner) { $apksigner = Find-AndroidTool "apksigner" }
    if ($null -eq $apkanalyzer -or $null -eq $apksigner) {
        Fail "apkanalyzer and apksigner are required"
    }
    $actualPackage = Invoke-AndroidTool $apkanalyzer @(
        "manifest", "application-id", $Path
    )
    $actualVersionName = Invoke-AndroidTool $apkanalyzer @(
        "manifest", "version-name", $Path
    )
    $actualVersionCode = Invoke-AndroidTool $apkanalyzer @(
        "manifest", "version-code", $Path
    )
    if ($actualPackage -ne $expectedPackageName) {
        Fail "APK applicationId is '$actualPackage', expected '$expectedPackageName'"
    }
    if ($actualVersionName -ne $ExpectedVersionName -or
        $actualVersionCode -ne [string]$ExpectedVersionCode) {
        Fail "APK version metadata does not match the release arguments"
    }
    $signatureOutput = Invoke-AndroidTool $apksigner @(
        "verify", "--verbose", "--print-certs", $Path
    )
    $digests = @([regex]::Matches(
        $signatureOutput,
        'certificate\s+SHA-256\s+digest:\s*([0-9A-Fa-f:]+)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    ) | ForEach-Object { Normalize-Hash $_.Groups[1].Value } | Select-Object -Unique)
    if ($digests.Count -eq 0 -or @($digests | Where-Object { $_ -ne $ExpectedSigner }).Count -gt 0) {
        Fail "APK signer certificate does not match the approved certificate"
    }
}

function Read-Manifest([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Fail "manifest not found: $Path"
    }
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $Path | ConvertFrom-Json
    } catch {
        Fail "manifest is not valid UTF-8 JSON"
    }
}

function Validate-ManifestAndApk(
    [string]$ResolvedManifest,
    [string]$ResolvedApk,
    [string]$ApprovedSigner,
    [string[]]$AllowedDownloadBaseUrls
) {
    $manifest = Read-Manifest $ResolvedManifest
    if ($null -eq $manifest -or [string]$manifest.packageName -ne $expectedPackageName) {
        Fail "packageName must be $expectedPackageName"
    }
    $manifestVersionName = [string]$manifest.versionName
    if ($manifest.versionCode -is [bool] -or [string]$manifest.versionCode -notmatch '^\d+$') {
        Fail "versionCode is invalid"
    }
    try { $manifestVersionCode = [int]$manifest.versionCode } catch { Fail "versionCode is invalid" }
    Assert-Version $manifestVersionName $manifestVersionCode
    if ([string]$manifest.sha256 -notmatch '^[a-f0-9]{64}$' -or
        [string]$manifest.signingCertificateSha256 -notmatch '^[a-f0-9]{64}$') {
        Fail "manifest digests must be lowercase SHA-256 hexadecimal"
    }
    $manifestSha = Assert-Sha256 ([string]$manifest.sha256) "sha256"
    $manifestSigner = Assert-Sha256 `
        ([string]$manifest.signingCertificateSha256) `
        "signingCertificateSha256"
    if ($manifestSigner -ne $ApprovedSigner) {
        Fail "signingCertificateSha256 is not the approved production certificate"
    }
    if ($manifest.sizeBytes -is [bool] -or [string]$manifest.sizeBytes -notmatch '^\d+$') {
        Fail "sizeBytes is invalid"
    }
    try { $manifestSize = [int64]$manifest.sizeBytes } catch { Fail "sizeBytes is invalid" }
    if ($manifestSize -le 0 -or $manifestSize -gt $maximumApkBytes) {
        Fail "sizeBytes is outside the supported APK range"
    }
    $expectedName = "kdjx-$manifestVersionCode-$($manifestSha.Substring(0, 12)).apk"
    $expectedUrls = @($AllowedDownloadBaseUrls | ForEach-Object {
        "$_/$expectedName"
    })
    [string[]]$manifestUrls = if ($null -eq $manifest.apkUrls) {
        @()
    } else {
        @($manifest.apkUrls | ForEach-Object { [string]$_ })
    }
    $urlsMatch = $manifestUrls.Count -eq $expectedUrls.Count
    if ($urlsMatch) {
        for ($index = 0; $index -lt $expectedUrls.Count; $index++) {
            if ($manifestUrls[$index] -ne $expectedUrls[$index]) {
                $urlsMatch = $false
                break
            }
        }
    }
    if ([string]$manifest.apkUrl -ne $expectedUrls[0] -or
        -not $urlsMatch) {
        Fail "apkUrl and apkUrls must match the configured download base URLs"
    }
    $notes = @($manifest.notes)
    if ($null -eq $manifest.notes -or $notes.Count -gt 8) {
        Fail "notes must be an array with at most 8 entries"
    }
    foreach ($note in $notes) {
        if ($note -isnot [string] -or [string]::IsNullOrWhiteSpace($note) -or
            $note.Length -gt 200) {
            Fail "each release note must contain 1 to 200 characters"
        }
    }
    if (-not (Test-Path -LiteralPath $ResolvedApk -PathType Leaf)) {
        Fail "APK not found: $ResolvedApk"
    }
    $apk = Get-Item -LiteralPath $ResolvedApk
    if ($apk.Name -ne $expectedName -or $apk.Length -ne $manifestSize) {
        Fail "APK name or size does not match manifest"
    }
    $actualSha = (Get-FileHash -LiteralPath $ResolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $manifestSha) {
        Fail "APK SHA-256 does not match manifest"
    }
    Assert-ApkArchive $ResolvedApk
    return $manifest
}

Push-Location $projectRoot
try {
    $approvedSigner = Get-ApprovedSigner
    [string[]]$downloadBaseUrls = @(Resolve-DownloadBaseUrls $DownloadBaseUrls)
    if ($ValidateOnly) {
        if ([string]::IsNullOrWhiteSpace($ManifestPath) -or
            [string]::IsNullOrWhiteSpace($ApkPath)) {
            Fail "ManifestPath and ApkPath are required with ValidateOnly"
        }
        $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
        $resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
        $manifest = Validate-ManifestAndApk `
            $resolvedManifest `
            $resolvedApk `
            $approvedSigner `
            $downloadBaseUrls
        Assert-ApkMetadata `
            $resolvedApk `
            ([string]$manifest.versionName) `
            ([int]$manifest.versionCode) `
            $approvedSigner
        Write-Output "Validated KDJX manifest: $resolvedManifest"
        Write-Output "APK: $resolvedApk"
        Write-Output "Version: $($manifest.versionName)+$($manifest.versionCode)"
        Write-Output "SHA256: $($manifest.sha256)"
        return
    }

    if ([string]::IsNullOrWhiteSpace($ApkPath) -or
        [string]::IsNullOrWhiteSpace($VersionName) -or
        $VersionCode -le 0 -or
        [string]::IsNullOrWhiteSpace($SigningCertificateSha256)) {
        Fail "ApkPath, VersionName, VersionCode, and SigningCertificateSha256 are required"
    }
    Assert-Version $VersionName $VersionCode
    $signer = Assert-Sha256 $SigningCertificateSha256 "SigningCertificateSha256"
    if ($signer -ne $approvedSigner) {
        Fail "SigningCertificateSha256 is not the approved production certificate"
    }
    $releaseNotes = @($Notes | Where-Object {
        -not [string]::IsNullOrWhiteSpace($_)
    } | ForEach-Object { $_.Trim() })
    if ($releaseNotes.Count -gt 8 -or
        @($releaseNotes | Where-Object { $_.Length -gt 200 }).Count -gt 0) {
        Fail "Notes may contain at most 8 entries of up to 200 characters"
    }
    $resolvedSource = (Resolve-Path -LiteralPath $ApkPath).Path
    $sourceInfo = Get-Item -LiteralPath $resolvedSource
    if ($sourceInfo.Length -le 0 -or $sourceInfo.Length -gt $maximumApkBytes) {
        Fail "APK is outside the supported 4 GiB size range"
    }
    Assert-ApkArchive $resolvedSource
    Assert-ApkMetadata $resolvedSource $VersionName $VersionCode $approvedSigner
    $sha = (Get-FileHash -LiteralPath $resolvedSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifactName = "kdjx-$VersionCode-$($sha.Substring(0, 12)).apk"
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $outputRoot = (Resolve-Path -LiteralPath $OutDir).ProviderPath
    $lockPath = Join-Path $outputRoot ".kdjx-release.lock"
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch {
        Fail "another KDJX release process is using $outputRoot"
    }
    $artifactPath = Join-Path $outputRoot $artifactName
    $manifestPathOut = Join-Path $outputRoot "manifest.json"
    $historyPath = Join-Path $outputRoot "manifest-$VersionName+$VersionCode.json"
    if (Test-Path -LiteralPath $artifactPath) {
        $existingSha = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingSha -ne $sha) {
            Fail "immutable artifact already exists with a different digest"
        }
    } else {
        $temporaryArtifact = "$artifactPath.$([Guid]::NewGuid().ToString('N')).tmp"
        $temporaryFiles.Add($temporaryArtifact)
        Copy-Item -LiteralPath $resolvedSource -Destination $temporaryArtifact
        if ((Get-FileHash -LiteralPath $temporaryArtifact -Algorithm SHA256).Hash.ToLowerInvariant() -ne $sha) {
            Fail "APK copy failed integrity verification"
        }
        Move-Item -LiteralPath $temporaryArtifact -Destination $artifactPath
        $temporaryFiles.Remove($temporaryArtifact) | Out-Null
    }
    $metadata = [ordered]@{
        packageName = $expectedPackageName
        versionName = $VersionName
        versionCode = $VersionCode
        apkUrl = "$($downloadBaseUrls[0])/$artifactName"
        apkUrls = @($downloadBaseUrls | ForEach-Object { "$_/$artifactName" })
        sizeBytes = [int64]$sourceInfo.Length
        sha256 = $sha
        signingCertificateSha256 = $approvedSigner
        notes = $releaseNotes
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $candidate = "$manifestPathOut.$([Guid]::NewGuid().ToString('N')).tmp"
    $temporaryFiles.Add($candidate)
    [IO.File]::WriteAllText(
        $candidate,
        "$(($metadata | ConvertTo-Json -Depth 8))`n",
        $utf8
    )
    $null = Validate-ManifestAndApk `
        $candidate `
        $artifactPath `
        $approvedSigner `
        $downloadBaseUrls
    if (Test-Path -LiteralPath $historyPath) {
        if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ne
            (Get-FileHash -LiteralPath $historyPath -Algorithm SHA256).Hash) {
            Fail "immutable versioned manifest already exists with different content"
        }
    } else {
        $temporaryHistory = "$historyPath.$([Guid]::NewGuid().ToString('N')).tmp"
        $temporaryFiles.Add($temporaryHistory)
        Copy-Item -LiteralPath $candidate -Destination $temporaryHistory
        Move-Item -LiteralPath $temporaryHistory -Destination $historyPath
        $temporaryFiles.Remove($temporaryHistory) | Out-Null
    }
    Move-Item -LiteralPath $candidate -Destination $manifestPathOut -Force
    $temporaryFiles.Remove($candidate) | Out-Null
    Write-Output "KDJX release generated offline."
    Write-Output "APK: $artifactPath"
    Write-Output "Manifest: $manifestPathOut"
    Write-Output "Versioned manifest: $historyPath"
    Write-Output "Download URL: $($metadata.apkUrl)"
    Write-Output "SHA256: $sha"
} finally {
    foreach ($temporaryFile in $temporaryFiles) {
        if (Test-Path -LiteralPath $temporaryFile) {
            Remove-Item -LiteralPath $temporaryFile -Force
        }
    }
    if ($null -ne $lockStream) { $lockStream.Dispose() }
    Pop-Location
}
