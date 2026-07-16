param(
  [Parameter(Mandatory = $true)]
  [string]$ApkPath,
  [Parameter(Mandatory = $true)]
  [ValidateRange(1, 999999)]
  [int]$BetaNumber,
  [string]$ExpectedAbi = 'arm64-v8a',
  [long]$MaximumApkBytes = 230686720
)

$ErrorActionPreference = 'Stop'

function Get-AndroidSdkDirectory {
  param([string]$RepoRoot)

  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_SDK_ROOT)) {
    $candidates += $env:ANDROID_SDK_ROOT
  }
  if (-not [string]::IsNullOrWhiteSpace($env:ANDROID_HOME)) {
    $candidates += $env:ANDROID_HOME
  }

  $localProperties = Join-Path $RepoRoot 'android\local.properties'
  if (Test-Path -LiteralPath $localProperties) {
    $sdkProperty = Get-Content -LiteralPath $localProperties |
      Where-Object { $_ -match '^sdk\.dir=' } |
      Select-Object -First 1
    if ($null -ne $sdkProperty) {
      $configuredPath = ($sdkProperty -replace '^sdk\.dir=', '').Trim()
      if (-not [string]::IsNullOrWhiteSpace($configuredPath)) {
        $candidates += $configuredPath.Replace('\\', '\')
      }
    }
  }

  foreach ($candidate in $candidates) {
    if (Test-Path -LiteralPath $candidate -PathType Container) {
      return (Resolve-Path -LiteralPath $candidate).Path
    }
  }

  throw 'Android SDK was not found. Set ANDROID_SDK_ROOT or configure android/local.properties.'
}

function Get-AndroidTool {
  param(
    [string]$SdkDirectory,
    [string]$PreferredRelativePath,
    [string]$FileName
  )

  $preferredPath = Join-Path $SdkDirectory $PreferredRelativePath
  if (Test-Path -LiteralPath $preferredPath -PathType Leaf) {
    return $preferredPath
  }

  $tool = Get-ChildItem -LiteralPath $SdkDirectory -Recurse -File -Filter $FileName |
    Sort-Object FullName -Descending |
    Select-Object -First 1
  if ($null -eq $tool) {
    throw "Android SDK tool was not found: $FileName"
  }
  return $tool.FullName
}

function Invoke-AndroidTool {
  param(
    [string]$ToolPath,
    [string[]]$Arguments
  )

  $output = & $ToolPath @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "Android SDK tool failed ($LASTEXITCODE): $ToolPath $($Arguments -join ' ')"
  }
  return @($output)
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$resolvedApkPath = (Resolve-Path -LiteralPath $ApkPath).Path
$apkLength = (Get-Item -LiteralPath $resolvedApkPath).Length
if ($MaximumApkBytes -le 0) {
  throw 'MaximumApkBytes must be greater than zero.'
}
if ($apkLength -gt $MaximumApkBytes) {
  throw "Beta APK is too large: $apkLength bytes (limit: $MaximumApkBytes bytes)."
}
$pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
$versionLine = Get-Content -LiteralPath $pubspecPath |
  Where-Object { $_ -match '^version:\s*' } |
  Select-Object -First 1
if ($null -eq $versionLine) {
  throw "Unable to read the base version from $pubspecPath"
}
$versionMatch = [regex]::Match(
  $versionLine,
  '^version:\s*([^\s+]+)\+([0-9]+)\s*$'
)
if (-not $versionMatch.Success) {
  throw "The pubspec version must use the '<name>+<code>' format: $versionLine"
}

$expectedApplicationId = 'com.novel.novel_app.beta'
$expectedVersionName = "$($versionMatch.Groups[1].Value)-beta.$BetaNumber"
$baseVersionCode = [int]$versionMatch.Groups[2].Value
$abiVersionCodeOffsets = @{
  'armeabi-v7a' = 1000
  'arm64-v8a' = 2000
  'x86_64' = 4000
}
if (-not $abiVersionCodeOffsets.ContainsKey($ExpectedAbi)) {
  throw "No Flutter split APK version-code offset is configured for ABI '$ExpectedAbi'."
}
$expectedVersionCode = ($baseVersionCode + $abiVersionCodeOffsets[$ExpectedAbi]).ToString()
$expectedLabel = 'Sakura ' + [char]0x6D4B + [char]0x8BD5 + [char]0x7248
$sdkDirectory = Get-AndroidSdkDirectory -RepoRoot $repoRoot
$apkAnalyzer = Get-AndroidTool `
  -SdkDirectory $sdkDirectory `
  -PreferredRelativePath 'cmdline-tools\latest\bin\apkanalyzer.bat' `
  -FileName 'apkanalyzer.bat'
$aapt = Get-AndroidTool `
  -SdkDirectory $sdkDirectory `
  -PreferredRelativePath 'build-tools\36.0.0\aapt.exe' `
  -FileName 'aapt.exe'

$applicationId = (Invoke-AndroidTool $apkAnalyzer @(
    'manifest', 'application-id', $resolvedApkPath
  ) | Out-String).Trim()
$versionName = (Invoke-AndroidTool $apkAnalyzer @(
    'manifest', 'version-name', $resolvedApkPath
  ) | Out-String).Trim()
$versionCode = (Invoke-AndroidTool $apkAnalyzer @(
    'manifest', 'version-code', $resolvedApkPath
  ) | Out-String).Trim()
$debuggable = (Invoke-AndroidTool $apkAnalyzer @(
    'manifest', 'debuggable', $resolvedApkPath
  ) | Out-String).Trim()
$badging = Invoke-AndroidTool $aapt @('dump', 'badging', $resolvedApkPath)
$manifest = (Invoke-AndroidTool $apkAnalyzer @(
    'manifest', 'print', $resolvedApkPath
  ) | Out-String)
$defaultLabelLine = $badging |
  Where-Object { $_ -match "^application-label:'(.*)'$" } |
  Select-Object -First 1
$applicationLabel = if ($null -ne $defaultLabelLine -and
    $defaultLabelLine -match "^application-label:'(.*)'$") {
  $Matches[1]
} else {
  ''
}
$nativeCodeLine = $badging |
  Where-Object { $_ -match '^native-code:\s*' } |
  Select-Object -First 1
$nativeCodes = @(
  if ($null -ne $nativeCodeLine) {
    [regex]::Matches($nativeCodeLine, "'([^']+)'") |
      ForEach-Object { $_.Groups[1].Value }
  }
)

if ($applicationId -ne $expectedApplicationId) {
  throw "Unexpected application ID. Expected '$expectedApplicationId', got '$applicationId'."
}
if ($versionName -ne $expectedVersionName) {
  throw "Unexpected version name. Expected '$expectedVersionName', got '$versionName'."
}
if ($versionCode -ne $expectedVersionCode) {
  throw "Unexpected version code. Expected '$expectedVersionCode', got '$versionCode'."
}
if ($debuggable -ne 'true') {
  throw "Beta APK must be debuggable, got '$debuggable'."
}
if ($applicationLabel -ne $expectedLabel) {
  throw "Unexpected application label. Expected '$expectedLabel', got '$applicationLabel'."
}
if ($nativeCodes.Count -ne 1 -or $nativeCodes[0] -ne $ExpectedAbi) {
  throw "Unexpected native ABIs. Expected only '$ExpectedAbi', got '$($nativeCodes -join ', ')'."
}
if ($manifest.Contains('android.permission.REQUEST_INSTALL_PACKAGES')) {
  throw 'Reader beta APK must not request permission to install APK updates.'
}
if ($manifest.Contains('android:sharedUserId=')) {
  throw 'Reader beta APK must not share an Android UID with another package.'
}
if (-not $manifest.Contains('android:allowBackup="false"')) {
  throw 'Reader beta APK must keep Android backup/restore disabled for data isolation.'
}
$expectedProviderAuthority = "$expectedApplicationId.fileprovider"
if (-not $manifest.Contains(
    "android:authorities=`"$expectedProviderAuthority`""
  )) {
  throw "Reader beta FileProvider authority is not isolated: $expectedProviderAuthority"
}

Write-Output "Application ID: $applicationId"
Write-Output "Application label: $applicationLabel"
Write-Output "Version name: $versionName"
Write-Output "Version code: $versionCode"
Write-Output "Debuggable: $debuggable"
Write-Output "Native ABI: $($nativeCodes[0])"
Write-Output "APK size: $apkLength bytes"
Write-Output "Update install permission: absent"
Write-Output "Shared Android UID: absent"
Write-Output "Android backup/restore: disabled"
Write-Output "FileProvider authority: $expectedProviderAuthority"
