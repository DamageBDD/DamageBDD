# Install-DamageBDD.ps1
# One-click installer for Erlang, DamageBDD (develop), and rebar3, then compile.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ensure-Admin {
  $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    Write-Host "Elevating to Administrator..." -ForegroundColor Yellow
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb = 'runas'
    try { [Diagnostics.Process]::Start($psi) | Out-Null } catch { throw "Elevation cancelled." }
    exit
  }
}
Ensure-Admin

$ErlangUrl = 'https://github.com/erlang/otp/releases/download/OTP-28.1/otp_win64_28.1.exe'
$DamageZip = 'https://github.com/DamageBDD/DamageBDD/archive/refs/heads/develop.zip'
$Rebar3Url = 'https://s3.amazonaws.com/rebar3/rebar3'

$Tmp = Join-Path $env:TEMP ("damagebdd-setup-" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $Tmp -Force
$ErlangExe = Join-Path $Tmp 'otp_win64_28.1.exe'
$ZipFile   = Join-Path $Tmp 'DamageBDD-develop.zip'
$ExtractDir = Join-Path $Tmp 'extract'
$null = New-Item -ItemType Directory -Path $ExtractDir -Force

# Install to the folder alongside this script
$ProjectParent = Split-Path -Parent $PSCommandPath
$ProjectDir    = Join-Path $ProjectParent 'DamageBDD'

Write-Host "Downloading Erlang/OTP 28.1 installer..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $ErlangUrl -OutFile $ErlangExe

Write-Host "Installing Erlang/OTP 28.1 (silent)..." -ForegroundColor Cyan
$args = '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-'
$proc = Start-Process -FilePath $ErlangExe -ArgumentList $args -Wait -PassThru
if ($proc.ExitCode -ne 0) { throw "Erlang installer exited with code $($proc.ExitCode)" }

Write-Host "Locating escript.exe..." -ForegroundColor Cyan
$Escript = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'escript.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $Escript) { throw "Couldn't find escript.exe after install." }
$ErlangBin = $Escript.Directory.FullName
$env:PATH = "$ErlangBin;$env:PATH"
Write-Host "Using Erlang bin at: $ErlangBin"

Write-Host "Downloading DamageBDD (develop)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $DamageZip -OutFile $ZipFile

Write-Host "Extracting DamageBDD..." -ForegroundColor Cyan
Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force
$UnzippedRoot = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
if (-not $UnzippedRoot) { throw "Zip extraction did not produce a folder as expected." }

if (Test-Path $ProjectDir) {
  Write-Host "Removing existing '$ProjectDir'..." -ForegroundColor Yellow
  Remove-Item -Recurse -Force $ProjectDir
}
Move-Item -Path $UnzippedRoot.FullName -Destination $ProjectDir

Write-Host "Fetching rebar3..." -ForegroundColor Cyan
$Rebar3Path = Join-Path $ProjectDir 'rebar3'
Invoke-WebRequest -Uri $Rebar3Url -OutFile $Rebar3Path
Unblock-File -Path $Rebar3Path

Write-Host "Compiling DamageBDD with rebar3..." -ForegroundColor Cyan
Push-Location $ProjectDir
try {
  & $Escript.FullName $Rebar3Path version | Out-Null
  & $Escript.FullName $Rebar3Path compile
} finally {
  Pop-Location
}

Write-Host "`n✅ Done! DamageBDD set up at: $ProjectDir" -ForegroundColor Green
Write-Host "Next time:  cd `"$ProjectDir`"  then  escript .\rebar3 compile"
