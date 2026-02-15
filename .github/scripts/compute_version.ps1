$ErrorActionPreference = 'Stop'

$buildName = $env:BUILD_NAME_INPUT
$buildNumber = $env:BUILD_NUMBER_INPUT

$rawVersion = ''
if (Test-Path 'pubspec.yaml') {
  $versionLine = Get-Content 'pubspec.yaml' | Where-Object { $_ -match '^\s*version:\s*' } | Select-Object -First 1
  if ($versionLine) {
    $rawVersion = ($versionLine -replace '^\s*version:\s*', '').Trim()
  }
}

if ([string]::IsNullOrWhiteSpace($buildName) -and -not [string]::IsNullOrWhiteSpace($rawVersion)) {
  $buildName = ($rawVersion -split '\+')[0]
}
if ([string]::IsNullOrWhiteSpace($buildName)) {
  $buildName = '0.1.0'
}

if ([string]::IsNullOrWhiteSpace($buildNumber) -and -not [string]::IsNullOrWhiteSpace($rawVersion) -and ($rawVersion -match '\+')) {
  $buildNumber = ($rawVersion -split '\+')[-1]
}
if ([string]::IsNullOrWhiteSpace($buildNumber)) {
  $buildNumber = $env:GITHUB_RUN_NUMBER
}
if ([string]::IsNullOrWhiteSpace($buildNumber)) {
  $buildNumber = '1'
}
if ($buildNumber -notmatch '^[0-9]+$') {
  throw "build_number must be an integer (got: $buildNumber)"
}

$versionFull = "$buildName+$buildNumber"
$appVersion = "$buildName.$buildNumber"

Write-Host "Using version: $versionFull"

Add-Content -Path $env:GITHUB_ENV -Value "BUILD_NAME=$buildName"
Add-Content -Path $env:GITHUB_ENV -Value "BUILD_NUMBER=$buildNumber"
Add-Content -Path $env:GITHUB_ENV -Value "VERSION_FULL=$versionFull"
Add-Content -Path $env:GITHUB_ENV -Value "APP_VERSION=$appVersion"
Add-Content -Path $env:GITHUB_ENV -Value "APP_VERSION_FULL=$versionFull"
