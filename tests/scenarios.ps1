# hw kit battle test: forces each failure and checks the fallback that should take over.
# Run: powershell -ep bypass -f tests\scenarios.ps1 [-Only S2,S9]
# Needs: assets\ (python tools\fetch_assets.py), dist\ (python tools\fetch_assets.py --packs), python on PATH.
param([string[]]$Only = @())
$ErrorActionPreference = 'Continue'
$KIT = Split-Path $PSScriptRoot -Parent
$W = Join-Path $env:TEMP ('hw-scen-' + (Get-Date).ToString('HHmmss'))
New-Item -ItemType Directory -Path $W -Force | Out-Null
$results = New-Object System.Collections.ArrayList
$Only = @($Only | ForEach-Object { $_ -split ',' } | Where-Object { $_ })

function Want([string]$id) { return ($Only.Count -eq 0 -or $Only -contains $id) }
function Result([string]$id, [string]$what, [bool]$ok, [string]$detail) {
  [void]$results.Add([pscustomobject]@{ id = $id; ok = $(if ($ok) { 'PASS' } else { 'FAIL' }); what = $what; detail = $detail })
  $c = if ($ok) { 'Green' } else { 'Red' }
  Write-Host ("{0,-4} {1} {2} - {3}" -f $id, $(if ($ok) { 'PASS' } else { 'FAIL' }), $what, $detail) -ForegroundColor $c
}
function Report-In([string]$dir) { $r = Get-ChildItem $dir -Recurse -Filter REPORT.md -ErrorAction SilentlyContinue | Select-Object -First 1; if ($r) { return $r.FullName } return $null }
function Cmd([string]$line, [hashtable]$envs = @{}) {
  $old = @{}; foreach ($k in $envs.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envs[$k]) }
  $o = (cmd.exe /c "echo.| $line" 2>&1 | Out-String)
  foreach ($k in $envs.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
  return $o
}

# S1 normal double-click path
if (Want 'S1') {
  $o = Join-Path $W 's1'
  $out = Cmd "`"$KIT\go.cmd`" -Auto -Use all -OutRoot `"$o`""
  $r = Report-In $o
  Result 'S1' 'go.cmd normal run' ([bool]$r -and $out -notmatch 'basic collector') ($(if ($r) { 'report written' } else { 'no report' }))
}

# S2 execution policy blocks script files (AllSigned) -> in-memory load
if (Want 'S2') {
  $o = Join-Path $W 's2'
  $out = Cmd "`"$KIT\go.cmd`" -Auto -Use all -OutRoot `"$o`"" @{ HW_TEST_POLICY = 'AllSigned' }
  $r = Report-In $o
  Result 'S2' 'policy blocks .ps1 files' ([bool]$r -and $out -match 'Loading the kit into memory') ($(if ($r) { 'in-memory run wrote report' } else { 'no report' }))
}

# S3 PowerShell missing -> basic cmd collector
if (Want 'S3') {
  $f = Join-Path ([Environment]::GetFolderPath('Desktop')) "hw-basic-$env:COMPUTERNAME.txt"
  Remove-Item $f -ErrorAction SilentlyContinue
  $out = Cmd "`"$KIT\go.cmd`"" @{ HW_TEST_NOPS = '1'; HW_NOPAUSE = '1' }
  $ok = (Test-Path $f) -and ($out -match 'PowerShell could not run')
  Result 'S3' 'no PowerShell -> fallback.cmd' $ok ($(if (Test-Path $f) { "basic report $((Get-Content $f).Count) lines" } else { 'no basic report' }))
  Remove-Item $f -ErrorAction SilentlyContinue
}

# S4 Constrained Language Mode -> fallback.cmd
if (Want 'S4') {
  $f = Join-Path ([Environment]::GetFolderPath('Desktop')) "hw-basic-$env:COMPUTERNAME.txt"
  Remove-Item $f -ErrorAction SilentlyContinue
  $out = Cmd "`"$KIT\go.cmd`" -Auto" @{ HW_TEST_LANGMODE = 'ConstrainedLanguage'; HW_NOPAUSE = '1' }
  $ok = (Test-Path $f) -and ($out -match 'locked down|basic collector')
  Result 'S4' 'Constrained Language Mode (simulated) -> fallback.cmd' $ok ($(if ($out -match 'locked down') { 'detected CLM' } elseif (Test-Path $f) { 'fell back' } else { 'no fallback' }))
  Remove-Item $f -ErrorAction SilentlyContinue
}

# S5 go.cmd opened alone (inside a zip / copied without the kit)
if (Want 'S5') {
  $d = Join-Path $W 's5'; New-Item -ItemType Directory $d -Force | Out-Null
  Copy-Item "$KIT\go.cmd" $d
  $out = Cmd "`"$d\go.cmd`""
  Result 'S5' 'go.cmd without its folder (zip preview)' ($out -match 'Extract All') 'tells you to extract the zip'
}

# S6 kit in a path with spaces and parentheses
if (Want 'S6') {
  $d = Join-Path $W 'hw test (1)'; New-Item -ItemType Directory $d -Force | Out-Null
  foreach ($x in 'go.cmd', 'go.ps1', 'fallback.cmd', 'PROMPT.md', 'packs.json') { Copy-Item "$KIT\$x" $d -ErrorAction SilentlyContinue }
  foreach ($x in 'lib', 'stress') { Copy-Item "$KIT\$x" $d -Recurse }
  $o = Join-Path $W 's6 out (x)'
  $out = Cmd "`"$d\go.cmd`" -Auto -Use all -OutRoot `"$o`""
  Result 'S6' 'path with spaces and ( )' ([bool](Report-In $o)) ($(if (Report-In $o) { 'report written' } else { ($out -split "`n" | Select-Object -Last 3) -join ' ' }))
}

# S7 first report folder not writable -> next folder
if (Want 'S7') {
  $bad = Join-Path $env:windir 'System32\hw-cannot-write-here'
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -OutRoot $bad *>&1 | Out-String)
  $m = [regex]::Match($out, 'Report saved: (.+?)\\REPORT\.md')
  $ok = $m.Success -and ($m.Groups[1].Value -notlike "$bad*") -and (Test-Path ($m.Groups[1].Value + '\REPORT.md'))
  Result 'S7' 'unwritable report folder -> next folder' $ok ($(if ($m.Success) { 'saved to ' + $m.Groups[1].Value } else { 'not saved' }))
  if ($ok) { Remove-Item $m.Groups[1].Value -Recurse -Force -ErrorAction SilentlyContinue }
}

# S8 collector hangs (broken WMI) -> partial results, INCOMPLETE
if (Want 'S8') {
  $o = Join-Path $W 's8'
  $env:HW_COLLECT_LIMIT = '4'
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -OutRoot $o *>&1 | Out-String)
  Remove-Item Env:\HW_COLLECT_LIMIT
  $r = Report-In $o
  $txt = if ($r) { Get-Content -Raw $r } else { '' }
  Result 'S8' 'collector times out -> partial report' ([bool]$r -and $txt -match 'stopped early|stopped after section') ($(if ($txt -match 'stopped after section (\S+)') { 'partial, last section ' + $Matches[1] } else { 'no partial marker' }))
}

# S9 download mode: one-liner bootstrap + pack download with checksum
$srv = $null
if ((Want 'S9') -or (Want 'S10') -or (Want 'S11') -or (Want 'S18')) {
  $www = Join-Path $W 'www'; New-Item -ItemType Directory $www -Force | Out-Null
  & python -c "import os,zipfile,sys;k=sys.argv[1];z=zipfile.ZipFile(sys.argv[2],'w',zipfile.ZIP_DEFLATED)
for d,ds,fs in os.walk(k):
  ds[:]=[x for x in ds if x not in ('.git','assets','dist','reports','__pycache__')]
  for f in fs:
    p=os.path.join(d,f); z.write(p,'hw-main/'+os.path.relpath(p,k).replace(os.sep,'/'))
z.close()" $KIT (Join-Path $www 'hw-main.zip')
  Copy-Item "$KIT\dist\win-ffmpeg.zip", "$KIT\dist\win-smartctl.zip" $www
  $srv = Start-Process python -ArgumentList "-m http.server 8765 --bind 127.0.0.1 --directory `"$www`"" -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 2
}
if (Want 'S9') {
  $env:HW_BOOT_DIR = Join-Path $W 'boot-s9'
  Remove-Item (Join-Path $env:TEMP 'hw-kit') -Recurse -Force -ErrorAction SilentlyContinue
  $o = Join-Path $W 's9'
  $env:HW_ZIP_URL = 'http://127.0.0.1:8765/hw-main.zip'; $env:HW_ASSET_BASE = 'http://127.0.0.1:8765/'
  $env:HW_BOOT_ARGS = "-Auto -Use all -Tests render -OutRoot $o"
  $out = (powershell -NoProfile -Command "Get-Content -Raw '$KIT\go.ps1' | Invoke-Expression" *>&1 | Out-String)
  $j = Get-ChildItem $o -Recurse -Filter raw.json -ErrorAction SilentlyContinue | Select-Object -First 1
  $rend = if ($j) { (Get-Content -Raw $j.FullName | ConvertFrom-Json).bench.render.status } else { '' }
  Result 'S9' 'one-liner: download kit + ffmpeg pack' ($rend -eq 'done' -and $out -match 'downloading win-ffmpeg') ("render test: $rend")
}
if (Want 'S10') {
  $env:HW_BOOT_DIR = Join-Path $W 'boot-s10'
  # tampered pack: packs.json says a different hash
  Remove-Item (Join-Path $env:TEMP 'hw-kit') -Recurse -Force -ErrorAction SilentlyContinue
  $o = Join-Path $W 's10'
  $env:HW_ZIP_URL = 'http://127.0.0.1:8765/hw-main.zip'; $env:HW_ASSET_BASE = 'http://127.0.0.1:8765/'
  $env:HW_BOOT_ARGS = "-Auto -Use all -Tests render -OutRoot $o"
  $pj = Get-Content -Raw "$KIT\packs.json"
  $zt = Join-Path $W 'www\hw-main-tampered.zip'
  & python -c "import json,sys,zipfile;m=json.load(open(sys.argv[1]));m['win-ffmpeg']['sha256']='0'*64
src=zipfile.ZipFile(sys.argv[2]);dst=zipfile.ZipFile(sys.argv[3],'w',zipfile.ZIP_DEFLATED)
for i in src.infolist():
  dst.writestr(i, json.dumps(m) if i.filename=='hw-main/packs.json' else src.read(i))
dst.close()" "$KIT\packs.json" (Join-Path $www 'hw-main.zip') $zt
  $env:HW_ZIP_URL = 'http://127.0.0.1:8765/hw-main-tampered.zip'
  $out = (powershell -NoProfile -Command "Get-Content -Raw '$KIT\go.ps1' | Invoke-Expression" *>&1 | Out-String)
  $j = Get-ChildItem $o -Recurse -Filter raw.json -ErrorAction SilentlyContinue | Select-Object -First 1
  $rend = if ($j) { (Get-Content -Raw $j.FullName | ConvertFrom-Json).bench.render.status } else { '' }
  Result 'S10' 'tampered download is refused' ($out -match 'failed its checksum' -and $rend -eq 'skipped') ("render: $rend")
}
if (Want 'S11') {
  $env:HW_BOOT_DIR = Join-Path $W 'boot-s11'
  # no internet for packs: asset server gone
  Remove-Item (Join-Path $env:TEMP 'hw-kit') -Recurse -Force -ErrorAction SilentlyContinue
  $o = Join-Path $W 's11'
  $env:HW_ZIP_URL = 'http://127.0.0.1:8765/hw-main.zip'; $env:HW_ASSET_BASE = 'http://127.0.0.1:1/'
  $env:HW_BOOT_ARGS = "-Auto -Use all -Tests render -OutRoot $o"
  $out = (powershell -NoProfile -Command "Get-Content -Raw '$KIT\go.ps1' | Invoke-Expression" *>&1 | Out-String)
  $j = Get-ChildItem $o -Recurse -Filter raw.json -ErrorAction SilentlyContinue | Select-Object -First 1
  $rend = if ($j) { (Get-Content -Raw $j.FullName | ConvertFrom-Json).bench.render.status } else { '' }
  Result 'S11' 'pack download fails -> test skipped, report still made' ([bool]$j -and $rend -eq 'skipped') ("render: $rend")
}
if (Want 'S18') {
  $env:HW_BOOT_DIR = Join-Path $W 'boot-s18'
  # one-liner on a PC whose policy blocks .ps1 files -> bootstrap runs the kit from memory
  Remove-Item (Join-Path $env:TEMP 'hw-kit') -Recurse -Force -ErrorAction SilentlyContinue
  $o = Join-Path $W 's18'
  $env:HW_ZIP_URL = 'http://127.0.0.1:8765/hw-main.zip'; $env:HW_ASSET_BASE = 'http://127.0.0.1:1/'
  $env:HW_BOOT_ARGS = "-Auto -Use all -OutRoot $o"; $env:HW_TEST_POLICY = 'AllSigned'
  $out = (powershell -NoProfile -ExecutionPolicy AllSigned -Command "Get-Content -Raw '$KIT\go.ps1' | Invoke-Expression" *>&1 | Out-String)
  Remove-Item Env:\HW_TEST_POLICY
  Result 'S18' 'one-liner + policy blocks files -> runs from memory' ([bool](Report-In $o) -and $out -match 'from memory') ($(if (Report-In $o) { 'report written' } else { 'no report' }))
}
if ($srv) { try { Stop-Process -Id $srv.Id -Force } catch {} }
Remove-Item Env:\HW_ZIP_URL, Env:\HW_ASSET_BASE, Env:\HW_BOOT_ARGS, Env:\HW_BOOT_DIR -ErrorAction SilentlyContinue
if ((Want 'S12')) {
  # whole kit download fails -> clear message, nothing else
  $env:HW_ZIP_URL = 'http://127.0.0.1:1/none.zip'
  $out = (powershell -NoProfile -Command "Get-Content -Raw '$KIT\go.ps1' | Invoke-Expression" *>&1 | Out-String)
  Remove-Item Env:\HW_ZIP_URL
  Result 'S12' 'one-liner with no internet -> use the USB' ($out -match 'Use the USB stick') 'clear message'
}

# S13 window closed mid CPU test -> next run kills leftovers, restores power settings, notes it
if (Want 'S13') {
  . "$KIT\lib\common.ps1"; . "$KIT\lib\bench.ps1"
  $before = "$(Ac-Index 'SUB_SLEEP' 'STANDBYIDLE')/$(Ac-Index 'SUB_VIDEO' 'VIDEOIDLE')"
  $o = Join-Path $W 's13'
  $p = Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$KIT\go.ps1`" -Auto -Use all -Tests cpu -OutRoot `"$o`"" -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 50
  Stop-Process -Id $p.Id -Force
  Start-Sleep -Seconds 2
  $orph = @(Get-Process ffmpeg -ErrorAction SilentlyContinue).Count
  $mid = "$(Ac-Index 'SUB_SLEEP' 'STANDBYIDLE')/$(Ac-Index 'SUB_VIDEO' 'VIDEOIDLE')"
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -OutRoot $o *>&1 | Out-String)
  $after = "$(Ac-Index 'SUB_SLEEP' 'STANDBYIDLE')/$(Ac-Index 'SUB_VIDEO' 'VIDEOIDLE')"
  $left = @(Get-Process ffmpeg -ErrorAction SilentlyContinue).Count
  $ok = ($orph -ge 1) -and ($left -eq 0) -and ($after -eq $before) -and ($out -match 'stopped during the cpu test')
  Result 'S13' 'window killed mid CPU test -> cleanup on next run' $ok "orphans $orph -> $left; power before $before, during $mid, after $after"
}

# S14 first browser broken -> next browser
if (Want 'S14') {
  $o = Join-Path $W 's14'
  $env:HW_TEST_BROWSER1 = "$env:windir\System32\where.exe"
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -Tests gpu -Quick -OutRoot $o *>&1 | Out-String)
  Remove-Item Env:\HW_TEST_BROWSER1
  $j = Get-ChildItem $o -Recurse -Filter raw.json -ErrorAction SilentlyContinue | Select-Object -First 1
  $g = if ($j) { (Get-Content -Raw $j.FullName | ConvertFrom-Json).bench.gpu } else { $null }
  Result 'S14' 'first browser fails -> next browser' ($out -match 'trying the next browser' -and $g.status -eq 'done') ("gpu: $($g.status) on $($g.renderer)")
}

# S15 previous run crashed (reboot during GPU test, on AC) -> RED
if (Want 'S15') {
  $d = "$env:LOCALAPPDATA\hw-kit"; New-Item -ItemType Directory $d -Force | Out-Null
  $uuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID; $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  @{ uuid = $uuid; test = 'gpu'; ts = $boot.AddMinutes(-3).ToString('s'); report = 'x'; ac = 'on AC' } | ConvertTo-Json | Set-Content "$d\heartbeat.json" -Encoding ascii
  $o = Join-Path $W 's15'
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -OutRoot $o *>&1 | Out-String)
  $txt = Get-Content -Raw (Report-In $o)
  Result 'S15' 'crash during GPU test -> RED next run' ($txt -match '\[RED\] \(test:gpu\)') 'reported'
  # S16 same but on battery -> AMBER, not RED
  @{ uuid = $uuid; test = 'cpu'; ts = $boot.AddMinutes(-3).ToString('s'); report = 'x'; ac = 'on battery' } | ConvertTo-Json | Set-Content "$d\heartbeat.json" -Encoding ascii
  $o = Join-Path $W 's16'
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -OutRoot $o *>&1 | Out-String)
  $txt = Get-Content -Raw (Report-In $o)
  Result 'S16' 'switched off on battery -> AMBER, not RED' ($txt -match '\[AMBER\] \(test:cpu\)' -and $out -match 'ON BATTERY') 'reported as battery'
}

# S17 asset on the stick altered -> refused
if (Want 'S17') {
  $man = "$KIT\assets\MANIFEST.txt"; $bak = "$man.bak"
  Copy-Item $man $bak -Force
  (Get-Content $man) -replace '^[0-9a-f]{64}(  win/ffmpeg/ffmpeg.exe)$', ('0' * 64 + '$1') | Set-Content $man -Encoding ascii
  $o = Join-Path $W 's17'
  $out = (powershell -NoProfile -ExecutionPolicy Bypass -File "$KIT\go.ps1" -Auto -Use all -Tests render -OutRoot $o *>&1 | Out-String)
  Move-Item $bak $man -Force
  Result 'S17' 'altered ffmpeg.exe on the stick -> not run' ($out -match 'does not match its checksum') 'refused'
}

Write-Host ''
$results | Format-Table -AutoSize | Out-String -Width 220 | Write-Host
$fail = @($results | Where-Object { $_.ok -eq 'FAIL' }).Count
Write-Host ("{0} scenarios, {1} failed. Work folder: {2}" -f $results.Count, $fail, $W)
exit $fail
