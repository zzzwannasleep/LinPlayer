param(
  [string]$BuildName,
  [string]$BuildNumber,
  [string]$ProxyUrl = $env:DANDANPLAY_PROXY_URL,
  [switch]$SkipBuild,
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
    AppVersion = "$resolvedName.$resolvedNumber"
  }
}

function Resolve-ReleaseDir {
  $release64 = 'build/windows/x64/runner/Release'
  $releaseLegacy = 'build/windows/runner/Release'
  if (Test-Path $release64) { return (Resolve-Path $release64).Path }
  if (Test-Path $releaseLegacy) { return (Resolve-Path $releaseLegacy).Path }
  throw 'Release folder not found. Please build Windows release first.'
}

function Copy-MsvcRuntimeDlls {
  param([string]$ReleaseDir)

  $roots = @(
    'C:\Program Files\Microsoft Visual Studio\2022',
    'C:\Program Files (x86)\Microsoft Visual Studio\2022'
  )

  $crtDir = $null
  foreach ($root in $roots) {
    foreach ($edition in @('Enterprise', 'Professional', 'Community', 'BuildTools')) {
      $search = Join-Path $root "$edition\VC\Redist\MSVC"
      if (-not (Test-Path $search)) { continue }

      $allV143 = Get-ChildItem -Directory -Recurse -Filter 'Microsoft.VC143.CRT' $search -ErrorAction SilentlyContinue
      $allV142 = Get-ChildItem -Directory -Recurse -Filter 'Microsoft.VC142.CRT' $search -ErrorAction SilentlyContinue
      $all = @($allV143 + $allV142)
      if (-not $all -or $all.Count -eq 0) { continue }

      $x64Preferred = $all | Where-Object { $_.FullName -match '(\\|/)x64(\\|/)' } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
      $found = if ($x64Preferred) { $x64Preferred } else { $all | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }

      if ($found) {
        $crtDir = $found.FullName
        break
      }
    }
    if ($crtDir) { break }
  }

  if (-not $crtDir) {
    Write-Warning 'MSVC CRT directory not found. Installer may rely on target machine runtime.'
    return
  }

  Copy-Item -Path (Join-Path $crtDir '*') -Destination $ReleaseDir -Recurse -Force
  Write-Host "Copied MSVC runtime DLLs from: $crtDir"
}

function Resolve-IsccPath {
  $candidates = @(
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:ProgramFiles 'Inno Setup 6\ISCC.exe'),
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
  )

  foreach ($candidate in $candidates) {
    if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path $candidate)) {
      return $candidate
    }
  }

  $regRoots = @(
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
  )
  foreach ($root in $regRoots) {
    if (-not (Test-Path $root)) { continue }
    foreach ($entry in Get-ChildItem $root -ErrorAction SilentlyContinue) {
      try {
        $props = Get-ItemProperty $entry.PSPath -ErrorAction Stop
        if ($props.DisplayName -notlike '*Inno Setup*') { continue }
        $installLocation = $props.InstallLocation
        if ([string]::IsNullOrWhiteSpace($installLocation)) { continue }
        $fromReg = Join-Path $installLocation 'ISCC.exe'
        if (Test-Path $fromReg) {
          return $fromReg
        }
      } catch {
        continue
      }
    }
  }

  $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Path $cmd.Source)) {
    return $cmd.Source
  }

  throw @"
ISCC.exe not found. Install Inno Setup first, then rerun:
  choco install innosetup -y
or
  winget install JRSoftware.InnoSetup
"@
}

Set-Location (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$version = Resolve-BuildVersion
Write-Host "Using build version: $($version.Full)"

flutter config --enable-windows-desktop | Out-Host

if (-not $SkipPubGet) {
  flutter pub get | Out-Host
}

if (-not $SkipBuild) {
  $buildArgs = @(
    'build', 'windows', '--release',
    '--build-name', $version.Name,
    '--build-number', $version.Number
  )
  if (-not [string]::IsNullOrWhiteSpace($ProxyUrl)) {
    $buildArgs += "--dart-define=LINPLAYER_DANDANPLAY_PROXY_URL=$ProxyUrl"
  }

  & flutter @buildArgs
  if ($LASTEXITCODE -ne 0) {
    throw "flutter build windows failed with exit code $LASTEXITCODE"
  }
}

$releaseDir = Resolve-ReleaseDir
Copy-MsvcRuntimeDlls -ReleaseDir $releaseDir

$env:SOURCE_DIR = $releaseDir
$env:OUTPUT_DIR = (Resolve-Path '.').Path
$env:APP_ARCH = 'x64'
$env:APP_VERSION = $version.AppVersion
$env:APP_VERSION_FULL = $version.Full

$iscc = Resolve-IsccPath
& $iscc '.github/installer/windows/linplayer.iss'
if ($LASTEXITCODE -ne 0) {
  throw "ISCC failed with exit code $LASTEXITCODE"
}

$setup = 'LinPlayer-Setup-x64.exe'
$renamed = 'LinPlayer-Windows-Setup-x64.exe'
if (Test-Path $setup) {
  Rename-Item -Path $setup -NewName $renamed -Force
}
if (-not (Test-Path $renamed)) {
  throw "Installer output missing: $renamed"
}

$installerPath = (Resolve-Path $renamed).Path
Write-Host ''
Write-Host "Installer generated: $installerPath"
