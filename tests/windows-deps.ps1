# Exercises the actual bootstrap with Git and Node removed from this process's PATH.
# Downloads are verified and cached in .toolchain; no system installations are changed.
$ErrorActionPreference = 'Stop'
$originalPath = $env:PATH
$userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
$machinePath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
. (Join-Path $PSScriptRoot '..\scripts\windows.ps1')
$downloadFunction = (Get-Item Function:\Get-Download).ScriptBlock

function Assert-True {
    param([bool] $Condition, [string] $Message)
    if (!$Condition) { throw $Message }
    Write-Host "PASS  $Message"
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $minimalPath = "$env:SystemRoot\System32;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
    $env:PATH = $minimalPath
    Assert-True (!(Test-NodeRuntime) -and !(Test-GitRuntime)) 'the bootstrap starts without Node.js or Git on PATH'
    Install-Prerequisites -IncludeNpm
    Assert-True (Test-NodeRuntime) 'a working Node.js runtime is installed'
    Assert-True (Test-GitRuntime) 'a working Git runtime is installed'
    Assert-True ((Get-Command node.exe).Source.StartsWith($Toolchain, [StringComparison]::OrdinalIgnoreCase)) 'Node.js is installed inside the project'
    Assert-True ((Get-Command git.exe).Source.StartsWith($Toolchain, [StringComparison]::OrdinalIgnoreCase)) 'Git is installed inside the project'
    Invoke-Checked 'npm.cmd' @('--version')
    # Exercise Git beyond --version: MinGit must also be able to read our repository.
    Invoke-Checked 'git.exe' @('-C', $ProjectRoot, 'rev-parse', '--show-toplevel')

    function Get-Download { throw 'A cached or already available dependency should not need a download.' }
    $availablePath = $env:PATH
    Install-Prerequisites -IncludeNpm
    Assert-True ($env:PATH -eq $availablePath) 'usable dependencies are reused without changing PATH or downloading'
    $env:PATH = $minimalPath
    Install-Prerequisites -IncludeNpm
    Assert-True ((Test-NodeRuntime) -and (Test-GitRuntime)) 'a new launch reuses local dependencies offline'
    Assert-True ([Environment]::GetEnvironmentVariable('PATH', 'User') -eq $userPath) 'the user PATH is unchanged'
    Assert-True ([Environment]::GetEnvironmentVariable('PATH', 'Machine') -eq $machinePath) 'the system PATH is unchanged'
    Write-Host 'All Windows dependency checks passed.'
} finally {
    $env:PATH = $originalPath
    Set-Item Function:\Get-Download $downloadFunction
}
