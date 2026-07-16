param(
  [ValidateRange(1, 999999)]
  [int]$BetaNumber = 1,
  [string]$ApiBaseUrl = 'http://10.0.2.2:3010/api',
  [string]$WebSocketBaseUrl = 'ws://10.0.2.2:3010/ws'
)

$ErrorActionPreference = 'Stop'

function Assert-BetaEndpoint {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name,
    [Parameter(Mandatory = $true)]
    [string]$Value,
    [Parameter(Mandatory = $true)]
    [string[]]$AllowedSchemes
  )

  $uri = $null
  if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri)) {
    throw "$Name must be an absolute URL."
  }

  $scheme = $uri.Scheme.ToLowerInvariant()
  if ($AllowedSchemes -notcontains $scheme) {
    throw "$Name must use one of these schemes: $($AllowedSchemes -join ', ')."
  }
  if ([string]::IsNullOrWhiteSpace($uri.Host)) {
    throw "$Name must include a host."
  }
  if (-not [string]::IsNullOrEmpty($uri.UserInfo) -or
      -not [string]::IsNullOrEmpty($uri.Query) -or
      -not [string]::IsNullOrEmpty($uri.Fragment)) {
    throw "$Name must not contain credentials, query parameters, or a fragment."
  }

  $endpointHost = $uri.DnsSafeHost.TrimEnd('.').ToLowerInvariant()
  $isProductionHost = $endpointHost -eq '49.232.137.85' -or
    $endpointHost -eq 'novel.kxhub.xyz' -or
    $endpointHost.EndsWith('.novel.kxhub.xyz', [StringComparison]::Ordinal)
  if ($isProductionHost) {
    throw "$Name points to a production host. Reader beta builds require a local or dedicated test environment."
  }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactDirectory = Join-Path $repoRoot 'build\test-artifacts'
$artifactName = "sakura-reader-beta-$BetaNumber-arm64-v8a.apk"
$artifactPath = Join-Path $artifactDirectory $artifactName
$checksumPath = "$artifactPath.sha256"
$verificationScript = Join-Path $PSScriptRoot 'verify_reader_beta_apk.ps1'
$artifactRelativePath = "build/test-artifacts/$artifactName"
$checksumRelativePath = "$artifactRelativePath.sha256"
$sourceApk = Join-Path $repoRoot `
  'build\app\outputs\flutter-apk\app-arm64-v8a-profile.apk'
$gradleCacheDirectory = Join-Path $repoRoot 'build\reader-beta-gradle-cache'

Assert-BetaEndpoint `
  -Name 'ApiBaseUrl' `
  -Value $ApiBaseUrl `
  -AllowedSchemes @('http', 'https')
Assert-BetaEndpoint `
  -Name 'WebSocketBaseUrl' `
  -Value $WebSocketBaseUrl `
  -AllowedSchemes @('ws', 'wss')

New-Item -ItemType Directory -Path $artifactDirectory -Force | Out-Null

Push-Location $repoRoot
try {
  foreach ($ignoredPath in @($artifactRelativePath, $checksumRelativePath)) {
    & git check-ignore --quiet -- $ignoredPath
    if ($LASTEXITCODE -ne 0) {
      throw "Beta APK output must remain inside a Git-ignored directory: $ignoredPath"
    }
  }

  Remove-Item -LiteralPath $artifactPath, $checksumPath, $sourceApk `
    -Force `
    -ErrorAction SilentlyContinue

  # Profile keeps the independent beta debuggable for local diagnostics while
  # compiling Dart AOT. A debug/JIT APK is far too noisy for reader smoothness
  # acceptance on memory-constrained physical devices.
  & flutter build apk --profile --no-pub --split-per-abi `
    --target-platform android-arm64 `
    --android-project-cache-dir $gradleCacheDirectory `
    "--android-project-arg=readerBeta=true" `
    "--android-project-arg=readerBetaNumber=$BetaNumber" `
    "--dart-define=READER_BETA=true" `
    "--dart-define=READER_BETA_TEST_ACCOUNT=true" `
    "--dart-define=NOVEL_API_BASE_URL=$ApiBaseUrl" `
    "--dart-define=NOVEL_WS_BASE_URL=$WebSocketBaseUrl"
  if ($LASTEXITCODE -ne 0) {
    throw "Flutter beta build failed with exit code $LASTEXITCODE."
  }
} finally {
  Pop-Location
}

if (-not (Test-Path -LiteralPath $sourceApk)) {
  throw "Expected APK was not produced: $sourceApk"
}
if (-not (Test-Path -LiteralPath $verificationScript)) {
  throw "Beta APK verification script is missing: $verificationScript"
}

& $verificationScript `
  -ApkPath $sourceApk `
  -BetaNumber $BetaNumber `
  -ExpectedAbi 'arm64-v8a' `
  -MaximumApkBytes (220MB)
if ($LASTEXITCODE -ne 0) {
  throw "Beta APK metadata verification failed with exit code $LASTEXITCODE."
}
Copy-Item -LiteralPath $sourceApk -Destination $artifactPath -Force

$hash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
Set-Content -LiteralPath $checksumPath -Value "$hash  $artifactName" -Encoding ascii

Write-Output "Beta APK: $artifactPath"
Write-Output "SHA-256: $hash"
