$ErrorActionPreference = 'Stop'

$configPath = Join-Path $PSScriptRoot 'emulator_window_config.json'
$config = [pscustomobject]@{
  avdName = 'Pixel_10_Pro'
  deviceSerial = 'emulator-5554'
  scale = 0.6
  window = [pscustomobject]@{
    x = 80
    y = 40
    width = 430
    height = 760
  }
  waitForBoot = $true
}

if (Test-Path $configPath) {
  $fileConfig = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
  if ($fileConfig.avdName) { $config.avdName = [string]$fileConfig.avdName }
  if ($fileConfig.deviceSerial) { $config.deviceSerial = [string]$fileConfig.deviceSerial }
  if ($null -ne $fileConfig.scale) { $config.scale = [double]$fileConfig.scale }
  if ($fileConfig.window) {
    if ($null -ne $fileConfig.window.x) { $config.window.x = [int]$fileConfig.window.x }
    if ($null -ne $fileConfig.window.y) { $config.window.y = [int]$fileConfig.window.y }
    if ($null -ne $fileConfig.window.width) { $config.window.width = [int]$fileConfig.window.width }
    if ($null -ne $fileConfig.window.height) { $config.window.height = [int]$fileConfig.window.height }
  }
  if ($null -ne $fileConfig.waitForBoot) { $config.waitForBoot = [bool]$fileConfig.waitForBoot }
}

$avdName = $config.avdName
$deviceSerial = $config.deviceSerial
$scale = ([string]$config.scale)
$targetX = $config.window.x
$targetY = $config.window.y
$targetWidth = $config.window.width
$targetHeight = $config.window.height

function Find-AndroidSdk {
  $candidates = @(
    $env:ANDROID_HOME,
    $env:ANDROID_SDK_ROOT,
    'G:\Android\Sdk',
    "$env:LOCALAPPDATA\Android\Sdk"
  ) | Where-Object { $_ -and (Test-Path $_) }

  foreach ($candidate in $candidates) {
    $emulator = Join-Path $candidate 'emulator\emulator.exe'
    $adb = Join-Path $candidate 'platform-tools\adb.exe'
    if ((Test-Path $emulator) -and (Test-Path $adb)) {
      return @{
        Root = $candidate
        Emulator = $emulator
        Adb = $adb
      }
    }
  }

  throw 'Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT.'
}

if (-not ('EmulatorWindowTools' -as [type])) {
  Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class EmulatorWindowTools {
  [DllImport("user32.dll")]
  public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

  [DllImport("user32.dll")]
  public static extern bool MoveWindow(IntPtr hWnd, int X, int Y, int nWidth, int nHeight, bool bRepaint);
}
'@
}

function Get-EmulatorWindow {
  Get-Process |
    Where-Object { $_.MainWindowTitle -like "Android Emulator - $avdName*" -and $_.MainWindowHandle -ne 0 } |
    Select-Object -First 1
}

function Resize-EmulatorWindow {
  $window = $null
  for ($i = 0; $i -lt 60; $i += 1) {
    $window = Get-EmulatorWindow
    if ($window) { break }
    Start-Sleep -Milliseconds 500
  }

  if (-not $window) { return }

  $handle = [IntPtr]$window.MainWindowHandle
  [EmulatorWindowTools]::ShowWindowAsync($handle, 9) | Out-Null
  Start-Sleep -Milliseconds 250

  for ($i = 0; $i -lt 3; $i += 1) {
    [EmulatorWindowTools]::MoveWindow($handle, $targetX, $targetY, $targetWidth, $targetHeight, $true) | Out-Null
    Start-Sleep -Milliseconds 250
  }
}

$sdk = Find-AndroidSdk
$window = Get-EmulatorWindow

if (-not $window) {
  Start-Process -FilePath $sdk.Emulator -ArgumentList @('-avd', $avdName, '-scale', $scale) | Out-Null
}

Resize-EmulatorWindow

if ($config.waitForBoot) {
  try {
    & $sdk.Adb wait-for-device
    for ($i = 0; $i -lt 90; $i += 1) {
      $bootRaw = & $sdk.Adb -s $deviceSerial shell getprop sys.boot_completed 2>$null
      $booted = if ($null -eq $bootRaw) { '' } else { ([string]$bootRaw).Trim() }
      if ($booted -eq '1') { break }
      Start-Sleep -Seconds 2
    }
  } catch {
    # The window resize is the important part; do not keep the launcher open on ADB hiccups.
  }
}

Resize-EmulatorWindow
