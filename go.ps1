# hw - used machine inspection kit. Windows entry point. ASCII only, PowerShell 5.1.
# USB:       double-click go.cmd
# Internet:  see README (one-liner downloads the kit, then runs this file)
# Test mode: go.ps1 -Auto -Tests disk,render -Quick
#
# Fallback chain (each step only runs if the one before it failed):
#   go.cmd: -File go.ps1  ->  in-memory load (beats AllSigned/GPO script blocking)  ->  fallback.cmd (cmd only)
#   one-liner: download zip -> tar / Expand-Archive -> -File go.ps1 -> in-memory load -> "use the USB"
#   collector: elevated (UAC) -> non-elevated -> partial results on timeout -> fallback.cmd
#   report folder: -OutRoot -> USB\reports -> Desktop\hw-reports -> %TEMP%\hw-reports
param(
  [string]$KitRoot = '',
  [switch]$Auto,
  [ValidateSet('render', 'llm', 'security', 'all', '')][string]$Use = '',
  [string[]]$Tests = @(),
  [switch]$Quick,
  [switch]$NoElevate,
  [switch]$NoRedact,
  [string]$OutRoot = '',
  [string]$ClaimsJson = ''
)

# ---------- where is the kit? (file run, or in-memory run started by go.cmd / the bootstrap)
$ROOT = $PSScriptRoot
if (-not $ROOT -and $env:HW_KIT -and (Test-Path (Join-Path $env:HW_KIT 'go.ps1'))) { $ROOT = $env:HW_KIT }

# ---------- iex bootstrap: nothing on disk yet -> fetch the kit, then run it
if (-not $ROOT) {
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}
  $base = 'https://github.com/NPasha1729/hw/archive/refs/heads/main.zip'
  if ($env:HW_ZIP_URL) { $base = $env:HW_ZIP_URL }
  $dst = Join-Path $env:TEMP 'hw-kit'
  if ($env:HW_BOOT_DIR) { $dst = $env:HW_BOOT_DIR }   # test hook: isolated download folder
  $zip = Join-Path $env:TEMP 'hw-kit.zip'
  Write-Host 'Downloading the hw kit (scripts only, under 1 MB)...'
  $ok = $false
  try { Invoke-WebRequest -UseBasicParsing -Uri $base -OutFile $zip -ErrorAction Stop; $ok = $true }
  catch {
    try { & curl.exe -sSL -o $zip $base; if ((Test-Path $zip) -and (Get-Item $zip).Length -gt 1000) { $ok = $true } } catch {}
    if (-not $ok) { Write-Host ('Download failed: ' + $_.Exception.Message) -ForegroundColor Red }
  }
  if (-not $ok) { Write-Host 'No internet or GitHub blocked. Use the USB stick instead (double-click go.cmd).' -ForegroundColor Yellow; return }
  if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Path $dst -Force | Out-Null
  try { & tar.exe -xf $zip -C $dst 2>$null } catch {}
  if (-not (Get-ChildItem $dst -Recurse -Filter go.ps1 -ErrorAction SilentlyContinue)) {
    try { Expand-Archive -Path $zip -DestinationPath $dst -Force -ErrorAction Stop } catch {
      try { $sh = New-Object -ComObject Shell.Application; $sh.NameSpace($dst).CopyHere($sh.NameSpace($zip).Items(), 20) } catch {}
    }
  }
  Remove-Item $zip -ErrorAction SilentlyContinue
  $go = Get-ChildItem $dst -Recurse -Filter go.ps1 -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $go) { Write-Host 'Could not unpack the kit. Use the USB stick (double-click go.cmd).' -ForegroundColor Red; return }
  Get-ChildItem $dst -Recurse | Unblock-File -ErrorAction SilentlyContinue
  $env:HW_KIT = $go.DirectoryName
  $flag = Join-Path $env:TEMP 'hw-started.flag'
  Remove-Item $flag -ErrorAction SilentlyContinue
  $bootArgs = @(); if ($env:HW_BOOT_ARGS) { $bootArgs = @($env:HW_BOOT_ARGS -split ' ' | Where-Object { $_ }) }
  $pol = 'Bypass'; if ($env:HW_TEST_POLICY) { $pol = $env:HW_TEST_POLICY }
  & powershell.exe -NoProfile -ExecutionPolicy $pol -File $go.FullName @bootArgs
  if (-not (Test-Path $flag)) {
    Write-Host 'Script files are blocked on this PC (policy). Running the kit from memory instead...' -ForegroundColor Yellow
    $sb = [scriptblock]::Create((Get-Content -Raw $go.FullName))
    if ($env:HW_BOOT_ARGS) { Invoke-Expression ('& $sb ' + $env:HW_BOOT_ARGS) } else { & $sb }
  }
  return
}

# ---------- started marker: lets go.cmd / the bootstrap know the script really ran
try { Set-Content -Path (Join-Path $env:TEMP 'hw-started.flag') -Value (Get-Date).ToString('s') -Encoding ascii } catch {}

# ---------- load libraries in memory (works even when execution policy blocks .ps1 files)
function Use-Lib([string]$name) { . ([scriptblock]::Create((Get-Content -Raw (Join-Path (Join-Path $ROOT 'lib') $name)))) }
$ErrorActionPreference = 'Continue'
$langMode = [string]$ExecutionContext.SessionState.LanguageMode
if ($env:HW_TEST_LANGMODE) { $langMode = $env:HW_TEST_LANGMODE }   # test hook: real CLM needs AppLocker/WDAC
if ($langMode -ne 'FullLanguage') {
  Write-Host 'PowerShell is locked down on this machine (Constrained Language Mode).' -ForegroundColor Yellow
  Write-Host 'Running the basic cmd collector instead.' -ForegroundColor Yellow
  & cmd.exe /c (Join-Path $ROOT 'fallback.cmd')
  exit 0
}
. Use-Lib 'common.ps1'
. Use-Lib 'verdict.ps1'
. Use-Lib 'bench.ps1'
. Use-Lib 'manual.ps1'

if (-not $KitRoot) { $KitRoot = $ROOT }
$KitRoot = $KitRoot.TrimEnd('\')
$script:KIT = $ROOT
$script:RUNAUTO = [bool]$Auto
# Assets live next to the ORIGINAL kit (the USB); scripts may run from a TEMP copy.
if (Test-Path (Join-Path $KitRoot 'assets')) { $script:KIT = $KitRoot }
$script:USBROOT = Get-UsbRoot $KitRoot
foreach ($f in 'PROMPT.md', 'stress') { if (-not (Test-Path (Join-Path $script:KIT $f)) -and (Test-Path (Join-Path $ROOT $f))) { $script:KIT = $ROOT } }
if (-not (Test-Path (Join-Path $script:KIT 'assets'))) { $script:ASSETDIR = Join-Path $ROOT 'assets' } else { $script:ASSETDIR = Join-Path $script:KIT 'assets' }
try { $host.UI.RawUI.WindowTitle = 'hw inspection kit' } catch {}

Say ''
Say '==============================================' 'Cyan'
Say "  hw - used machine inspection kit v$script:HW_VERSION" 'Cyan'
Say '==============================================' 'Cyan'
Say 'Nothing is uploaded. Step 1 only READS this machine and saves a report.'
Say 'Load tests come later and each one asks first.'
Say ''
if ($PSVersionTable.PSVersion.Major -lt 5) { Say "PowerShell $($PSVersionTable.PSVersion) is old; some checks may show UNKNOWN." 'Yellow' }

$script:UUID = Try-Get { (Get-CimInstance Win32_ComputerSystemProduct).UUID }

# ---------- clean up after an earlier run that was closed or crashed
Cleanup-Leftovers
Undo-Restore
$crash = Check-PreviousCrash
if ($crash) {
  if ($crash.boot -ne 'no reboot' -and $crash.ac -eq 'on battery') { Say "WARNING: last run, this machine switched off during the $($crash.test) test while ON BATTERY (battery may have run out)." 'Yellow' }
  elseif ($crash.boot -ne 'no reboot') { Say "WARNING: last run, this machine shut down or crashed during the $($crash.test) test (rebooted $($crash.boot))." 'Red' }
  else { Say "Note: last run stopped during the $($crash.test) test (window closed, no reboot)." 'Yellow' }
}

# ---------- where reports go: first folder we can actually write to
$cands = @()
if ($OutRoot) { $cands += $OutRoot }
if ($script:USBROOT) { $cands += (Join-Path $script:USBROOT 'reports') }
$cands += (Join-Path (Get-DesktopDir) 'hw-reports')
$cands += (Join-Path $env:TEMP 'hw-reports')
$script:OUTCANDS = $cands
$outBase = Pick-WritableDir $cands
if (-not $outBase) { Say 'Cannot write a report anywhere (USB, Desktop and TEMP all failed).' 'Red'; & cmd.exe /c (Join-Path $ROOT 'fallback.cmd'); exit 0 }
if ($outBase -ne $cands[0]) { Say "  Reports will be saved in $outBase (first choice was not writable)." 'Yellow' }

# ---------- intake
Say 'INTAKE - type what the seller claims (Enter = skip).' 'Cyan'
$C = [ordered]@{}
$C.label = Ask '  Shop / stall name' 'unnamed'
$C.price = Ask '  Asking price (INR)'
$C.refurb = Ask '  Refurbished unit with warranty? (y/n)' 'n'
if ($C.refurb -eq 'y') { $C.refurb_warranty_months = Ask '  Warranty months offered' }
$C.model = Ask '  Model the seller claims'
$C.cpu = Ask '  CPU the seller claims (e.g. i7-11800H)'
$C.gpu = Ask '  Graphics card the seller claims (e.g. RTX 3060)'
$C.vram_gb = Ask '  Graphics memory GB claimed (e.g. 6)'
$C.ram_gb = Ask '  RAM GB claimed'
$C.ssd_gb = Ask '  Storage GB claimed'
$C.age_years = Ask '  Age in years claimed'
$C.prev_use = Ask '  Previous use claimed (office / gaming / personal)'
if ($ClaimsJson -and (Test-Path $ClaimsJson)) { foreach ($pr in (Get-Content -Raw $ClaimsJson | ConvertFrom-Json).PSObject.Properties) { $C[$pr.Name] = $pr.Value } }
$C.mode = if ($script:USBROOT) { 'USB' } elseif ($env:HW_KIT) { 'download' } else { 'disk' }
if (-not $Use) {
  $Use = 'render'
  $u = Ask '  Main use: 1 Render  2 Local LLM  3 Security labs  4 All' '1'
  switch ($u) { '2' { $Use = 'llm' } '3' { $Use = 'security' } '4' { $Use = 'all' } default { $Use = 'render' } }
}
foreach ($k in 'vram_gb', 'ram_gb', 'ssd_gb', 'age_years') { if ($C[$k]) { $n = [regex]::Match([string]$C[$k], '\d+(\.\d+)?'); $C[$k] = if ($n.Success) { [double]$n.Value } else { '' } } }

# ---------- PHASE A
Say ''
Say 'PHASE A - reading this machine (about 1 minute, nothing can break).' 'Cyan'
[void](Asset 'win\smartctl\smartctl.exe' -Quiet)   # tiny; fetched automatically in download mode
$R = Run-Collector -Elevate:(-not $NoElevate -and -not $script:RUNAUTO) -NoRedact:$NoRedact
if (-not $R) { Say 'The collector failed completely. Running the basic cmd collector.' 'Red'; & cmd.exe /c (Join-Path $ROOT 'fallback.cmd'); exit 0 }

$sys = [string]$R.id.serials.system; if (IsUnk $sys) { $sys = 'UNKNOWN' }
$tail = if ($sys.Length -gt 4) { $sys.Substring($sys.Length - 4) } else { $sys }
$name = 'hw-' + (Safe-Name $R.id.maker) + '-' + (Safe-Name $R.id.model) + '-' + (Safe-Name $tail) + '-' + (Get-Date).ToString('yyyyMMdd-HHmm')
$script:REPORTNAME = $name
$script:REPORTDIR = Join-Path $outBase $name
New-Item -ItemType Directory -Path $script:REPORTDIR -Force -ErrorAction SilentlyContinue | Out-Null

$B = [ordered]@{}
if ($crash -and $crash.boot -ne 'no reboot') {
  $lv = if ($crash.ac -eq 'on battery') { 'AMBER' } else { 'RED' }
  $B[$crash.test] = @{ status = 'CRASHED'; level = $lv; summary = "machine switched off during the $($crash.test) test on the previous run ($($crash.at), power: $($crash.ac))" }
}
$M = @{}

function Save-All([string]$stage) {
  $V = Get-Verdict $R $C $B $M $Use
  $md = Render-Report $R $C $B $M $V $script:KIT
  $json = [ordered]@{ raw = $R; claims = $C; bench = $B; manual = $M; verdict = $V; stage = $stage } | ConvertTo-Json -Depth 8
  # Save; if the folder vanished (USB pulled, disk full), move to the next writable folder and retry.
  foreach ($attempt in 1..4) {
    try {
      if (-not (Test-Path $script:REPORTDIR)) { New-Item -ItemType Directory -Path $script:REPORTDIR -Force -ErrorAction Stop | Out-Null }
      Write-Text-Strict (Join-Path $script:REPORTDIR 'REPORT.md') $md
      Write-Text-Strict (Join-Path $script:REPORTDIR 'raw.json') $json
      return $V
    } catch {
      $next = Pick-WritableDir @($script:OUTCANDS | Where-Object { $script:REPORTDIR -notlike ($_ + '*') })
      if (-not $next) { break }
      Say "  Could not save to $($script:REPORTDIR); saving to $next instead." 'Yellow'
      $script:OUTCANDS = @($script:OUTCANDS | Where-Object { $script:REPORTDIR -notlike ($_ + '*') })
      $script:REPORTDIR = Join-Path $next $script:REPORTNAME
    }
  }
  Say '  WARNING: report could not be saved anywhere. Take a photo of this screen.' 'Red'
  return $V
}

$V = Save-All 'phase-a'
Say ''
Say "Report saved: $($script:REPORTDIR)\REPORT.md" 'Green'
Show-Verdict $V

# ---------- PHASE C offered early (wary seller)
$doneManual = $false
if (-not $script:RUNAUTO) {
  $a = Ask 'Do the manual checks now (screen, keyboard, ports...)? y = now, n = after load tests, s = skip' 'n'
  if ($a -eq 'y') { $M = Run-Manual $R $M; $doneManual = $true; $V = Save-All 'phase-c' ; Show-Verdict $V }
}

# ---------- PHASE B
$all = @(
  @{ k = 'disk'; t = 'Disk speed test'; d = 'writes and reads a 4 GB temp file, then deletes it'; time = '1-2 min'; risk = 'very low' },
  @{ k = 'render'; t = 'Render benchmark'; d = 'encodes a 20 s 1080p test video with ffmpeg'; time = '1-3 min'; risk = 'low' },
  @{ k = 'llm'; t = 'Local AI (LLM) benchmark'; d = 'runs a small 0.5B model on the GPU and CPU'; time = '1-3 min'; risk = 'low' },
  @{ k = 'cpu'; t = 'CPU stress'; d = 'all cores at 100%, watching for heat throttling'; time = '5 min'; risk = 'medium (overheating machines may shut down)' },
  @{ k = 'gpu'; t = 'GPU stress'; d = 'full-screen graphics load in the browser'; time = '7 min'; risk = 'HIGHEST (a failing GPU may crash or reboot)' }
)
$cpuSecs = 300; $gpuSecs = 420
if ($Quick) { $cpuSecs = 30; $gpuSecs = 40 }
$list = $all
$Tests = @($Tests | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
if ($Tests.Count -gt 0) { $list = @($all | Where-Object { $Tests -contains $_.k }) }
if ($script:RUNAUTO -and $Tests.Count -eq 0) { $list = @() }

if ($list.Count -gt 0) {
  Say ''
  Say 'PHASE B - load tests. The report above is already saved; ask the seller before each test.' 'Cyan'
  if ($R.env.ac -eq 'on battery') { Say '  Plug in the charger first: tests on battery are slower and unfair.' 'Yellow' }
  if ($R.env.sac -eq 'on') { Say '  Smart App Control is ON: Windows may block the benchmark tools.' 'Yellow' }
  $slept = Block-Sleep
  if (-not $slept) { Say '  Could not stop this PC from sleeping; keep touching the touchpad during long tests.' 'DarkGray' }
  foreach ($t in $list) {
    Say ''
    Say ("  " + $t.t + ": " + $t.d) 'White'
    Say ("    time " + $t.time + ", crash risk " + $t.risk) 'DarkGray'
    $a = Ask-YSQ '    Ready?'
    if ($a -eq 'q') { break }
    if ($a -eq 's') { $B[$t.k] = @{ status = 'skipped'; level = 'INFO'; summary = 'skipped by user' }; continue }
    Heartbeat $t.k
    $res = $null
    try {
      switch ($t.k) {
        'disk' { $res = Test-Disk }
        'render' { $res = Test-Render }
        'llm' { $res = Test-LLM $R }
        'cpu' { $res = Test-CPU $cpuSecs }
        'gpu' { $res = Test-GPU $R $gpuSecs }
      }
    } catch { $res = @{ status = 'error'; level = 'INCOMPLETE'; summary = 'test error: ' + (Clean $_.Exception.Message 100) } }
    if (-not $res) { $res = @{ status = 'error'; level = 'INCOMPLETE'; summary = 'test returned nothing' } }
    $B[$t.k] = $res
    Heartbeat 'between'
    $col = @{ 'GREEN' = 'Green'; 'AMBER' = 'Yellow'; 'RED' = 'Red'; 'INCOMPLETE' = 'Magenta'; 'INFO' = 'Gray' }[$res.level]
    if (-not $col) { $col = 'Gray' }
    Say ("    -> " + $res.summary) $col
    $V = Save-All ('phase-b-' + $t.k)
  }
  Undo-Restore
}
Heartbeat 'done'

# ---------- PHASE C
if (-not $doneManual -and -not $script:RUNAUTO) {
  $a = Ask 'Do the manual checks now? (y/n)' 'y'
  if ($a -eq 'y') { $M = Run-Manual $R $M }
}

$V = Save-All 'final'
Show-Verdict $V
Say "Full report: $($script:REPORTDIR)\REPORT.md" 'Green'
Say 'Send REPORT.md to Claude (copy the reports folder to your phone).'
if (-not $script:USBROOT) { Say 'Tip: if you joined this PC to your phone hotspot, forget that Wi-Fi network before leaving.' 'DarkGray' }
if (-not $script:RUNAUTO) { [void](Read-Host 'Press Enter to close') }
if ($PSScriptRoot) { exit 0 }
