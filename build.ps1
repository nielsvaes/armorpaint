<#
.SYNOPSIS
    Builds ArmorPaint on Windows and optionally launches it.

.DESCRIPTION
    Wraps the three steps the build needs on Windows:

      1. Generate the Visual Studio project, assets and shaders (base/tools/make.js).
      2. Invoke MSBuild on the generated project.
      3. Copy the executable next to build/out/data, where it expects to find it.

    This deliberately does not use "make --compile". That path invokes the
    generated build.bat by a bare name, which cmd fails to resolve, so it
    silently builds nothing and still exits 0. Here MSBuild is invoked directly
    and its exit code is checked.

.PARAMETER Config
    Release (default) or Debug.

.PARAMETER Run
    Launch the built executable, detached, from its output directory.

.PARAMETER Clean
    Delete paint/build before generating.

.PARAMETER SkipGenerate
    Reuse the existing generated project. Fast when only C sources changed; do
    not use after changing assets, shaders or project.js.

.PARAMETER Embed
    Pass --embed to the generator, baking assets into the executable.

.PARAMETER Verbosity
    MSBuild verbosity: quiet, minimal (default), normal, detailed, diagnostic.

.EXAMPLE
    .\build.ps1 -Run

.EXAMPLE
    .\build.ps1 -Config Debug -Clean
#>
[CmdletBinding()]
param(
    [ValidateSet('Release', 'Debug')]
    [string] $Config = 'Release',

    [ValidateSet('quiet', 'minimal', 'normal', 'detailed', 'diagnostic')]
    [string] $Verbosity = 'minimal',

    [switch] $Run,
    [switch] $Clean,
    [switch] $SkipGenerate,
    [switch] $Embed
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
$PaintDir = Join-Path $RepoRoot 'paint'
$BuildDir = Join-Path $PaintDir 'build'
$OutDir   = Join-Path $BuildDir 'out'
$Amake    = Join-Path $RepoRoot 'base\tools\bin\windows_x64\amake.exe'
$MakeJs   = Join-Path $RepoRoot 'base\tools\make.js'
$Vcxproj  = Join-Path $BuildDir 'ArmorPaint.vcxproj'
$ExeName  = 'ArmorPaint.exe'

function Write-Step([string] $Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Stop-WithError([string] $Message) {
    Write-Host ''
    Write-Host "ERROR: $Message" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------- preflight --

Write-Step 'Checking toolchain'

if (-not (Test-Path $Amake)) {
    Stop-WithError "amake.exe not found at $Amake. Is this an ArmorPaint checkout?"
}

$programFilesX86 = ${env:ProgramFiles(x86)}
$vswhere = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    Stop-WithError 'vswhere.exe not found. Install Visual Studio 2022 or the Build Tools.'
}

$vsPath = & $vswhere -products * -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    Stop-WithError 'No Visual Studio installation with the MSVC x64 toolset was found.'
}
$vsPath = $vsPath.Trim()

# make.js hardcodes PlatformToolset=ClangCL and passes clang-only warning flags,
# so MSVC cannot stand in for these two components.
$clangCl = Join-Path $vsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe'
$toolset = Join-Path $vsPath 'MSBuild\Microsoft\VC\v170\Platforms\x64\PlatformToolsets\ClangCL'

$missing = @()
if (-not (Test-Path $clangCl)) { $missing += 'Microsoft.VisualStudio.Component.VC.Llvm.Clang' }
if (-not (Test-Path $toolset)) { $missing += 'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset' }

if ($missing.Count -gt 0) {
    $setupExe = Join-Path $programFilesX86 'Microsoft Visual Studio\Installer\setup.exe'
    Write-Host ''
    Write-Host 'Missing required Visual Studio components:' -ForegroundColor Red
    foreach ($m in $missing) { Write-Host "  - $m" -ForegroundColor Red }
    Write-Host ''
    Write-Host 'Add them in the Visual Studio Installer (Modify > Individual components):' -ForegroundColor Yellow
    Write-Host '  "C++ Clang Compiler for Windows"' -ForegroundColor Yellow
    Write-Host '  "MSBuild support for LLVM (clang-cl) toolset"' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'Or from an elevated prompt:' -ForegroundColor Yellow
    $addFlags = ($missing | ForEach-Object { "--add $_" }) -join ' '
    Write-Host "  & '$setupExe' modify --installPath '$vsPath' $addFlags --passive --norestart" -ForegroundColor Yellow
    exit 1
}

$vcvars = Join-Path $vsPath 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path $vcvars)) {
    Stop-WithError "vcvars64.bat not found at $vcvars"
}

$clangVersion = (& $clangCl --version | Select-Object -First 1)
Write-Host "Visual Studio: $vsPath"
Write-Host "clang-cl:      $clangVersion"

$stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# ------------------------------------------------------------------- clean ---

if ($Clean -and (Test-Path $BuildDir)) {
    Write-Step 'Cleaning'
    Remove-Item -Recurse -Force $BuildDir
}

# ---------------------------------------------------------------- generate ---

if ($SkipGenerate) {
    if (-not (Test-Path $Vcxproj)) {
        Stop-WithError '-SkipGenerate was given but no generated project exists. Run without it first.'
    }
    Write-Step 'Skipping generation (reusing existing project)'
}
else {
    Write-Step 'Generating project, assets and shaders'

    $makeArgs = @($MakeJs)
    if ($Embed)              { $makeArgs += '--embed' }
    if ($Config -eq 'Debug') { $makeArgs += '--debug' }

    Push-Location $PaintDir
    try {
        & $Amake @makeArgs
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if ($code -ne 0) {
        Stop-WithError "Project generation failed (exit $code)."
    }
    if (-not (Test-Path $Vcxproj)) {
        Stop-WithError "Generation reported success but $Vcxproj is missing."
    }
}

# ------------------------------------------------------------------- build ---

Write-Step "Building ($Config, x64)"

# Record the current binary so a no-op build cannot masquerade as a fresh one.
$builtExe = Join-Path $BuildDir "x64\$Config\$ExeName"
if (Test-Path $builtExe) {
    $before = (Get-Item $builtExe).LastWriteTimeUtc
}
else {
    $before = [datetime]::MinValue
}

# vcvars has to run in the same cmd session as MSBuild, hence the wrapper.
$batPath = Join-Path $BuildDir '_msbuild.bat'
# Each concatenation needs its own parentheses: in an array literal the comma
# operator binds tighter than +, which would split these across elements.
$batLines = @(
    '@echo off',
    ('call "' + $vcvars + '" >nul'),
    'if errorlevel 1 exit /b 1',
    ('MSBuild.exe "' + $Vcxproj + '" /nologo /m /p:Configuration=' + $Config + ' /p:Platform=x64 /v:' + $Verbosity),
    'exit /b %ERRORLEVEL%'
)
Set-Content -Path $batPath -Value $batLines -Encoding ASCII

& cmd.exe /c $batPath
$code = $LASTEXITCODE
Remove-Item -Force $batPath -ErrorAction SilentlyContinue

if ($code -ne 0) {
    Stop-WithError "MSBuild failed (exit $code)."
}
if (-not (Test-Path $builtExe)) {
    Stop-WithError "MSBuild reported success but $builtExe was not produced."
}

if ((Get-Item $builtExe).LastWriteTimeUtc -eq $before) {
    Write-Host 'Nothing to rebuild; binary is already up to date.' -ForegroundColor DarkGray
}

# -------------------------------------------------------------------- copy ---

Write-Step 'Staging executable'

# The app resolves data/ relative to its working directory, so it must sit in out/.
if (-not (Test-Path $OutDir)) {
    Stop-WithError "$OutDir does not exist. Run without -SkipGenerate to export the assets."
}

$stagedPath = Join-Path $OutDir $ExeName
Copy-Item -Force $builtExe $stagedPath

$stopwatch.Stop()
$staged = Get-Item $stagedPath

Write-Host ''
Write-Host 'Build succeeded.' -ForegroundColor Green
Write-Host ("  Executable: " + $staged.FullName)
Write-Host ("  Size:       {0:N1} MB" -f ($staged.Length / 1MB))
Write-Host ("  Elapsed:    {0:mm\:ss}" -f $stopwatch.Elapsed)

# --------------------------------------------------------------------- run ---

if ($Run) {
    Write-Step 'Launching ArmorPaint'
    # Must be detached: started as a child of a shell job it segfaults after ~60s.
    $proc = Start-Process -FilePath $staged.FullName -WorkingDirectory $OutDir -PassThru
    Write-Host "Started (PID $($proc.Id))."
}
