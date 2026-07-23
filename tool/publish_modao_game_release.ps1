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
    [string]$OutDir = "build/modao-release",
    [string]$BaseUrl = "https://novel.kxhub.xyz/games/modao",
    [string[]]$Notes = @(),
    [switch]$ValidateOnly,
    [switch]$SkipApkMetadataCheck
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$maximumApkBytes = [int64]4 * 1024 * 1024 * 1024
$maximumVersionCode = 2100000000
$expectedPackageName = "com.you91.fish.lucky"
$expectedSigningCertificateSha256 = "c345303f1b945e5b49100d38edc2abf85cd0513f0f240437e03a7face9e2f37c"
$temporaryFiles = [System.Collections.Generic.List[string]]::new()
$lockStream = $null

function Fail([string]$Message) {
    throw "Modao release validation failed: $Message"
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

function Assert-Version([string]$Name, [int]$Code) {
    if ($Name -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        Fail "versionName must contain 3 or 4 numeric segments"
    }
    if ($Code -le 0 -or $Code -gt $maximumVersionCode) {
        Fail "versionCode must be between 1 and $maximumVersionCode"
    }
}

function Assert-BaseUrl([string]$Value) {
    $uri = $null
    if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -ne "https" -or
        $uri.Host -ne "novel.kxhub.xyz" -or
        ($uri.Port -ne -1 -and $uri.Port -ne 443) -or
        $uri.UserInfo -or
        $uri.Query -or
        $uri.Fragment) {
        Fail "BaseUrl must be https://novel.kxhub.xyz/games/modao"
    }
    $path = $uri.AbsolutePath.TrimEnd('/')
    if ($path -ne "/games/modao") {
        Fail "BaseUrl must end at /games/modao"
    }
    return $uri.AbsoluteUri.TrimEnd('/')
}

function Assert-ApkArchive([string]$Path) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = $null
    try {
        $archive = [IO.Compression.ZipFile]::OpenRead($Path)
        $manifestEntry = $archive.GetEntry("AndroidManifest.xml")
        $dexEntry = $archive.GetEntry("classes.dex")
        if ($null -eq $manifestEntry -or $null -eq $dexEntry) {
            Fail "APK must contain AndroidManifest.xml and classes.dex"
        }
        foreach ($entry in $archive.Entries) {
            # Reading every entry catches truncated/corrupt ZIP payloads without
            # loading a multi-gigabyte APK into memory.
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
    $sdkRoots = [System.Collections.Generic.List[string]]::new()
    foreach ($candidate in @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME, "G:\Android\Sdk")) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and
            -not $sdkRoots.Contains($candidate)) {
            $sdkRoots.Add($candidate)
        }
    }
    foreach ($root in $sdkRoots) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $matches = @(Get-ChildItem -LiteralPath $root -Recurse -File -Filter $FileName -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending)
        if ($matches.Count -gt 0) { return $matches[0].FullName }
    }
    return $null
}

function Invoke-AndroidTool([string]$ToolPath, [string[]]$Arguments) {
    $output = & $ToolPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        Fail "Android SDK tool failed: $ToolPath"
    }
    return ($output | Out-String).Trim()
}

function Assert-ApkMetadata([string]$Path, [string]$VersionName, [int]$VersionCode, [string]$Signer) {
    if ($SkipApkMetadataCheck) { return }
    $apkanalyzer = Find-AndroidTool "apkanalyzer.bat"
    if ($null -eq $apkanalyzer) { $apkanalyzer = Find-AndroidTool "apkanalyzer" }
    $apksigner = Find-AndroidTool "apksigner.bat"
    if ($null -eq $apksigner) { $apksigner = Find-AndroidTool "apksigner" }
    if ($null -eq $apkanalyzer -or $null -eq $apksigner) {
        Fail "apkanalyzer and apksigner are required; use -SkipApkMetadataCheck only after an independent verification"
    }
    $actualPackage = Invoke-AndroidTool $apkanalyzer @("manifest", "application-id", $Path)
    $actualVersionName = Invoke-AndroidTool $apkanalyzer @("manifest", "version-name", $Path)
    $actualVersionCode = Invoke-AndroidTool $apkanalyzer @("manifest", "version-code", $Path)
    if ($actualPackage -ne $expectedPackageName) {
        Fail "APK applicationId is '$actualPackage', expected '$expectedPackageName'"
    }
    if ($actualVersionName -ne $VersionName -or $actualVersionCode -ne [string]$VersionCode) {
        Fail "APK version metadata does not match the release arguments"
    }
    $signatureOutput = Invoke-AndroidTool $apksigner @("verify", "--print-certs", $Path)
    $digests = [regex]::Matches(
        $signatureOutput,
        'certificate\s+SHA-256\s+digest:\s*([0-9A-Fa-f:]+)',
        [Text.RegularExpressions.RegexOptions]::IgnoreCase
    ) | ForEach-Object { Normalize-Hash $_.Groups[1].Value }
    if (-not ($digests -contains $Signer)) {
        Fail "APK signer certificate does not match signingCertificateSha256"
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

function Validate-ManifestAndApk([string]$ResolvedManifest, [string]$ResolvedApk) {
    $manifest = Read-Manifest $ResolvedManifest
    if ($null -eq $manifest) { Fail "manifest is empty" }
    if ([string]$manifest.packageName -ne $expectedPackageName) {
        Fail "packageName must be $expectedPackageName"
    }
    $manifestVersionName = [string]$manifest.versionName
    if ($manifest.versionCode -is [bool] -or [string]$manifest.versionCode -notmatch '^\d+$') {
        Fail "versionCode is invalid"
    }
    $manifestVersionCode = 0
    try { $manifestVersionCode = [int]$manifest.versionCode } catch { Fail "versionCode is invalid" }
    Assert-Version $manifestVersionName $manifestVersionCode
    if ([string]$manifest.sha256 -notmatch '^[a-f0-9]{64}$') {
        Fail "sha256 must be lowercase hexadecimal"
    }
    if ([string]$manifest.signingCertificateSha256 -notmatch '^[a-f0-9]{64}$') {
        Fail "signingCertificateSha256 must be lowercase hexadecimal"
    }
    $manifestSha = Assert-Sha256 ([string]$manifest.sha256) "sha256"
    $manifestSigner = Assert-Sha256 ([string]$manifest.signingCertificateSha256) "signingCertificateSha256"
    if ($manifestSigner -ne $expectedSigningCertificateSha256) {
        Fail "signingCertificateSha256 is not the approved game certificate"
    }
    if ($manifest.sizeBytes -is [bool] -or [string]$manifest.sizeBytes -notmatch '^\d+$') {
        Fail "sizeBytes is invalid"
    }
    $manifestSize = 0L
    try { $manifestSize = [int64]$manifest.sizeBytes } catch { Fail "sizeBytes is invalid" }
    if ($manifestSize -le 0 -or $manifestSize -gt $maximumApkBytes) {
        Fail "sizeBytes is outside the supported APK range"
    }
    $manifestUrl = [string]$manifest.apkUrl
    $expectedName = "modao-$manifestVersionCode-$($manifestSha.Substring(0, 12)).apk"
    $expectedUrl = "https://novel.kxhub.xyz/games/modao/$expectedName"
    $url = $null
    if (-not [Uri]::TryCreate($manifestUrl, [UriKind]::Absolute, [ref]$url) -or
        $url.AbsoluteUri -ne $expectedUrl) {
        Fail "apkUrl must be $expectedUrl"
    }
    $manifestNotes = @($manifest.notes)
    if ($null -eq $manifest.notes -or $manifestNotes.Count -gt 8) {
        Fail "notes must be an array with at most 8 entries"
    }
    foreach ($note in $manifestNotes) {
        if ($note -isnot [string] -or [string]::IsNullOrWhiteSpace($note) -or $note.Length -gt 200) {
            Fail "each release note must contain 1 to 200 characters"
        }
    }
    if (-not (Test-Path -LiteralPath $ResolvedApk -PathType Leaf)) {
        Fail "APK not found: $ResolvedApk"
    }
    $apk = Get-Item -LiteralPath $ResolvedApk
    if ($apk.Length -ne $manifestSize) {
        Fail "APK size does not match manifest"
    }
    if ($apk.Length -le 0 -or $apk.Length -gt $maximumApkBytes) {
        Fail "APK is outside the supported size range"
    }
    if ($apk.Name -ne $expectedName) {
        Fail "APK file name must be $expectedName"
    }
    $actualSha = (Get-FileHash -LiteralPath $ResolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha -ne $manifestSha) {
        Fail "APK SHA-256 does not match manifest"
    }
    Assert-ApkArchive $ResolvedApk
    return $manifest
}

function Get-ArtifactName([int]$Code, [string]$Sha) {
    return "modao-$Code-$($Sha.Substring(0, 12)).apk"
}

Push-Location $projectRoot
try {
    if ($ValidateOnly) {
        if ([string]::IsNullOrWhiteSpace($ManifestPath)) { Fail "ManifestPath is required with ValidateOnly" }
        if ([string]::IsNullOrWhiteSpace($ApkPath)) { Fail "ApkPath is required with ValidateOnly" }
        $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
        $resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
        $manifest = Validate-ManifestAndApk $resolvedManifest $resolvedApk
        Assert-ApkMetadata $resolvedApk ([string]$manifest.versionName) ([int]$manifest.versionCode) (Normalize-Hash ([string]$manifest.signingCertificateSha256))
        Write-Output "Validated Modao manifest: $resolvedManifest"
        Write-Output "APK: $resolvedApk"
        Write-Output "Version: $($manifest.versionName)+$($manifest.versionCode)"
        Write-Output "SHA256: $($manifest.sha256.ToLowerInvariant())"
        return
    }

    if ([string]::IsNullOrWhiteSpace($ApkPath)) { Fail "ApkPath is required" }
    if ([string]::IsNullOrWhiteSpace($VersionName)) { Fail "VersionName is required" }
    if ($VersionCode -le 0) { Fail "VersionCode is required" }
    if ([string]::IsNullOrWhiteSpace($SigningCertificateSha256)) {
        Fail "SigningCertificateSha256 is required"
    }
    Assert-Version $VersionName $VersionCode
    $signer = Assert-Sha256 $SigningCertificateSha256 "SigningCertificateSha256"
    if ($signer -ne $expectedSigningCertificateSha256) {
        Fail "SigningCertificateSha256 is not the approved game certificate"
    }
    $baseUrl = Assert-BaseUrl $BaseUrl
    $releaseNotes = @($Notes | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($releaseNotes.Count -gt 8 -or @($releaseNotes | Where-Object { $_.Length -gt 200 }).Count -gt 0) {
        Fail "Notes may contain at most 8 entries of up to 200 characters"
    }
    $resolvedApkSource = (Resolve-Path -LiteralPath $ApkPath).Path
    $sourceInfo = Get-Item -LiteralPath $resolvedApkSource
    if ($sourceInfo.Length -le 0 -or $sourceInfo.Length -gt $maximumApkBytes) {
        Fail "APK is outside the supported 4 GiB size range"
    }
    Assert-ApkArchive $resolvedApkSource
    Assert-ApkMetadata $resolvedApkSource $VersionName $VersionCode $signer
    $sha = (Get-FileHash -LiteralPath $resolvedApkSource -Algorithm SHA256).Hash.ToLowerInvariant()
    $artifactName = Get-ArtifactName $VersionCode $sha
    $null = New-Item -ItemType Directory -Force -Path $OutDir
    $outputRoot = (Resolve-Path -LiteralPath $OutDir).ProviderPath
    $lockPath = Join-Path $outputRoot ".modao-release.lock"
    try {
        $lockStream = [IO.File]::Open(
            $lockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )
    } catch {
        Fail "another Modao release process is using $outputRoot"
    }
    $artifactPath = Join-Path $outputRoot $artifactName
    $manifestPathOut = Join-Path $outputRoot "manifest.json"
    $versionedManifestPath = Join-Path $outputRoot "manifest-$VersionName+$VersionCode.json"
    if (Test-Path -LiteralPath $artifactPath) {
        $existingSha = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($existingSha -ne $sha) { Fail "immutable artifact already exists with a different digest" }
    } else {
        $temporaryArtifact = "$artifactPath.$([Guid]::NewGuid().ToString('N')).tmp"
        $temporaryFiles.Add($temporaryArtifact)
        Copy-Item -LiteralPath $resolvedApkSource -Destination $temporaryArtifact
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
        apkUrl = "$baseUrl/$artifactName"
        sizeBytes = [int64]$sourceInfo.Length
        sha256 = $sha
        signingCertificateSha256 = $signer
        notes = $releaseNotes
    }
    $json = $metadata | ConvertTo-Json -Depth 8
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $manifestCandidate = "$manifestPathOut.$([Guid]::NewGuid().ToString('N')).tmp"
    $temporaryFiles.Add($manifestCandidate)
    [IO.File]::WriteAllText($manifestCandidate, "$json`n", $utf8)
    $null = Validate-ManifestAndApk $manifestCandidate $artifactPath

    if (Test-Path -LiteralPath $versionedManifestPath) {
        $candidateHash = (Get-FileHash -LiteralPath $manifestCandidate -Algorithm SHA256).Hash
        $historyHash = (Get-FileHash -LiteralPath $versionedManifestPath -Algorithm SHA256).Hash
        if ($candidateHash -ne $historyHash) {
            Fail "immutable versioned manifest already exists with different content"
        }
    } else {
        $temporaryHistory = "$versionedManifestPath.$([Guid]::NewGuid().ToString('N')).tmp"
        $temporaryFiles.Add($temporaryHistory)
        Copy-Item -LiteralPath $manifestCandidate -Destination $temporaryHistory
        Move-Item -LiteralPath $temporaryHistory -Destination $versionedManifestPath
        $temporaryFiles.Remove($temporaryHistory) | Out-Null
    }
    Move-Item -LiteralPath $manifestCandidate -Destination $manifestPathOut -Force
    $temporaryFiles.Remove($manifestCandidate) | Out-Null
    Write-Output "Modao release generated offline."
    Write-Output "APK: $artifactPath"
    Write-Output "Manifest: $manifestPathOut"
    Write-Output "Versioned manifest: $versionedManifestPath"
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
