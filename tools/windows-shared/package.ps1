<#
.SYNOPSIS
  Package the Windows *shared* PHP SDK (php8ts.dll + import lib + headers)
  and the Windows Xdebug catalog for one PHP release.

.DESCRIPTION
  The default Windows SDK (build.yml, platform windows-x86_64) is a static
  spc --build-embed: one fat php8embed.lib. A binary linked against it has no
  php8ts.dll, so it cannot load extension DLLs at all: php_xdebug.dll and
  every other PHP extension import their engine symbols from php8ts.dll.

  This script produces the shared alternative from the official
  windows.php.net build of the same PHP release (ZTS, x64, the VS toolset PHP
  ships that minor with). Nothing is compiled: the official release zip
  already contains a small static php8embed.lib (the embed SAPI, whose
  objects import the engine from php8ts.dll via php8ts.lib), and the matching
  devel pack carries php8ts.lib and the headers. Because the engine is the
  official one, the official extension DLLs (ext\php_*.dll) and the official
  Xdebug DLLs from xdebug.org are ABI-matched to it by construction.

  Outputs (in -OutDir):
    php-sdk-<ver>-windows-x86_64-shared.tar.gz
      include/php/...         headers (devel pack include/)
      lib/php8embed.lib       embed SAPI (static, imports php8ts.dll)
      lib/php8ts.lib          import library for php8ts.dll
      bin/php8ts.dll          the engine; ship next to the consuming .exe
      bin/*.dll               the engine's and extensions' dependency DLLs
      bin/ext/php_*.dll       the official shared extensions
      ephpm-sdk.json          manifest: ABI identity + the extension preload
                              list that restores the static SDK's set
      LICENSE-PHP.txt, readme-redist-bins.txt, sbom/
    ephpm-ext-<ver>-windows-x86_64.tar.gz
      php_xdebug.dll + manifest.json, same manifest schema as the Linux
      catalog (extensions.yml) plus "os"/"crt"; libc is "msvc".

  Every download is sha256-verified before use, against
  tools/windows-shared/checksums.txt first and the live
  windows.php.net/downloads/releases/sha256sum.txt second. A file found in
  neither is refused (the error prints the hash to pin).

  Before packaging, a smoke test runs the official php.exe from a directory
  that holds ONLY the packaged bin/ payload, loads the whole preload list
  plus Xdebug, and fails unless every extension of the static SDK's set is
  present and Xdebug registered as a Zend extension.

.PARAMETER PhpVersion
  Full PHP version, e.g. 8.5.7. Pre-releases are not published as Windows
  builds on windows.php.net and are refused.

.PARAMETER XdebugVersion
  Xdebug release to package (an official xdebug.org Windows DLL).

.PARAMETER OutDir
  Where the two tarballs are written.

.PARAMETER WorkDir
  Scratch directory (downloads + staging). Deleted and recreated.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$PhpVersion,
  [string]$XdebugVersion = '3.5.3',
  [string]$OutDir = (Join-Path (Get-Location) 'out'),
  [string]$WorkDir = (Join-Path (Get-Location) 'work-windows-shared')
)

$ErrorActionPreference = 'Stop'
# Native exit codes are checked explicitly ($LASTEXITCODE): the first URL a
# file is tried at is expected to 404 for archived releases. PowerShell 7.4+
# would otherwise turn that non-zero exit into a terminating error.
$PSNativeCommandUseErrorActionPreference = $false
Set-StrictMode -Version 3

# The static SDK's extension set (build.yml WIN_PHP_EXTENSIONS), in a load
# order that satisfies inter-extension dependencies (mbstring before exif,
# pdo/mysqlnd before pdo_mysql/mysqli, dom/xml before xsl). mbregex is part of
# mbstring. An entry that is compiled into php8ts.dll has no ext\php_<n>.dll
# and is simply skipped; the smoke test then proves it is present anyway.
$WantedExtensions = @(
  'bcmath', 'bz2', 'calendar', 'ctype', 'curl', 'dom', 'mbstring', 'exif',
  'fileinfo', 'filter', 'ftp', 'gd', 'gettext', 'hash', 'iconv', 'intl',
  'mysqlnd', 'mysqli', 'opcache', 'openssl', 'pcre', 'pdo', 'pdo_mysql',
  'pdo_sqlite', 'phar', 'session', 'simplexml', 'soap', 'sockets', 'sodium',
  'sqlite3', 'tokenizer', 'xml', 'xmlreader', 'xmlwriter', 'xsl', 'zip', 'zlib'
)
# Loaded with zend_extension= rather than extension= when shipped as a DLL
# (PHP 8.3/8.4; 8.5 compiles OPcache into php8ts.dll).
$ZendExtensions = @('opcache')
# Extension DLLs that are test fixtures, not features: never shipped.
$NeverShip = @('php_dl_test.dll', 'php_zend_test.dll')
# SAPI DLLs for other servers: not needed by an embedder.
$OtherSapis = @('php8apache2_4.dll', 'php8phpdbg.dll')

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ChecksumFile = Join-Path $ScriptDir 'checksums.txt'
$Curl = Join-Path $env:SystemRoot 'System32\curl.exe'
$Tar = Join-Path $env:SystemRoot 'System32\tar.exe'

function Fail([string]$msg) {
  Write-Host "::error::$msg"
  throw $msg
}

if ($PhpVersion -notmatch '^(\d+)\.(\d+)\.(\d+)$') {
  Fail "php version '$PhpVersion' must be a GA x.y.z version (windows.php.net publishes no pre-release builds)"
}
$Minor = "$($Matches[1]).$($Matches[2])"
# The VS toolset windows.php.net builds each minor with. An extension DLL must
# be built with the same one (the CRT/ABI is part of the module build id).
$Vs = switch ($Minor) {
  '8.3' { 'vs16' }
  default { 'vs17' }
}
$ZipName = "php-$PhpVersion-Win32-$Vs-x64.zip"
$DevelName = "php-devel-pack-$PhpVersion-Win32-$Vs-x64.zip"
$XdebugName = "php_xdebug-$XdebugVersion-$Minor-ts-$Vs-x86_64.dll"

if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
New-Item -ItemType Directory -Force -Path $WorkDir, $OutDir | Out-Null
$Dl = Join-Path $WorkDir 'dl'
New-Item -ItemType Directory -Force -Path $Dl | Out-Null

# ---------------------------------------------------------------------------
# Checksums
# ---------------------------------------------------------------------------
function Read-Checksums([string]$path) {
  $map = @{}
  if (-not (Test-Path $path)) { return $map }
  foreach ($line in Get-Content $path) {
    $line = $line.Trim()
    if ($line -eq '' -or $line.StartsWith('#')) { continue }
    if ($line -match '^([0-9a-fA-F]{64})\s+\*?(\S+)$') {
      $map[$Matches[2]] = $Matches[1].ToLowerInvariant()
    }
  }
  return $map
}

$Pinned = Read-Checksums $ChecksumFile
$LiveSums = Join-Path $Dl 'live-sha256sum.txt'
& $Curl -fsSL --retry 3 --retry-delay 5 --max-time 120 -o $LiveSums 'https://windows.php.net/downloads/releases/sha256sum.txt'
if ($LASTEXITCODE -ne 0) {
  Write-Host "::warning::could not fetch the live windows.php.net sha256sum.txt (curl exit $LASTEXITCODE); only pinned checksums are usable"
  $Live = @{}
} else {
  $Live = Read-Checksums $LiveSums
}

function Get-Verified([string]$name, [string[]]$urls) {
  $dest = Join-Path $Dl $name
  $ok = $false
  foreach ($url in $urls) {
    & $Curl -fsL --retry 3 --retry-delay 5 --max-time 900 -o $dest $url
    if ($LASTEXITCODE -eq 0) { $ok = $true; Write-Host "==> fetched $url"; break }
    Write-Host "    $url -> curl exit $LASTEXITCODE"
  }
  if (-not $ok) { Fail "could not download $name from any of: $($urls -join ', ')" }
  $actual = (Get-FileHash -Algorithm SHA256 $dest).Hash.ToLowerInvariant()
  $expected = $null
  $source = $null
  if ($Pinned.ContainsKey($name)) { $expected = $Pinned[$name]; $source = 'checksums.txt' }
  elseif ($Live.ContainsKey($name)) { $expected = $Live[$name]; $source = 'windows.php.net sha256sum.txt' }
  if (-not $expected) {
    Fail "no trusted sha256 for $name (not in tools/windows-shared/checksums.txt nor the live windows.php.net list). Downloaded hash: $actual - verify it out of band and pin it as: $actual *$name"
  }
  if ($actual -ne $expected) {
    Fail "sha256 mismatch for $name (expected $expected from $source, got $actual)"
  }
  Write-Host "==> sha256 OK for $name ($source)"
  return @{ Path = $dest; Sha256 = $actual }
}

$base = 'https://windows.php.net/downloads/releases'
$zip = Get-Verified $ZipName @("$base/$ZipName", "$base/archives/$ZipName")
$devel = Get-Verified $DevelName @("$base/$DevelName", "$base/archives/$DevelName")
$xdebug = Get-Verified $XdebugName @("https://xdebug.org/files/$XdebugName")

# ---------------------------------------------------------------------------
# Extract
# ---------------------------------------------------------------------------
$PhpDir = Join-Path $WorkDir 'php'
$DevelDir = Join-Path $WorkDir 'devel'
New-Item -ItemType Directory -Force -Path $PhpDir, $DevelDir | Out-Null
& $Tar -xf $zip.Path -C $PhpDir
if ($LASTEXITCODE -ne 0) { Fail "failed to extract $ZipName" }
& $Tar -xf $devel.Path -C $DevelDir
if ($LASTEXITCODE -ne 0) { Fail "failed to extract $DevelName" }
# The devel pack nests everything under php-<ver>-devel-<vs>-x64/.
$DevelRoot = Get-ChildItem -Directory $DevelDir | Select-Object -First 1
if (-not $DevelRoot -or -not (Test-Path (Join-Path $DevelRoot.FullName 'include\main\php.h'))) {
  Fail "unexpected devel pack layout: include\main\php.h not found under $DevelDir"
}
$DevelRoot = $DevelRoot.FullName

foreach ($required in @('php8ts.dll', 'php8embed.lib', 'php.exe', 'ext')) {
  if (-not (Test-Path (Join-Path $PhpDir $required))) { Fail "official zip has no $required" }
}
$ImportLib = Join-Path $DevelRoot 'lib\php8ts.lib'
if (-not (Test-Path $ImportLib)) { $ImportLib = Join-Path $PhpDir 'dev\php8ts.lib' }
if (-not (Test-Path $ImportLib)) { Fail 'php8ts.lib found in neither the devel pack nor the zip dev\ dir' }

# ---------------------------------------------------------------------------
# Identity guards
# ---------------------------------------------------------------------------
$VersionH = Join-Path $DevelRoot 'include\main\php_version.h'
$m = Select-String -Path $VersionH -Pattern '#define PHP_VERSION "([^"]+)"'
if (-not $m) { Fail "cannot read PHP_VERSION from $VersionH" }
$staged = $m.Matches[0].Groups[1].Value
if ($staged -ne $PhpVersion) { Fail "devel pack headers are PHP $staged, asked for $PhpVersion" }

$ModulesH = Join-Path $DevelRoot 'include\Zend\zend_modules.h'
$m = Select-String -Path $ModulesH -Pattern '#define ZEND_MODULE_API_NO (\d+)'
if (-not $m) { Fail "cannot read ZEND_MODULE_API_NO from $ModulesH" }
$ApiNo = $m.Matches[0].Groups[1].Value

# Windows passes ZTS as a compiler flag (/D ZTS=1), not via config.w32.h; the
# devel pack records the build's thread-safety mode for phpize here. The
# smoke test below re-checks it at runtime from `php -v`.
$PhpizeJs = Join-Path $DevelRoot 'script\phpize.js'
if (-not (Select-String -Path $PhpizeJs -Pattern '^var PHP_ZTS="Yes"' -Quiet)) {
  Fail "devel pack $PhpizeJs does not declare PHP_ZTS=Yes - not a thread-safe build"
}
Write-Host "==> PHP $staged, ZEND_MODULE_API_NO=$ApiNo, ZTS, $Vs"

# ---------------------------------------------------------------------------
# Stage the SDK
# ---------------------------------------------------------------------------
$Sdk = Join-Path $WorkDir 'sdk'
$SdkBin = Join-Path $Sdk 'bin'
$SdkExt = Join-Path $SdkBin 'ext'
New-Item -ItemType Directory -Force -Path (Join-Path $Sdk 'include'), (Join-Path $Sdk 'lib'), $SdkExt | Out-Null

Copy-Item -Recurse (Join-Path $DevelRoot 'include') (Join-Path $Sdk 'include\php')
Copy-Item (Join-Path $PhpDir 'php8embed.lib') (Join-Path $Sdk 'lib\')
Copy-Item $ImportLib (Join-Path $Sdk 'lib\')

# Runtime payload: every DLL at the zip root except other servers' SAPIs.
# These are php8ts.dll plus the third-party DLLs the engine and the shared
# extensions import (libcrypto, libssl, ICU, libsqlite3, nghttp2, ...); the
# Windows loader resolves them from the directory of the .exe.
Get-ChildItem -File (Join-Path $PhpDir '*.dll') |
  Where-Object { $OtherSapis -notcontains $_.Name } |
  ForEach-Object { Copy-Item $_.FullName $SdkBin }
Get-ChildItem -File (Join-Path $PhpDir 'ext\*.dll') |
  Where-Object { $NeverShip -notcontains $_.Name } |
  ForEach-Object { Copy-Item $_.FullName $SdkExt }
# php_enchant.dll loads its providers from lib\enchant\ next to the .exe.
if (Test-Path (Join-Path $PhpDir 'lib')) {
  Copy-Item -Recurse (Join-Path $PhpDir 'lib') (Join-Path $SdkBin 'lib')
}
Copy-Item (Join-Path $PhpDir 'license.txt') (Join-Path $Sdk 'LICENSE-PHP.txt')
foreach ($f in @('readme-redist-bins.txt', 'news.txt')) {
  if (Test-Path (Join-Path $PhpDir $f)) { Copy-Item (Join-Path $PhpDir $f) $Sdk }
}
if (Test-Path (Join-Path $PhpDir 'extras\sbom')) {
  Copy-Item -Recurse (Join-Path $PhpDir 'extras\sbom') (Join-Path $Sdk 'sbom')
}

# Preload list: the static SDK's set, minus what php8ts.dll compiles in.
$Preload = @()
foreach ($name in $WantedExtensions) {
  $file = "php_$name.dll"
  if (Test-Path (Join-Path $SdkExt $file)) {
    $Preload += [ordered]@{
      name           = $name
      file           = $file
      zend_extension = ($ZendExtensions -contains $name)
    }
  }
}
Write-Host "==> preload: $(($Preload | ForEach-Object { $_.name }) -join ', ')"

# ---------------------------------------------------------------------------
# Smoke test: official php.exe + ONLY the staged bin/ payload
# ---------------------------------------------------------------------------
$Smoke = Join-Path $WorkDir 'smoke'
Copy-Item -Recurse $SdkBin $Smoke
Copy-Item (Join-Path $PhpDir 'php.exe') $Smoke
Copy-Item $xdebug.Path (Join-Path $Smoke 'ext\php_xdebug.dll')
$SmokeExt = Join-Path $Smoke 'ext'

$phpArgs = @('-n', '-d', "extension_dir=$SmokeExt")
foreach ($p in $Preload) {
  $directive = if ($p.zend_extension) { 'zend_extension' } else { 'extension' }
  $phpArgs += @('-d', "$directive=$(Join-Path $SmokeExt $p.file)")
}
$phpArgs += @('-d', "zend_extension=$(Join-Path $SmokeExt 'php_xdebug.dll')")

$SmokeExe = Join-Path $Smoke 'php.exe'

# Run php.exe capturing stdout+stderr without PowerShell's native-stderr
# handling (Windows PowerShell 5.1 turns redirected stderr into terminating
# errors under ErrorActionPreference=Stop).
function Invoke-Php([string[]]$argv) {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $SmokeExe
  $psi.Arguments = ($argv | ForEach-Object { '"' + ($_ -replace '"', '\"') + '"' }) -join ' '
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = $Smoke
  $proc = [System.Diagnostics.Process]::Start($psi)
  $stdout = $proc.StandardOutput.ReadToEndAsync()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()
  return @{ Code = $proc.ExitCode; Output = ($stdout.Result + $stderr) }
}

# Any startup warning (an extension that failed to load) is displayed with
# display_startup_errors=1; capture everything and fail on it.
$r = Invoke-Php ($phpArgs + @('-d', 'display_startup_errors=1', '-m'))
$modules = $r.Output
if ($r.Code -ne 0) { Fail "php -m failed (exit $($r.Code)):`n$modules" }
if ($modules -match '(?i)(warning|unable to load|failed loading)') {
  Fail "an extension failed to load in the smoke test:`n$modules"
}
$loaded = @{}
foreach ($line in ($modules -split "`r?`n")) {
  $l = $line.Trim()
  if ($l -ne '' -and -not $l.StartsWith('[')) { $loaded[$l.ToLowerInvariant()] = $true }
}
$missing = @()
foreach ($name in $WantedExtensions) {
  $key = if ($name -eq 'opcache') { 'zend opcache' } else { $name }
  if (-not $loaded.ContainsKey($key)) { $missing += $name }
}
if ($missing.Count -gt 0) {
  Fail "the shared SDK cannot provide the static SDK's extension set; missing: $($missing -join ', ')`n$modules"
}
Write-Host "==> smoke: all $($WantedExtensions.Count) extensions of the static set present"

$r = Invoke-Php ($phpArgs + @('-v'))
$banner = $r.Output
if ($r.Code -ne 0) { Fail "php -v failed (exit $($r.Code)):`n$banner" }
if ($banner -notmatch [regex]::Escape("with Xdebug v$XdebugVersion")) {
  Fail "Xdebug $XdebugVersion did not register as a Zend extension:`n$banner"
}
if ($banner -notmatch '\(ZTS ') { Fail "php -v does not report a ZTS build:`n$banner" }
Write-Host "==> smoke: $(($banner -split "`r?`n")[0])"
Write-Host "==> smoke: Xdebug $XdebugVersion loads as a Zend extension"

# ---------------------------------------------------------------------------
# Manifests
# ---------------------------------------------------------------------------
$SdkManifest = [ordered]@{
  php_version = $PhpVersion
  php_api_no  = $ApiNo
  zts         = 1
  os          = 'windows'
  arch        = 'x86_64'
  crt         = $Vs
  linkage     = 'shared'
  runtime_dir = 'bin'
  source      = [ordered]@{
    zip       = [ordered]@{ file = $ZipName; sha256 = $zip.Sha256 }
    devel     = [ordered]@{ file = $DevelName; sha256 = $devel.Sha256 }
  }
  preload     = @($Preload)
}
$SdkManifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding ascii (Join-Path $Sdk 'ephpm-sdk.json')

$ExtOut = Join-Path $WorkDir 'ext-out'
New-Item -ItemType Directory -Force -Path $ExtOut | Out-Null
Copy-Item $xdebug.Path (Join-Path $ExtOut 'php_xdebug.dll')
# Redistributing the DLL means shipping its license text with it.
& $Curl -fsSL --retry 3 --retry-delay 5 --max-time 120 -o (Join-Path $ExtOut 'LICENSE-xdebug.txt') `
  "https://raw.githubusercontent.com/xdebug/xdebug/$XdebugVersion/LICENSE"
if ($LASTEXITCODE -ne 0) { Fail "could not fetch the Xdebug $XdebugVersion LICENSE (curl exit $LASTEXITCODE)" }
$ExtManifest = [ordered]@{
  php_version = $PhpVersion
  php_api_no  = $ApiNo
  zts         = 1
  libc        = 'msvc'
  os          = 'windows'
  arch        = 'x86_64'
  crt         = $Vs
  extensions  = @(
    [ordered]@{
      name           = 'xdebug'
      file           = 'php_xdebug.dll'
      version        = $XdebugVersion
      php_api_no     = $ApiNo
      zts            = 1
      zend_extension = $true
      sha256         = $xdebug.Sha256
      source         = "https://xdebug.org/files/$XdebugName"
    }
  )
}
$ExtManifest | ConvertTo-Json -Depth 6 | Set-Content -Encoding ascii (Join-Path $ExtOut 'manifest.json')

# ---------------------------------------------------------------------------
# Package
# ---------------------------------------------------------------------------
$SdkTar = Join-Path $OutDir "php-sdk-$PhpVersion-windows-x86_64-shared.tar.gz"
$ExtTar = Join-Path $OutDir "ephpm-ext-$PhpVersion-windows-x86_64.tar.gz"
& $Tar -czf $SdkTar -C $Sdk .
if ($LASTEXITCODE -ne 0) { Fail "failed to write $SdkTar" }
& $Tar -czf $ExtTar -C $ExtOut .
if ($LASTEXITCODE -ne 0) { Fail "failed to write $ExtTar" }
foreach ($t in @($SdkTar, $ExtTar)) {
  $h = (Get-FileHash -Algorithm SHA256 $t).Hash.ToLowerInvariant()
  Write-Host ("==> {0} ({1:N1} MB) sha256 {2}" -f (Split-Path -Leaf $t), ((Get-Item $t).Length / 1MB), $h)
}
