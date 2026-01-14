$ErrorActionPreference = 'Stop'

$buildName = $env:BUILD_NAME_INPUT
if ([string]::IsNullOrWhiteSpace($buildName)) {
  throw 'Missing build_name input.'
}

$buildNumber = $env:BUILD_NUMBER_INPUT
if ([string]::IsNullOrWhiteSpace($buildNumber)) {
  throw 'Missing build_number input.'
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
