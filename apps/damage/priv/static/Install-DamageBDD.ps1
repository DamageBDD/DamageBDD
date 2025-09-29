# Install-DamageBDD.ps1 (v2)
# Streamlined one-click: install Erlang (if needed), fetch DamageBDD, prompt for port & password,
# generate config/sys.config, initialize encrypted key store, build release.

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ensure-Admin {
  $me = [Security.Principal.WindowsIdentity]::GetCurrent()
  $pri = New-Object Security.Principal.WindowsPrincipal($me)
  if (-not $pri.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $psi.Verb      = 'runas'
    try { [Diagnostics.Process]::Start($psi) | Out-Null } catch { throw "Elevation cancelled." }
    exit
  }
}
Ensure-Admin

# --- Constants/URLs ---
$ErlangUrl = 'https://github.com/erlang/otp/releases/download/OTP-28.1/otp_win64_28.1.exe'
$DamageZip = 'https://github.com/DamageBDD/DamageBDD/archive/refs/heads/develop.zip'
$Rebar3Url = 'https://s3.amazonaws.com/rebar3/rebar3'

# --- Helpers ---
function Find-Exe([string]$name){ Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Is-PortUsed([int]$Port){
  try {
    $c = Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop
    return $null -ne $c
  } catch { return $false }
}
function Find-FreePort([int]$Start=8080){
  $p = [Math]::Max(1,$Start)
  while(Is-PortUsed $p){ $p++ }
  return $p
}
function Confirm([string]$msg, [bool]$default=$true){
  $d = $default ? 'Y/n' : 'y/N'
  $r = Read-Host "$msg [$d]"
  if([string]::IsNullOrWhiteSpace($r)){ return $default }
  return @('y','yes','true','1') -contains $r.ToLower()
}

# --- Working folders ---
$Tmp  = Join-Path $env:TEMP ("damagebdd-setup-" + [guid]::NewGuid())
$null = New-Item -ItemType Directory -Path $Tmp -Force
$ErlangExe  = Join-Path $Tmp 'otp_win64_28.1.exe'
$ZipFile    = Join-Path $Tmp 'DamageBDD-develop.zip'
$ExtractDir = Join-Path $Tmp 'extract'; New-Item -ItemType Directory $ExtractDir -Force | Out-Null

# Install beside this script
$ProjectParent = Split-Path -Parent $PSCommandPath
$ProjectDir    = Join-Path $ProjectParent 'DamageBDD'
$ConfigDir     = Join-Path $ProjectDir 'config'
$null = New-Item -ItemType Directory -Path $ConfigDir -Force

Write-Host "==> Checking Erlang/OTP..." -ForegroundColor Cyan
$Escript = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'escript.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
if(-not $Escript){
  Write-Host "Downloading Erlang/OTP 28.1..." -ForegroundColor Cyan
  Invoke-WebRequest -Uri $ErlangUrl -OutFile $ErlangExe
  Write-Host "Installing Erlang/OTP 28.1 (silent)..." -ForegroundColor Cyan
  $args = '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-'
  $proc = Start-Process -FilePath $ErlangExe -ArgumentList $args -Wait -PassThru
  if ($proc.ExitCode -ne 0) { throw "Erlang installer exited with code $($proc.ExitCode)" }
  $Escript = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'escript.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
}
if(-not $Escript){ throw "Couldn't find escript.exe after install." }
$ErlangBin = $Escript.Directory.FullName
$ErlExe    = Join-Path (Split-Path $ErlangBin -Parent) 'erl.exe'
$env:PATH = "$ErlangBin;$env:PATH"
Write-Host "Erlang bin: $ErlangBin"

# Fetch app + rebar3
Write-Host "==> Fetching DamageBDD (develop)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $DamageZip -OutFile $ZipFile
Expand-Archive -Path $ZipFile -DestinationPath $ExtractDir -Force
$UnzippedRoot = Get-ChildItem -Path $ExtractDir -Directory | Select-Object -First 1
if(Test-Path $ProjectDir){ Remove-Item -Recurse -Force $ProjectDir }
Move-Item -Path $UnzippedRoot.FullName -Destination $ProjectDir

Write-Host "==> Fetching rebar3..." -ForegroundColor Cyan
$Rebar3Path = Join-Path $ProjectDir 'rebar3'
Invoke-WebRequest -Uri $Rebar3Url -OutFile $Rebar3Path
Unblock-File $Rebar3Path

# --- Prompt port (auto-find free if taken) ---
$defaultPort = 8080
$port = $defaultPort
try { $port = [int](Read-Host "HTTP listen port (blank for $defaultPort)") } catch { $port = $defaultPort }
if(Is-PortUsed $port){
  $next = Find-FreePort ($port + 1)
  Write-Host "Port $port is in use. Suggesting $next..." -ForegroundColor Yellow
  try { $picked = [int](Read-Host "Use $next instead? (enter to accept)") ; if($picked){ $port = $picked } else { $port = $next } }
  catch { $port = $next }
}
Write-Host "Using port: $port"

# --- Prompt password (secure Windows credential dialog) ---
Write-Host "==> Set wallet password (for encrypted keystore)..." -ForegroundColor Cyan
$cred = Get-Credential -Message "Set a password for the Damage node key store (username ignored)" -UserName "damage"
$WalletPass = $cred.GetNetworkCredential().Password
if([string]::IsNullOrWhiteSpace($WalletPass)){ throw "Password cannot be empty." }

# --- Generate config/sys.config ---
Write-Host "==> Writing config/sys.config ..." -ForegroundColor Cyan
$sysConfig = @"
[
  {kernel, []},
  {logger, [{handler, default, logger_std_h, [{level, info}]}]},
  {sasl, [{sasl_error_logger, {file, "log/sasl-error.log"}}]},
  {damage, [
      {port, $port},
      {keystore, "damage.key"}
  ]}
].
"@
$sysConfig | Out-File -FilePath (Join-Path $ConfigDir 'sys.config') -Encoding ASCII -Force

# --- Compile ---
Write-Host "==> Compiling (rebar3 compile)..." -ForegroundColor Cyan
Push-Location $ProjectDir
& $Escript.FullName $Rebar3Path version | Out-Null
& $Escript.FullName $Rebar3Path compile
Pop-Location

# --- Initialize encrypted key store (one-shot, no password stored) ---
Write-Host "==> Initializing encrypted key store..." -ForegroundColor Cyan
$env:DAMAGE_SECRET_KEY = $WalletPass
Push-Location $ProjectDir
# Ensure libs available; start dependencies needed by secrets
& "$ErlExe" -pa "$ProjectDir\_build\default\lib\*\ebin" -noshell -eval `
  "application:ensure_all_started(crypto), application:ensure_all_started(enacl), application:ensure_all_started(gproc), secrets:start_link(), secrets:node_keypair(), halt()."
Pop-Location
Remove-Item Env:\DAMAGE_SECRET_KEY

# --- Build release (so run/service scripts work immediately) ---
Write-Host "==> Building release..." -ForegroundColor Cyan
Push-Location $ProjectDir
& $Escript.FullName $Rebar3Path release
Pop-Location

Write-Host "`n✅ Done!"
Write-Host "Project: $ProjectDir"
Write-Host "Port:    $port"
Write-Host "Next:    Double-click damagebdd-run.bat to Start/Stop, or damagebdd-service.bat to install a service."

