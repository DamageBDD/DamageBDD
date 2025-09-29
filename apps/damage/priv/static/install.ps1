# Requires: PowerShell 5+ on Windows x64. Run as Administrator.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# --- URLs ---
$ErlangUrl   = 'https://github.com/erlang/otp/releases/download/OTP-28.1/otp_win64_28.1.exe'
$DamageZip   = 'https://github.com/DamageBDD/DamageBDD/archive/refs/heads/develop.zip'
$Rebar3Url   = 'https://s3.amazonaws.com/rebar3/rebar3'

# --- Working paths ---
$Tmp      = Join-Path $env:TEMP ("damagebdd-setup-" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $Tmp -Force
$ErlangExe = Join-Path $Tmp 'otp_win64_28.1.exe'
$ZipFile   = Join-Path $Tmp 'DamageBDD-develop.zip'

# Project will be placed next to where you run the script
$ProjectParent = (Get-Location).Path
$ProjectDir    = Join-Path $ProjectParent 'DamageBDD'

Write-Host "Downloading Erlang/OTP 28.1 installer..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $ErlangUrl -OutFile $ErlangExe

Write-Host "Installing Erlang/OTP 28.1 (silent)..." -ForegroundColor Cyan
# Inno Setup silent flags
$args = '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-'
$proc = Start-Process -FilePath $ErlangExe -ArgumentList $args -Wait -PassThru
if ($proc.ExitCode -ne 0) {
    throw "Erlang installer exited with code $($proc.ExitCode)"
}

# Try to locate escript.exe (so we can run rebar3)
Write-Host "Locating escript.exe..." -ForegroundColor Cyan
$Escript = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'escript.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Escript) {
    throw "Couldn't find escript.exe after install. Ensure Erlang installed correctly."
}
$ErlangBin = $Escript.Directory.FullName
$env:PATH = "$ErlangBin;$env:PATH"
Write-Host "Using Erlang bin at: $ErlangBin"

# Fetch DamageBDD develop.zip
Write-Host "Downloading DamageBDD (develop)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $DamageZip -OutFile $ZipFile

# Extract & normalize folder name to 'DamageBDD'
Write-Host "Extracting DamageBDD..." -ForegroundColor Cyan
$ExtractDir = Join-Path $Tmp 'extract'
$null = New-Item -ItemType Directory -Path $ExtractDir -Force
Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force

$UnzippedRoot = Get-ChildItem -Path $ExtractDir | Where-Object { $_.PSIsContainer } | Select-Object -First 1
if (-not $UnzippedRoot) { throw "Zip extraction did not produce a folder as expected." }

if (Test-Path $ProjectDir) {
    Write-Host "Removing existing '$ProjectDir'..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $ProjectDir
}
Rename-Item -Path $UnzippedRoot.FullName -NewName (Split-Path $ProjectDir -Leaf)
Move-Item -Path (Join-Path $ExtractDir (Split-Path $ProjectDir -Leaf)) -Destination $ProjectParent

# Download rebar3 into project root
Write-Host "Fetching rebar3..." -ForegroundColor Cyan
$Rebar3Path = Join-Path $ProjectDir 'rebar3'
Invoke-WebRequest -Uri $Rebar3Url -OutFile $Rebar3Path
# Unblock and ensure it's executable (Windows will run via escript)
Unblock-File -Path $Rebar3Path

# Make sure rebar3 runs using escript explicitly (avoids PATHEXT quirks)
$RebarCmd = "escript `"$Rebar3Path`""

# Compile
Write-Host "Running 'rebar3 compile'..." -ForegroundColor Cyan
Push-Location $ProjectDir
try {
    # First run can self-bootstraps; use escript to be explicit
    & $Escript.FullName $Rebar3Path localversion | Out-Null  # warms cache, not required
    & $Escript.FullName $Rebar3Path compile
}
finally {
    Pop-Location
}

Write-Host "`n✅ Done! DamageBDD set up at: $ProjectDir" -ForegroundColor Green
Write-Host "You can re-run builds with:  `n  cd `"$ProjectDir`" `n  escript .\rebar3 compile"
