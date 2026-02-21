param(
  [string]$BuildName,
  [string]$BuildNumber,
  [string]$ProxyUrl = $env:DANDANPLAY_PROXY_URL,
  [string]$TargetPlatforms = 'android-arm,android-arm64',
  [string]$OutDir = 'build/local-android-apks',
  [switch]$SplitPerAbi,
  [switch]$SkipPubGet
)

$ErrorActionPreference = 'Stop'

function Get-VersionFromPubspec {
  if (-not (Test-Path 'pubspec.yaml')) { return $null }
  $versionLine = Get-Content 'pubspec.yaml' | Where-Object { $_ -match '^\s*version:\s*' } | Select-Object -First 1
  if (-not $versionLine) { return $null }
  return ($versionLine -replace '^\s*version:\s*', '').Trim()
}

function Resolve-BuildVersion {
  $raw = Get-VersionFromPubspec
  $resolvedName = $BuildName
  $resolvedNumber = $BuildNumber

  if ([string]::IsNullOrWhiteSpace($resolvedName) -and -not [string]::IsNullOrWhiteSpace($raw)) {
    $resolvedName = ($raw -split '\+')[0]
  }
  if ([string]::IsNullOrWhiteSpace($resolvedName)) {
    $resolvedName = '1.0.0'
  }

  if ([string]::IsNullOrWhiteSpace($resolvedNumber) -and -not [string]::IsNullOrWhiteSpace($raw) -and ($raw -match '\+')) {
    $resolvedNumber = ($raw -split '\+')[-1]
  }
  if ([string]::IsNullOrWhiteSpace($resolvedNumber)) {
    $resolvedNumber = '1'
  }
  if ($resolvedNumber -notmatch '^[0-9]+$') {
    throw "BuildNumber must be an integer. Current value: $resolvedNumber"
  }

  return @{
    Name = $resolvedName
    Number = $resolvedNumber
    Full = "$resolvedName+$resolvedNumber"
  }
}

Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$version = Resolve-BuildVersion
Write-Host "Using build version: $($version.Full)"

if (-not $SkipPubGet) {
  flutter pub get | Out-Host
}

$buildArgs = @(
  'build', 'apk', '--release',
  '--build-name', $version.Name,
  '--build-number', $version.Number,
  '--target-platform', $TargetPlatforms,
  '--dart-define=LINPLAYER_FORCE_TV=true'
)
if ($SplitPerAbi) {
  $buildArgs += '--split-per-abi'
}
if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
  $buildArgs += "--dart-define=LINPLAYER_DANDANPLAY_PROXY_URL=$ProxyUrl"
}

& flutter @buildArgs
if ($LASTEXITCODE -ne 0) {
  throw "flutter build apk failed with exit code $LASTEXITCODE"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Copy-IfExists([string]$Src, [string]$Dst) {
  if (-not (Test-Path $Src)) { return $false }
  Copy-Item -Path $Src -Destination $Dst -Force
  return $true
}

if ($SplitPerAbi) {
  $copied = $false
  $copied = (Copy-IfExists 'build/app/outputs/flutter-apk/app-arm64-v8a-release.apk' (Join-Path $OutDir 'LinPlayer-Android-TV-arm64-v8a.apk')) -or $copied
  $copied = (Copy-IfExists 'build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk' (Join-Path $OutDir 'LinPlayer-Android-TV-armeabi-v7a.apk')) -or $copied
  $copied = (Copy-IfExists 'build/app/outputs/flutter-apk/app-x86_64-release.apk' (Join-Path $OutDir 'LinPlayer-Android-TV-x86_64.apk')) -or $copied
  if (-not $copied) {
    throw "No split APKs found under build/app/outputs/flutter-apk/."
  }
} else {
  $src = 'build/app/outputs/flutter-apk/app-release.apk'
  $dst = Join-Path $OutDir 'LinPlayer-Android-TV.apk'
  if (-not (Test-Path $src)) {
    throw "APK output missing: $src"
  }
  Copy-Item -Path $src -Destination $dst -Force
}

$outPath = (Resolve-Path $OutDir).Path
Write-Host ""
Write-Host "Output folder: $outPath"

