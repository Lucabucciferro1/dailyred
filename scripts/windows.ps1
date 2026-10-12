# Native Windows entry point. PowerShell 5.1+; missing dependencies install locally.
# MSYS2 supplies Windows build tools; no WSL, administrator rights or global installs.
[CmdletBinding()]
param(
    [ValidateSet('setup', 'build', 'clean', 'start', 'save-patch', 'test')]
    [string] $Command = 'start',
    [ValidateRange(1, 65535)] [int] $Port = 8080,
    [ValidateRange(1, 64)] [int] $Jobs = [Math]::Min(8, [Environment]::ProcessorCount),
    [switch] $NoBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ProjectRoot = Split-Path -Parent $PSScriptRoot
$Toolchain = Join-Path $ProjectRoot '.toolchain'
$Downloads = Join-Path $Toolchain 'downloads'
$Game = Join-Path $ProjectRoot 'pokefirered'
$PretCommit = '037335f4c725d7c9aecdac87066f2002b4bd7e14'
$GccVersion = '14.2.1-1.1'
$MsysVersion = '20260927'
$ToolsVersion = "msys2-$MsysVersion-gcc-$GccVersion-ucrt64-v1"
$NodeVersion = '24.21.0'
$GitVersion = '2.56.0.2'

function Invoke-Checked {
    param([string] $File, [string[]] $Arguments)
    & $File @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$File exited with code $LASTEXITCODE." }
}

function Get-Download {
    param([string] $Url, [string] $Name, [string] $Sha256)
    $destination = Join-Path $Downloads $Name
    if ((Test-Path -LiteralPath $destination) -and
        (!$Sha256 -or (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $Sha256)) {
        return $destination
    }
    Write-Host ">> Downloading $Name"
    $partial = "$destination.partial"
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $partial
            if ($Sha256 -and (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) {
                throw "Checksum mismatch for $Name."
            }
            Move-Item -LiteralPath $partial -Destination $destination -Force
            return $destination
        } catch {
            if ($attempt -eq 3) { throw }
            Write-Warning "Download failed; retrying ($attempt/3)."
        }
    }
}

function Test-NodeRuntime {
    param([string] $File = 'node.exe')
    try {
        $executable = Get-Command $File -CommandType Application -ErrorAction Stop
        $version = & $executable.Source -p 'process.versions.node' 2>$null
        return $LASTEXITCODE -eq 0 -and $version -match '^\d+\.\d+\.\d+$' -and [version]$version -ge [version]'18.0.0'
    } catch { return $false }
}

function Test-GitRuntime {
    param([string] $File = 'git.exe')
    try {
        $executable = Get-Command $File -CommandType Application -ErrorAction Stop
        $version = & $executable.Source --version 2>$null
        return $LASTEXITCODE -eq 0 -and $version -match '^git version 2\.'
    } catch { return $false }
}

function Install-Prerequisites {
    param([switch] $IncludeNpm)
    New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
    if (!(Test-NodeRuntime) -or ($IncludeNpm -and !(Get-Command npm.cmd -CommandType Application -ErrorAction SilentlyContinue))) {
        $directory = Join-Path $Toolchain "node-v$NodeVersion-win-x64"
        $marker = Join-Path $directory '.installed'
        if (!(Test-Path -LiteralPath $marker) -or !(Test-NodeRuntime (Join-Path $directory 'node.exe')) -or
            !(Test-Path -LiteralPath (Join-Path $directory 'npm.cmd'))) {
            $archive = "node-v$NodeVersion-win-x64.zip"
            $zip = Get-Download "https://nodejs.org/dist/v$NodeVersion/$archive" $archive `
                '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541'
            Write-Host ">> Installing portable Node.js $NodeVersion (includes npm)"
            # Expand-Archive is built into PowerShell; bootstrap needs no external tools.
            Expand-Archive -LiteralPath $zip -DestinationPath $Toolchain -Force
            if (!(Test-NodeRuntime (Join-Path $directory 'node.exe')) -or
                !(Test-Path -LiteralPath (Join-Path $directory 'npm.cmd'))) { throw 'The downloaded Node.js runtime could not start.' }
            [IO.File]::WriteAllText($marker, $NodeVersion)
        }
        $env:PATH = "$directory;$env:PATH"
    }
    if (!(Test-GitRuntime)) {
        $directory = Join-Path $Toolchain "mingit-$GitVersion"
        $marker = Join-Path $directory '.installed'
        if (!(Test-Path -LiteralPath $marker) -or !(Test-GitRuntime (Join-Path $directory 'cmd\git.exe'))) {
            $archive = "MinGit-$GitVersion-64-bit.zip"
            $zip = Get-Download "https://github.com/git-for-windows/git/releases/download/v2.56.0.windows.2/$archive" $archive `
                'da35e72aa21c005a5a0d298cfbae110bc1609a815730ea0dde84b01a1b3cd3be'
            Write-Host ">> Installing portable Git $GitVersion"
            Expand-Archive -LiteralPath $zip -DestinationPath $directory -Force
            if (!(Test-GitRuntime (Join-Path $directory 'cmd\git.exe'))) { throw 'The downloaded Git runtime could not start.' }
            [IO.File]::WriteAllText($marker, $GitVersion)
        }
        $env:PATH = "$(Join-Path $directory 'cmd');$env:PATH"
    }
}

function Invoke-Msys {
    param([string] $Action, [string] $Root = $ProjectRoot)
    $variables = @('MSYSTEM', 'MSYS2_PATH_TYPE', 'CHERE_INVOKING', 'DAILYRED_ROOT', 'DAILYRED_JOBS')
    $previous = @{}
    foreach ($name in $variables) { $previous[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
    try {
        $env:MSYSTEM = 'UCRT64'
        $env:MSYS2_PATH_TYPE = 'strict'
        $env:CHERE_INVOKING = '1'
        $env:DAILYRED_ROOT = $Root
        $env:DAILYRED_JOBS = "$Jobs"
        $bash = Join-Path $Root '.toolchain\msys64\usr\bin\bash.exe'
        $helper = (Join-Path $Root 'scripts\windows-build.sh').Replace('\', '/')
        Invoke-Checked $bash @('--login', $helper, $Action)
    } finally {
        foreach ($name in $variables) { [Environment]::SetEnvironmentVariable($name, $previous[$name], 'Process') }
    }
}

function Install-Toolchain {
    $gcc = Join-Path $Toolchain 'arm-none-eabi\bin\arm-none-eabi-gcc.exe'
    if (!(Test-Path -LiteralPath $gcc)) {
        $archive = "xpack-arm-none-eabi-gcc-$GccVersion-win32-x64.zip"
        $zip = Get-Download "https://github.com/xpack-dev-tools/arm-none-eabi-gcc-xpack/releases/download/v$GccVersion/$archive" $archive `
            '0b2d496b383ba578182eb57b3f7d35ff510e36eda56257883b902fa07c3bba55'
        Write-Host '>> Extracting the ARM compiler'
        Invoke-Checked 'tar.exe' @('-xf', $zip, '-C', $Toolchain)
        $extracted = Join-Path $Toolchain "xpack-arm-none-eabi-gcc-$GccVersion"
        $target = Join-Path $Toolchain 'arm-none-eabi'
        if (Test-Path -LiteralPath $target) { throw "Incomplete toolchain at $target. Rename it and run setup again." }
        # Both paths are fixed children of this project's .toolchain directory.
        Move-Item -LiteralPath $extracted -Destination $target
    }
    Invoke-Checked $gcc @('--version')

    $bash = Join-Path $Toolchain 'msys64\usr\bin\bash.exe'
    if (!(Test-Path -LiteralPath $bash)) {
        $archive = "msys2-base-x86_64-$MsysVersion.sfx.exe"
        $sfx = Get-Download "https://github.com/msys2/msys2-installer/releases/download/2026-09-27/$archive" $archive `
            'ad336cccfda47758b5e15cda993fbba421115cb0b126697daef1ee4dfe37209f'
        Write-Host '>> Extracting the local MSYS2 build tools'
        Invoke-Checked $sfx @('-y', "-o$Toolchain")
    }
    $marker = Join-Path $Toolchain 'windows-tools.version'
    $ready = (Test-Path -LiteralPath $marker) -and ((Get-Content -LiteralPath $marker -Raw).Trim() -eq $ToolsVersion)
    foreach ($tool in @('usr\bin\make.exe', 'ucrt64\bin\gcc.exe', 'ucrt64\bin\g++.exe', 'ucrt64\bin\pkg-config.exe', 'ucrt64\lib\libpng.dll.a')) {
        $ready = $ready -and (Test-Path -LiteralPath (Join-Path $Toolchain "msys64\$tool"))
    }
    if (!$ready) {
        # Core MSYS2 updates require a fresh Bash process before installing packages.
        try {
            Invoke-Msys 'update'
        } catch {
            # A runtime upgrade can terminate its own shell with a nonzero exit.
            # Retry in a new process; a persistent package/network error still fails.
            Write-Warning 'Restarting MSYS2 to finish the update.'
            Invoke-Msys 'update'
        }
        Invoke-Msys 'packages'
        [IO.File]::WriteAllText($marker, $ToolsVersion)
    }
}

function Get-Game {
    if (!(Test-Path -LiteralPath (Join-Path $Game '.git'))) {
        if ((Test-Path -LiteralPath $Game) -and @(Get-ChildItem -LiteralPath $Game -Force).Count -gt 0) {
            throw 'pokefirered already contains files. Move it aside before running setup.'
        }
        Invoke-Checked 'git' @('init', '-q', $Game)
        Invoke-Checked 'git' @('-C', $Game, 'remote', 'add', 'origin', 'https://github.com/pret/pokefirered.git')
    }
    # This is repository-local: never change the user's global Git preferences.
    Invoke-Checked 'git' @('-C', $Game, 'config', 'core.autocrlf', 'false')
    $head = & git -C $Game rev-parse --verify --quiet HEAD
    if ($LASTEXITCODE -ne 0) {
        Invoke-Checked 'git' @('-C', $Game, 'fetch', '--depth', '1', 'origin', $PretCommit)
        Invoke-Checked 'git' @('-C', $Game, 'checkout', '--detach', 'FETCH_HEAD')
    } elseif ($head -ne $PretCommit) {
        throw "pokefirered is not at the supported commit $PretCommit. Existing work has been preserved."
    }
    if (Test-Path -LiteralPath (Join-Path $Game 'src\dailyred.c')) {
        Write-Host '>> Keeping the existing patched pokefirered checkout'
        return
    }
    $patch = Join-Path $ProjectRoot 'patches\pokefirered-dailyred.patch'
    Invoke-Checked 'git' @('-C', $Game, 'apply', '--check', '--whitespace=nowarn', $patch)
    Invoke-Checked 'git' @('-C', $Game, 'apply', '--whitespace=nowarn', $patch)
}

function Get-Vendor {
    $vendor = Join-Path $ProjectRoot 'web\vendor'
    New-Item -ItemType Directory -Force -Path $vendor | Out-Null
    $nostalgist = Get-Download 'https://registry.npmjs.org/nostalgist/-/nostalgist-0.22.0.tgz' 'nostalgist-0.22.0.tgz' `
        'e0bb4a7c0adefd4399034c4931dcc13720ff87aaedd6e1f20d88db3564da5876'
    Invoke-Checked 'tar.exe' @('-xf', $nostalgist, '-C', $Downloads, 'package/dist/nostalgist.js', 'package/license')
    Copy-Item -LiteralPath (Join-Path $Downloads 'package\dist\nostalgist.js') -Destination (Join-Path $vendor 'nostalgist.js')
    Copy-Item -LiteralPath (Join-Path $Downloads 'package\license') -Destination (Join-Path $vendor 'nostalgist.LICENSE.txt')
    $core = Get-Download 'https://cdn.jsdelivr.net/gh/arianrhodsandlot/retroarch-emscripten-build@v1.22.2/retroarch/mgba_libretro.zip' 'mgba-v1.22.2.zip' `
        'd195371c3ea626c9246e9d3ab82ded4d93f3f99f85634af1588724cc44d47644'
    Invoke-Checked 'tar.exe' @('-xf', $core, '-C', $vendor)
    $font = Get-Download 'https://fonts.gstatic.com/s/pixelifysans/v3/CHylV-3HFUT7aC4iv1TxGDR9Jn0Ei0tSaJ0.woff2' 'pixelify-sans.woff2' `
        '0f2216c1b7bf13b775e7b825c15e1c8414f3899cbd4120f275cdc96001a053a0'
    Copy-Item -LiteralPath $font -Destination (Join-Path $vendor 'pixelify-sans.woff2')
    $license = Get-Download 'https://raw.githubusercontent.com/google/fonts/main/ofl/pixelifysans/OFL.txt' 'pixelify-sans.OFL.txt' ''
    Copy-Item -LiteralPath $license -Destination (Join-Path $vendor 'pixelify-sans.OFL.txt')
}

function Build-Game {
    param([string] $Action = 'build')
    if (!(Test-Path -LiteralPath (Join-Path $Toolchain 'windows-tools.version')) -or
        !(Test-Path -LiteralPath (Join-Path $Game 'src\dailyred.c'))) {
        throw 'Build prerequisites are missing. Run: powershell -ExecutionPolicy Bypass -File scripts\windows.ps1 setup'
    }
    Invoke-Msys $Action
    if ($Action -eq 'clean') { return }
    $rom = Join-Path $Game 'pokefirered_modern.gba'
    $output = Join-Path $ProjectRoot 'web\game'
    New-Item -ItemType Directory -Force -Path $output | Out-Null
    $compressed = Join-Path $output 'dailyred.gba.gz'
    $inputStream = [IO.File]::OpenRead($rom)
    try {
        $outputStream = [IO.File]::Create("$compressed.partial")
        try {
            $gzip = New-Object IO.Compression.GZipStream($outputStream, [IO.Compression.CompressionLevel]::Optimal, $true)
            try { $inputStream.CopyTo($gzip) } finally { $gzip.Dispose() }
        } finally { $outputStream.Dispose() }
    } finally { $inputStream.Dispose() }
    Move-Item -LiteralPath "$compressed.partial" -Destination $compressed -Force
    Copy-Item -LiteralPath (Join-Path $Game 'graphics\trainers\front_pics\red_front_pic.png') -Destination (Join-Path $output 'red.png')
    Write-Host ">> Built $compressed"
}

function Initialize-Game {
    param([switch] $ForTests)
    $files = @('web\game\dailyred.gba.gz', 'web\game\red.png', 'web\vendor\nostalgist.js',
        'web\vendor\mgba_libretro.js', 'web\vendor\mgba_libretro.wasm', 'web\vendor\pixelify-sans.woff2')
    if ($ForTests) { $files += @('pokefirered\src\dailyred.c', 'pokefirered\pokefirered_modern.elf', 'pokefirered\pokefirered_modern.gba', '.toolchain\arm-none-eabi\bin\arm-none-eabi-nm.exe') }
    $missing = @($files | Where-Object { !(Test-Path -LiteralPath (Join-Path $ProjectRoot $_)) })
    if ($missing.Count -gt 0) {
        Install-Toolchain
        Get-Game
        Get-Vendor
        Build-Game
    }
}

function Start-Game {
    Initialize-Game
    Write-Host ">> Starting Daily Red at http://localhost:$Port (Ctrl+C to stop)"
    $serverArgs = @((Join-Path $PSScriptRoot 'serve.mjs'), "$Port")
    if (!$NoBrowser) { $serverArgs += '--open' }
    Invoke-Checked 'node' $serverArgs
}

# Allow the bootstrap regression test to load the real helpers without starting a game.
if ($MyInvocation.InvocationName -eq '.') { return }

try {
    if ($env:OS -ne 'Windows_NT' -or ![Environment]::Is64BitOperatingSystem) {
        throw 'This script requires 64-bit Windows 10 or Windows 11.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-Prerequisites -IncludeNpm:($Command -eq 'test')
    switch ($Command) {
        'setup' { Install-Toolchain; Get-Game; Get-Vendor; Write-Host 'Setup complete. Run play.cmd to build and play.' }
        'build' { Build-Game }
        'clean' { Build-Game 'clean' }
        'start' { Start-Game }
        'test' {
            Initialize-Game -ForTests
            # Keep npm's cache in the project too; no persistent PATH changes are needed.
            Invoke-Checked 'npm.cmd' @('ci', '--prefix', (Join-Path $ProjectRoot 'tests'), '--cache', (Join-Path $Toolchain 'npm-cache'))
            Invoke-Checked 'npm.cmd' @('test', '--prefix', (Join-Path $ProjectRoot 'tests'))
        }
        'save-patch' {
            if (!(Test-Path -LiteralPath (Join-Path $Game 'src\dailyred.c'))) { throw 'Run setup before saving a patch.' }
            Invoke-Checked 'git' @('-C', $Game, 'add', '--intent-to-add', '.')
            $patch = Join-Path $ProjectRoot 'patches\pokefirered-dailyred.patch'
            # Git writes the bytes itself: PowerShell 5.1 redirection would use UTF-16.
            Invoke-Checked 'git' @('-C', $Game, 'diff', '--binary', "--output=$patch.partial", 'HEAD')
            Move-Item -LiteralPath "$patch.partial" -Destination $patch -Force
            Write-Host ">> Saved $patch"
        }
    }
} catch {
    Write-Host "Daily Red: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
