# win/build.ps1 — Build the Howl Windows app end-to-end.
#
# Usage:
#   .\win\build.ps1                      # Release build
#   .\win\build.ps1 -Configuration Debug # Debug build
#   .\win\build.ps1 -SkipGo              # Skip Go DLL build (use existing win\bin\)
#
# Prerequisites:
#   - Go 1.22+ in PATH
#   - MSYS2 UCRT64 at C:\msys64 with gcc + cmake installed
#   - whisper.cpp built to C:\dev\whisper-dist (or set $WhisperDist)
#   - .NET 8 SDK in PATH

param(
    [string] $Configuration = "Release",
    [string] $MsysRoot      = "C:\msys64",
    [string] $WhisperDist   = "C:\dev\whisper-dist",
    [switch] $SkipGo
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path $PSScriptRoot -Parent

function Step([string]$name) { Write-Host "`n==> $name" -ForegroundColor Cyan }
function Ok([string]$msg)    { Write-Host "    $msg" -ForegroundColor Green }
function Die([string]$msg)   { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ── Step 1: Build libhowl.dll ─────────────────────────────────────────────

if (-not $SkipGo) {
    Step "Building libhowl.dll (Go + whisper.cpp)"

    $gccPath = "$MsysRoot\ucrt64\bin\gcc.exe"
    if (-not (Test-Path $gccPath)) { Die "gcc not found at $gccPath — install MSYS2 UCRT64 toolchain" }
    if (-not (Test-Path "$WhisperDist\include\whisper.h")) { Die "whisper.h not found in $WhisperDist\include" }

    $env:GOOS        = "windows"
    $env:GOARCH      = "amd64"
    $env:CGO_ENABLED = "1"
    $env:CC          = $gccPath
    $env:CGO_CFLAGS  = "-I$WhisperDist\include"
    $env:CGO_LDFLAGS = "-L$WhisperDist\lib -lwhisper -lggml -lggml-base"

    $outDll = "$Root\win\bin\libhowl.dll"
    Push-Location "$Root\core\cmd\libhowl"
    try {
        & go build -buildmode=c-shared -tags=whispercpp -o $outDll .
        if ($LASTEXITCODE -ne 0) { Die "go build failed" }
    } finally { Pop-Location }
    Ok "libhowl.dll → $outDll"

    # Copy whisper runtime DLLs
    Step "Copying whisper runtime DLLs"
    $dlls = @("libwhisper.dll","ggml.dll","ggml-base.dll","ggml-cpu.dll")
    foreach ($dll in $dlls) {
        $src = "$WhisperDist\bin\$dll"
        if (Test-Path $src) { Copy-Item $src "$Root\win\bin\" -Force; Ok $dll }
        else { Write-Host "    WARNING: $dll not found in $WhisperDist\bin" -ForegroundColor Yellow }
    }

    # Copy MinGW runtime DLLs
    $mingwDlls = @("libgcc_s_seh-1.dll","libstdc++-6.dll","libwinpthread-1.dll","libgomp-1.dll")
    foreach ($dll in $mingwDlls) {
        $src = "$MsysRoot\ucrt64\bin\$dll"
        if (Test-Path $src) { Copy-Item $src "$Root\win\bin\" -Force; Ok $dll }
    }
}

# ── Step 2: Restore + Build WPF ──────────────────────────────────────────

Step "Restoring NuGet packages"
& dotnet restore "$Root\win\Howl\Howl.csproj"
if ($LASTEXITCODE -ne 0) { Die "dotnet restore failed" }

Step "Building WPF app ($Configuration)"
& dotnet build "$Root\win\Howl\Howl.csproj" -c $Configuration --no-restore
if ($LASTEXITCODE -ne 0) { Die "dotnet build failed" }

# ── Step 3: Publish (Release only) ───────────────────────────────────────

if ($Configuration -eq "Release") {
    Step "Publishing self-contained package"
    $outDir = "$Root\win\out"
    & dotnet publish "$Root\win\Howl\Howl.csproj" -c Release -r win-x64 `
        --self-contained false -o $outDir --no-restore
    if ($LASTEXITCODE -ne 0) { Die "dotnet publish failed" }
    Ok "Published to $outDir"

    Step "Creating zip artifact"
    $zip = "$Root\win\Howl-windows.zip"
    Compress-Archive -Path "$outDir\*" -DestinationPath $zip -Force
    Ok "Artifact: $zip"
}

Write-Host "`n✓ Build complete ($Configuration)" -ForegroundColor Green
