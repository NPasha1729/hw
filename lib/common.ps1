# hw kit - shared helpers. ASCII only. PowerShell 5.1 compatible. No Add-Type.

$script:HW_VERSION = '1.0.0'

function Clean([object]$v, [int]$max = 120) {
  # Seller-controlled string -> printable ASCII, capped.
  if ($null -eq $v) { return $null }
  $s = [string]$v
  $s = ($s -replace '[^\x20-\x7E]', '').Trim()
  if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
  return $s
}

function Unk([string]$reason) { return "UNKNOWN($reason)" }
function IsUnk($v) { return ($null -eq $v) -or (($v -is [string]) -and $v.StartsWith('UNKNOWN(')) }

function Try-Get([scriptblock]$sb, [string]$reason = 'error') {
  try {
    $v = & $sb
    if ($null -eq $v -or (($v -is [string]) -and $v -eq '')) { return (Unk 'empty') }
    return $v
  } catch {
    $m = $_.Exception.Message
    if ($m -match 'denied|not available to the client|elevation|privilege|Administrator') { return (Unk 'needs admin') }
    return (Unk ($reason + ': ' + (Clean $m 80)))
  }
}

function Is-Admin {
  try {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch {
    return [bool]((whoami /groups) -match 'S-1-16-12288')
  }
}

function Write-Text([string]$path, [string]$text) {
  # UTF-8 without BOM, flushed. Falls back to Out-File in Constrained Language Mode.
  try { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding($false))) }
  catch { $text | Out-File -FilePath $path -Encoding ascii -Force }
}

function Save-Json($obj, [string]$path) { Write-Text $path ($obj | ConvertTo-Json -Depth 8) }

function Load-Json([string]$path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content -Raw -Path $path | ConvertFrom-Json) } catch { return $null }
}

function Say([string]$msg, [string]$color = 'Gray') { Write-Host $msg -ForegroundColor $color }

function Ask([string]$prompt, [string]$default = '') {
  if ($script:RUNAUTO) { return $default }
  $suffix = ''
  if ($default -ne '') { $suffix = " [$default]" }
  $a = Read-Host ($prompt + $suffix)
  if ([string]::IsNullOrWhiteSpace($a)) { return $default }
  return $a.Trim()
}

function Ask-YSQ([string]$prompt) {
  # Returns y, s or q.
  if ($script:RUNAUTO) { return 'y' }
  while ($true) {
    $a = (Read-Host ($prompt + ' (y = run / s = skip / q = stop tests)')).Trim().ToLower()
    if ($a -in @('y', 's', 'q')) { return $a }
  }
}

function Safe-Name([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s) -or (IsUnk $s)) { return 'UNKNOWN' }
  $t = ($s -replace '[^A-Za-z0-9]+', '-').Trim('-')
  if ($t.Length -gt 24) { $t = $t.Substring(0, 24) }
  if ($t -eq '') { return 'UNKNOWN' }
  return $t
}

function Find-NvidiaSmi {
  $c = Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $cands = @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:windir\System32\nvidia-smi.exe")
  foreach ($p in $cands) { if (Test-Path $p) { return $p } }
  $ds = Get-ChildItem "$env:windir\System32\DriverStore\FileRepository" -Filter 'nv*' -Directory -ErrorAction SilentlyContinue
  foreach ($d in $ds) { $p = Join-Path $d.FullName 'nvidia-smi.exe'; if (Test-Path $p) { return $p } }
  return $null
}

function Get-UsbRoot([string]$kitRoot) {
  # The drive the kit was launched from, if it is removable (DriveType 2).
  if ([string]::IsNullOrWhiteSpace($kitRoot)) { return $null }
  $q = Split-Path -Qualifier $kitRoot -ErrorAction SilentlyContinue
  if (-not $q) { return $null }
  $ld = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$q'" -ErrorAction SilentlyContinue
  if ($ld -and $ld.DriveType -eq 2) { return ($q + '\') }
  return $null
}

function Get-DesktopDir {
  try { $d = [Environment]::GetFolderPath('Desktop'); if ($d -and (Test-Path $d)) { return $d } } catch {}
  return (Join-Path $env:USERPROFILE 'Desktop')
}

function Write-Text-Strict([string]$path, [string]$text) {
  # Like Write-Text but throws on failure, so the caller can move to another folder.
  $enc = New-Object Text.UTF8Encoding($false)
  try { [IO.File]::WriteAllText($path, $text, $enc) }
  catch { $text | Out-File -FilePath $path -Encoding ascii -Force -ErrorAction Stop }
}

function Pick-WritableDir([string[]]$cands) {
  # First folder we can create AND write a file in.
  foreach ($d in $cands) {
    if ([string]::IsNullOrWhiteSpace($d)) { continue }
    try {
      New-Item -ItemType Directory -Path $d -Force -ErrorAction Stop | Out-Null
      $t = Join-Path $d ('.hw-write-test-' + [guid]::NewGuid().ToString('N'))
      Set-Content -Path $t -Value 'x' -ErrorAction Stop
      Remove-Item $t -Force -ErrorAction SilentlyContinue
      return $d
    } catch {}
  }
  return $null
}
