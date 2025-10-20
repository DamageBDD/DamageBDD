#requires -version 5.1
param(
  [switch]$InstallOnly,
  [switch]$Start,
  [switch]$UpdateOnly,
  [switch]$RebuildOnly,
  [int]$Port = 0,
  [switch]$Localhost,
  [string]$Branch = "develop",
  [string]$RepoOwner = "DamageBDD",
  [string]$RepoName  = "DamageBDD"
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ------------------ Config ------------------
$BASE         = 'http://run.dev.damagebdd.com/static/'
$HOME         = $env:USERPROFILE
$RootDir      = Join-Path $HOME 'DamageBDD'
$CfgDir       = Join-Path $RootDir 'config'
$LastShaF     = Join-Path $RootDir '.last_sha'
$PortF        = Join-Path $RootDir '.port'
$LocalF       = Join-Path $RootDir '.localhost'
$Rebar3       = Join-Path $RootDir 'rebar3'

$ErlangFile     = 'otp_win64_28.1.exe'
$ErlangBase     = "$BASE$ErlangFile"
$ErlangFallback = 'https://github.com/erlang/otp/releases/download/OTP-28.1/otp_win64_28.1.exe'

$RebarBase      = "$BASE" + 'rebar3'
$RebarFallback  = 'https://s3.amazonaws.com/rebar3/rebar3'

$ZipUrl         = "https://github.com/$RepoOwner/$RepoName/archive/refs/heads/$Branch.zip"
$ApiUrl         = "https://api.github.com/repos/$RepoOwner/$RepoName/branches/$Branch"

# ------------------ UX / Errors ------------------
function Log([string]$m, [ConsoleColor]$c='Cyan'){ Write-Host $m -ForegroundColor $c }
function Pause-Error([string]$msg, $errObj=$null) {
  $detail = if ($errObj) { ($errObj | Out-String) } else { "" }
  $full = "[ERROR] $msg`n$detail"
  Write-Host $full -ForegroundColor Red
  Write-Host ""
  Write-Host "Press 'C' to copy this error to clipboard, or any other key to continue..." -ForegroundColor Yellow
  $k = [Console]::ReadKey($true)
  if ($k.Key -eq 'C') {
    try {
      Set-Clipboard -Value $full
      Write-Host "Copied to clipboard." -ForegroundColor Green
    } catch {
      try {
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.Clipboard]::SetText($full)
        Write-Host "Copied to clipboard (WinForms)." -ForegroundColor Green
      } catch {
        Write-Host "Copy failed; clipboard not available." -ForegroundColor Yellow
      }
    }
  }
  Write-Host "Press Enter to exit..." -ForegroundColor Yellow
  [void][Console]::ReadLine()
  exit 1
}
trap { Pause-Error "Unhandled exception:" $_ }

# ------------------ Helpers ------------------
function Ensure-Admin {
  $id=[Security.Principal.WindowsIdentity]::GetCurrent()
  $p=[Security.Principal.WindowsPrincipal]$id
  if(-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)){
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName='powershell.exe'
    $psi.Arguments="-NoP -EP Bypass -File `"$PSCommandPath`" " + ($MyInvocation.Line -replace '.*Install-DamageBDD\.ps1','')
    $psi.Verb='runas'
    try { [Diagnostics.Process]::Start($psi) | Out-Null } catch { Pause-Error "Elevation cancelled." $_ }
    exit
  }
}
function Ensure-Dir($p){ if(-not (Test-Path $p)){ New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Find-Exe([string]$n){ Get-Command $n -ErrorAction SilentlyContinue | Select-Object -First 1 }
function Is-PortUsed([int]$p){ try { (Get-NetTCPConnection -State Listen -LocalPort $p -ErrorAction Stop) } catch { $false } }
function Find-FreePort([int]$start=8080){ $p=[Math]::Max(1,$start); while(Is-PortUsed $p){$p++}; $p }

# Prefer BASE URL, fallback to alt if 404/timeout
function Get-FromBase([string]$primary, [string]$fallback, [string]$outPath){
  try {
    Invoke-WebRequest -Uri $primary -OutFile $outPath -UseBasicParsing -TimeoutSec 60
    return
  } catch {
    Log "Primary unavailable ($primary). Falling back..." 'Yellow'
    try {
      Invoke-WebRequest -Uri $fallback -OutFile $outPath -UseBasicParsing -TimeoutSec 120
      return
    } catch {
      Pause-Error "Failed to download:`n$primary`n…and fallback:`n$fallback" $_
    }
  }
}

# ------------------ Erlang / rebar3 ------------------
function Ensure-Erlang {
  $es = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'escript.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if($es){ return $es.Directory.FullName }
  Log "Installing Erlang/OTP 28.1 ..." 'Yellow'
  $tmp = Join-Path $env:TEMP $ErlangFile
  Get-FromBase $ErlangBase $ErlangFallback $tmp
  $p = Start-Process -FilePath $tmp -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
  if($p.ExitCode -ne 0){ Pause-Error "Erlang installer exited with $($p.ExitCode)." }
  $es = Get-ChildItem -Path 'C:\Program Files','C:\Program Files (x86)' -Filter 'escript.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
  if(-not $es){ Pause-Error "escript.exe not found after installing Erlang." }
  $es.Directory.FullName
}

function Ensure-Rebar3 {
  if(-not (Test-Path $Rebar3)){
    Log "Fetching rebar3 ..." 'Cyan'
    Get-FromBase $RebarBase $RebarFallback $Rebar3
    Unblock-File $Rebar3
  }
}

# ------------------ Repo sync ------------------
function Get-RemoteSha {
  Invoke-RestMethod -Uri $ApiUrl -Headers @{ 'User-Agent'='DamageBDD-Installer' } | ForEach-Object { $_.commit.sha }
}
function Repo-HasGit { Test-Path (Join-Path $RootDir '.git') }
function Update-FromGit {
  $git = Find-Exe git; if(-not $git){ return $false }
  if(-not (Repo-HasGit)){
    if(Test-Path $RootDir){ Remove-Item -Recurse -Force $RootDir }
    & $git.Source git clone --branch $Branch --depth 1 "https://github.com/$RepoOwner/$RepoName.git" $RootDir
  } else {
    Push-Location $RootDir
    & $git.Source git fetch origin $Branch --depth 1
    & $git.Source git reset --hard "origin/$Branch"
    Pop-Location
  }
  $true
}
function Update-FromZip {
  Log "Fetching repo zip ..." 'Cyan'
  $tmp = Join-Path $env:TEMP "dbdd-$([Guid]::NewGuid()).zip"
  $ex  = Join-Path $env:TEMP "dbdd-ex-$([Guid]::NewGuid())"
  Invoke-WebRequest -Uri $ZipUrl -OutFile $tmp -UseBasicParsing
  Expand-Archive -Path $tmp -DestinationPath $ex -Force
  $root = Get-ChildItem -Path $ex -Directory | Select-Object -First 1
  if(Test-Path $RootDir){ Remove-Item -Recurse -Force $RootDir }
  Move-Item $root.FullName $RootDir
}
function Ensure-Repo-UpToDate {
  Ensure-Dir $RootDir
  $remote = Get-RemoteSha
  $local  = (Test-Path $LastShaF) ? (Get-Content $LastShaF -Raw).Trim() : ''
  if(-not (Test-Path (Join-Path $RootDir 'rebar.config'))){
    if(Update-FromGit){ } else { Update-FromZip }
    Set-Content -Path $LastShaF -Value $remote -Encoding ascii
    return
  }
  if($remote -ne $local){
    Log "New upstream commit detected. Updating ..." 'Yellow'
    if(Update-FromGit){ } else { Update-FromZip }
    Set-Content -Path $LastShaF -Value $remote -Encoding ascii
  } else {
    Log "Already up to date ($remote)." 'DarkGray'
  }
}

# ------------------ Config / Build ------------------
function Read-Or-Prompt-Port {
  if($Port -gt 0){ return $Port }
  if(Test-Path $PortF){ try { return [int](Get-Content $PortF -Raw) } catch {} }
  $d = 8080
  try { $p = [int](Read-Host "HTTP listen port (default $d)"); if($p -gt 0){$d=$p} } catch {}
  if(Is-PortUsed $d){ $d = Find-FreePort ($d+1); Log "Port in use, picked $d" 'Yellow' }
  Set-Content -Path $PortF -Value $d -Encoding ascii
  $d
}
function Remember-Localhost {
  if($Localhost){ Set-Content -Path $LocalF -Value "1" -Encoding ascii }
  elseif(-not (Test-Path $LocalF)){ Set-Content -Path $LocalF -Value "0" -Encoding ascii }
  [bool]((Test-Path $LocalF) -and ((Get-Content $LocalF -Raw).Trim() -eq '1'))
}

function Write-SysConfig([int]$p,[bool]$useLocal){
  Ensure-Dir $CfgDir

  # PS 5.1-safe conditional (no ternary, no assigning 'if' expression)
  $bindIp = '0.0.0.0'
  if ($useLocal) { $bindIp = '127.0.0.1' }

  @"
[
  {kernel, []},
  {logger, [{handler, default, logger_std_h, [{level, info}]}]},
  {sasl, [{sasl_error_logger, {file, "log/sasl-error.log"}}]},
  {damage, [
      {port, $p},
      {bind_ip, "$bindIp"},
      {keystore, "damage.key"}
  ]}
].
"@ | Out-File (Join-Path $CfgDir 'sys.config') -Encoding ascii -Force
}

function Build-Project {
  $erlbin = Ensure-Erlang
  Ensure-Rebar3
  $escript = Join-Path $erlbin 'escript.exe'
  Push-Location $RootDir
  & $escript $Rebar3 version | Out-Null
  & $escript $Rebar3 compile
  & $escript $Rebar3 release
  Pop-Location
}

function Init-Keystore {
  $keyfile = Join-Path $RootDir 'damage.key'
  if(Test-Path $keyfile){ return }
  Log "Initialize encrypted keystore (password dialog) ..." 'Cyan'
  $cred = Get-Credential -Message "Set a password for the Damage node key store (username ignored)" -UserName "damage"
  $pass = $cred.GetNetworkCredential().Password
  if([string]::IsNullOrWhiteSpace($pass)){ Pause-Error "Password cannot be empty." }

  $erlbin = Ensure-Erlang
  $erl    = Join-Path (Split-Path $erlbin -Parent) 'erl.exe'
  $env:DAMAGE_SECRET_KEY = $pass
  try {
    Push-Location $RootDir
    & $erl -pa "$RootDir\_build\default\lib\*\ebin" -noshell -eval `
      "application:ensure_all_started(crypto), application:ensure_all_started(enacl), application:ensure_all_started(gproc), catch(secrets:start_link()), catch(secrets:node_keypair()), halt()."
  } catch {
    Pause-Error "Keystore init failed." $_
  } finally {
    Pop-Location
    Remove-Item Env:\DAMAGE_SECRET_KEY -ErrorAction SilentlyContinue
  }
}

# ------------------ Run ------------------
function Start-DamageBDD {
  Ensure-Repo-UpToDate
  $p = Read-Or-Prompt-Port
  $loc = Remember-Localhost
  Write-SysConfig -p $p -useLocal $loc
  Build-Project
  Init-Keystore

  $rel = Join-Path $RootDir "_build\default\rel\damagebdd\bin"
  $cmd = Get-ChildItem $rel -Filter "damagebdd*.cmd","damagebdd*.bat" -ErrorAction SilentlyContinue | Select-Object -First 1
  if($cmd){
    Log "Starting release (port $p) ..." 'Green'
    Push-Location $rel
    Start-Process -WindowStyle Normal -WorkingDirectory $rel -FilePath $cmd.FullName -ArgumentList "start"
    Pop-Location
    Log "Use: `"$($cmd.Name) stop`" in $rel to stop." 'DarkGray'
  } else {
    Log "Release script not found; falling back to 'rebar3 shell'." 'Yellow'
    $erlbin = Ensure-Erlang
    $escript = Join-Path $erlbin 'escript.exe'
    Push-Location $RootDir
    Start-Process -WindowStyle Normal -WorkingDirectory $RootDir -FilePath $escript -ArgumentList "`"$Rebar3`" shell"
    Pop-Location
  }
}

# ------------------ Entry ------------------
Ensure-Admin
Ensure-Dir $RootDir

try {
  if($InstallOnly){ Ensure-Repo-UpToDate; Build-Project; Log "Installed to $RootDir" 'Green'; exit }
  if($UpdateOnly){  Ensure-Repo-UpToDate; Log "Update complete." 'Green'; exit }
  if($RebuildOnly){ Build-Project; Log "Rebuilt." 'Green'; exit }
  if($Start){ Start-DamageBDD; exit }

  Ensure-Repo-UpToDate
  Build-Project
  if((Read-Host "Start now? (Y/n)") -ne 'n'){ Start-DamageBDD }
} catch {
  Pause-Error "Installer failed." $_
}

