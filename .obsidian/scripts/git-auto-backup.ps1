param(
  [string]$Repo = "E:\yueyutai\notes\studt_notes",
  [string]$Branch = "main"
)

$ErrorActionPreference = "Continue"
$env:GIT_TERMINAL_PROMPT = "0"
$env:GCM_INTERACTIVE = "never"

$StateDir = Join-Path $env:LOCALAPPDATA "ObsidianStudyNotesBackup"
$LogFile = Join-Path $StateDir "git-auto-backup.log"
$LockFile = Join-Path $StateDir "git-auto-backup.lock"
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Write-BackupLog {
  param([string]$Message)
  $stamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Add-Content -LiteralPath $LogFile -Encoding UTF8 -Value "[$stamp] $Message"
}

function Get-GitExe {
  $cmd = Get-Command git -ErrorAction SilentlyContinue
  if ($cmd -and $cmd.Source) {
    return $cmd.Source
  }

  $desktopRoot = Join-Path $env:LOCALAPPDATA "GitHubDesktop"
  $desktopGit = Get-ChildItem -LiteralPath $desktopRoot -Directory -Filter "app-*" -ErrorAction SilentlyContinue |
    Sort-Object Name -Descending |
    ForEach-Object {
      Join-Path $_.FullName "resources\app\git\cmd\git.exe"
    } |
    Where-Object { Test-Path -LiteralPath $_ } |
    Select-Object -First 1

  if ($desktopGit) {
    return $desktopGit
  }

  throw "git.exe not found. Install Git or GitHub Desktop."
}

function Invoke-Git {
  param(
    [string[]]$Arguments,
    [switch]$AllowFailure
  )

  $output = & $GitExe -C $Repo @Arguments 2>&1
  $code = $LASTEXITCODE
  if ($output) {
    Write-BackupLog ("git " + ($Arguments -join " ") + " -> " + (($output | Out-String).Trim()))
  }
  if ($code -ne 0 -and -not $AllowFailure) {
    throw "git $($Arguments -join ' ') failed with exit code $code"
  }
  return @{ Code = $code; Output = $output }
}

function Sync-GitProxyWithWindows {
  $settings = Get-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
  if ($settings.ProxyEnable -eq 1 -and $settings.ProxyServer) {
    $proxy = [string]$settings.ProxyServer
    if ($proxy -match "(?:https|http)=([^;]+)") {
      $proxy = $Matches[1]
    }
    if ($proxy -notmatch "^[a-zA-Z][a-zA-Z0-9+.-]*://") {
      $proxy = "http://$proxy"
    }
    Invoke-Git -Arguments @("config", "http.proxy", $proxy) | Out-Null
    Invoke-Git -Arguments @("config", "https.proxy", $proxy) | Out-Null
    Write-BackupLog "Using proxy $proxy"
  } else {
    Invoke-Git -Arguments @("config", "--unset-all", "http.proxy") -AllowFailure | Out-Null
    Invoke-Git -Arguments @("config", "--unset-all", "https.proxy") -AllowFailure | Out-Null
    Write-BackupLog "Using direct network access"
  }
}

if (Test-Path -LiteralPath $LockFile) {
  $lock = Get-Item -LiteralPath $LockFile
  if ($lock.LastWriteTime -gt (Get-Date).AddMinutes(-15)) {
    Write-BackupLog "Another backup run is active; exiting."
    exit 0
  }
}

Set-Content -LiteralPath $LockFile -Encoding UTF8 -Value "$PID $(Get-Date -Format o)"

try {
  $GitExe = Get-GitExe
  Write-BackupLog "Backup started. Repo=$Repo Branch=$Branch Git=$GitExe"

  Sync-GitProxyWithWindows

  Invoke-Git -Arguments @("status", "--short", "--branch") | Out-Null

  $status = Invoke-Git -Arguments @("status", "--porcelain")
  if (($status.Output | Measure-Object).Count -gt 0) {
    Invoke-Git -Arguments @("add", "-A") | Out-Null
    $staged = Invoke-Git -Arguments @("diff", "--cached", "--quiet") -AllowFailure
    if ($staged.Code -ne 0) {
      $message = "auto backup: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
      Invoke-Git -Arguments @("commit", "-m", $message) | Out-Null
      Write-BackupLog "Committed changes: $message"
    } else {
      Write-BackupLog "No staged changes after add."
    }
  } else {
    Write-BackupLog "No local changes."
  }

  Invoke-Git -Arguments @("fetch", "--prune", "origin") | Out-Null
  Invoke-Git -Arguments @("pull", "--rebase", "origin", $Branch) | Out-Null
  Invoke-Git -Arguments @("push", "origin", $Branch) | Out-Null

  Write-BackupLog "Backup finished successfully."
} catch {
  Write-BackupLog ("ERROR: " + $_.Exception.Message)
  exit 1
} finally {
  Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}
