param(
    [string]$ApkPath = "build/release-archive/app-release-4.1.33+86.apk",
    [string]$ManifestPath = "build/release-archive/version.json",
    [string]$TokenPath = "build/release-archive/.upload-token",
    [string]$Endpoint = "https://49.232.137.85/novel-api",
    [int]$ChunkBytes = 3MB,
    [switch]$SkipCertificateCheck
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    $endpointUri = [Uri]$Endpoint
    if ($endpointUri.Scheme -ne "https" -or
        $endpointUri.Host -ne "49.232.137.85" -or
        $endpointUri.AbsolutePath.TrimEnd('/') -ne "/novel-api" -or
        $endpointUri.Query -or
        $endpointUri.Fragment) {
        throw "Endpoint must be exactly https://49.232.137.85/novel-api."
    }
    if ($ChunkBytes -lt 256KB -or $ChunkBytes -gt 3MB) {
        throw "ChunkBytes must be between 256 KiB and 3 MiB."
    }

    $resolvedApk = (Resolve-Path -LiteralPath $ApkPath).Path
    $resolvedManifest = (Resolve-Path -LiteralPath $ManifestPath).Path
    $resolvedToken = (Resolve-Path -LiteralPath $TokenPath).Path
    $manifest = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedManifest | ConvertFrom-Json
    if ($manifest.versionName -notmatch '^\d+\.\d+\.\d+$' -or
        [int]$manifest.versionCode -le 0 -or
        $manifest.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
        throw "Release manifest is invalid."
    }
    $expectedName = "app-release-$($manifest.versionName)+$($manifest.versionCode).apk"
    if ((Split-Path -Leaf $resolvedApk) -ne $expectedName) {
        throw "APK file name does not match the release manifest."
    }
    $actualSha256 = (Get-FileHash -LiteralPath $resolvedApk -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $manifest.sha256.ToLowerInvariant()) {
        throw "APK checksum does not match the release manifest."
    }
    $token = [IO.File]::ReadAllText($resolvedToken).Trim()
    if ([string]::IsNullOrWhiteSpace($token) -or $token.Length -gt 512) {
        throw "Release upload token is invalid."
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    if ($SkipCertificateCheck) {
        $handler.ServerCertificateCustomValidationCallback = {
            param($message, $certificate, $chain, $errors)
            return $true
        }
    }
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromMinutes(15)
    $client.DefaultRequestHeaders.ExpectContinue = $false
    $client.DefaultRequestHeaders.Authorization =
        [Net.Http.Headers.AuthenticationHeaderValue]::new("Release", $token)

    function Read-JsonResponse([Net.Http.HttpResponseMessage]$Response) {
        $body = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        if (-not $Response.IsSuccessStatusCode) {
            throw "Release server returned HTTP $([int]$Response.StatusCode): $body"
        }
        if ([string]::IsNullOrWhiteSpace($body)) { return $null }
        return $body | ConvertFrom-Json
    }

    $statusUri = "$($Endpoint.TrimEnd('/'))/internal/app-release/status"
    $status = Read-JsonResponse ($client.GetAsync($statusUri).GetAwaiter().GetResult())
    if ($status.consumed) {
        Write-Output "Release $($status.versionName)+$($status.versionCode) is already published."
        Remove-Item -LiteralPath $resolvedToken -Force
        return
    }

    $apk = Get-Item -LiteralPath $resolvedApk
    $partCount = [int][Math]::Ceiling($apk.Length / [double]$ChunkBytes)
    $received = [Collections.Generic.HashSet[int]]::new()
    foreach ($index in @($status.receivedPartIndexes)) {
        [void]$received.Add([int]$index)
    }
    $stream = [IO.File]::OpenRead($resolvedApk)
    try {
        for ($index = 0; $index -lt $partCount; $index += 1) {
            $offset = [int64]$index * $ChunkBytes
            $length = [int][Math]::Min($ChunkBytes, $apk.Length - $offset)
            if ($received.Contains($index)) {
                $stream.Seek($length, [IO.SeekOrigin]::Current) | Out-Null
                Write-Output "Part $($index + 1)/$partCount already uploaded."
                continue
            }
            $buffer = [byte[]]::new($length)
            $read = 0
            while ($read -lt $length) {
                $count = $stream.Read($buffer, $read, $length - $read)
                if ($count -le 0) { throw "Unexpected end of APK while reading part $index." }
                $read += $count
            }
            $partHasher = [Security.Cryptography.SHA256]::Create()
            try {
                $partSha256 = ($partHasher.ComputeHash($buffer) | ForEach-Object {
                    $_.ToString("x2")
                }) -join ''
            } finally {
                $partHasher.Dispose()
            }
            $multipart = [Net.Http.MultipartFormDataContent]::new()
            try {
                $content = [Net.Http.ByteArrayContent]::new($buffer)
                $content.Headers.ContentType =
                    [Net.Http.Headers.MediaTypeHeaderValue]::new("application/octet-stream")
                $multipart.Add($content, "apk", "part-$('{0:D4}' -f $index).bin")
                $request = [Net.Http.HttpRequestMessage]::new(
                    [Net.Http.HttpMethod]::Put,
                    "$($Endpoint.TrimEnd('/'))/internal/app-release/chunks/$index"
                )
                try {
                    $request.Headers.Add("X-Release-Part-Count", "$partCount")
                    $request.Headers.Add("X-Release-Part-Sha256", $partSha256)
                    $request.Content = $multipart
                    $response = $client.SendAsync($request).GetAwaiter().GetResult()
                    [void](Read-JsonResponse $response)
                } finally {
                    $request.Dispose()
                }
            } finally {
                $multipart.Dispose()
            }
            Write-Output "Uploaded part $($index + 1)/$partCount."
        }
    } finally {
        $stream.Dispose()
    }

    $finalizeRequest = [Net.Http.HttpRequestMessage]::new(
        [Net.Http.HttpMethod]::Post,
        "$($Endpoint.TrimEnd('/'))/internal/app-release/finalize"
    )
    try {
        $finalizeRequest.Content = [Net.Http.ByteArrayContent]::new([byte[]]::new(0))
        $published = Read-JsonResponse (
            $client.SendAsync($finalizeRequest).GetAwaiter().GetResult()
        )
    } finally {
        $finalizeRequest.Dispose()
    }
    if ($published.versionCode -ne [int]$manifest.versionCode -or
        $published.sha256 -ne $actualSha256) {
        throw "Release server returned an unexpected publication result."
    }
    Remove-Item -LiteralPath $resolvedToken -Force
    Write-Output "Published $($manifest.versionName)+$($manifest.versionCode)."
    Write-Output "SHA256: $actualSha256"
} finally {
    if ($null -ne $client) { $client.Dispose() }
    if ($null -ne $handler) { $handler.Dispose() }
    Pop-Location
}
