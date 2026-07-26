param(
    [Parameter(Mandatory = $true)]
    [string]$KdjxSigningCertificateSha256,
    [int]$MaxSizeMiB = 120,
    [string]$NovelAppSigningCertificateSha256,
    [switch]$SkipClean
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
$legacyAndroidTestCertificateSha256 =
    "a40da80a59d170caa950cf15c18c454d47a39b26989d8b640ecd745ba71bf5dc"

function Fail([string]$Message) {
    throw "KDJX Android production build failed: $Message"
}

function Normalize-Sha256([string]$Value, [string]$Name) {
    $normalized = ($Value -replace ":", "" -replace "\s", "").ToLowerInvariant()
    if ($normalized -notmatch '^[0-9a-f]{64}$' -or $normalized -eq ("0" * 64)) {
        Fail "$Name must be a non-placeholder SHA-256 certificate digest"
    }
    if ($normalized -eq $legacyAndroidTestCertificateSha256) {
        Fail "$Name must not use the legacy Android test certificate"
    }
    return $normalized
}

$kdjxSigner = Normalize-Sha256 $KdjxSigningCertificateSha256 "KdjxSigningCertificateSha256"
$environmentValues = [ordered]@{
    ORG_GRADLE_PROJECT_KDJX_GAME_SIGNING_CERT_SHA256 = $kdjxSigner
}
$previousEnvironment = @{}

Push-Location $projectRoot
try {
    foreach ($name in $environmentValues.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
        Set-Item -Path "Env:$name" -Value $environmentValues[$name]
    }
    if (-not $SkipClean) {
        & flutter clean
        if ($LASTEXITCODE -ne 0) { Fail "flutter clean failed" }
    }
    & flutter pub get
    if ($LASTEXITCODE -ne 0) { Fail "flutter pub get failed" }
    & flutter build apk --release `
        "--dart-define=KDJX_SIGNING_CERT_SHA256=$kdjxSigner"
    if ($LASTEXITCODE -ne 0) { Fail "flutter build apk --release failed" }

    $verificationArguments = @{ MaxSizeMiB = $MaxSizeMiB }
    if (-not [string]::IsNullOrWhiteSpace($NovelAppSigningCertificateSha256)) {
        $verificationArguments.ExpectedSignerSha256 =
            Normalize-Sha256 $NovelAppSigningCertificateSha256 "NovelAppSigningCertificateSha256"
    }
    & "$PSScriptRoot/verify_android_release.ps1" @verificationArguments
} finally {
    foreach ($name in $environmentValues.Keys) {
        $previous = $previousEnvironment[$name]
        if ($null -eq $previous) {
            Remove-Item -Path "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$name" -Value $previous
        }
    }
    Pop-Location
}
