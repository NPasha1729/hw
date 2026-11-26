# hw kit - Phase B load tests. Each returns @{ status; level; summary; negotiate; ... }.
# level: GREEN / AMBER / RED / INCOMPLETE / INFO. Never throws.

function State-Dir { $d = Join-Path $env:LOCALAPPDATA 'hw-kit'; if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }; return $d }

$script:PACKS = @{ 'win\smartctl' = 'win-smartctl'; 'win\ffmpeg' = 'win-ffmpeg'; 'win\llama-vulkan' = 'win-llama-vulkan'; 'win\llama-cpu' = 'win-llama-cpu'; 'model' = 'model' }

function Fetch-Pack([string]$pack, [switch]$Quiet) {
  # Download one asset pack from the GitHub release (download mode only). Returns $true on success.
  $meta = Load-Json (Join-Path $ROOT 'packs.json')
  $info = $null; if ($meta) { $info = $meta.$pack }
  $mb = if ($info) { [math]::Round([double]$info.size / 1MB) } else { '?' }
  if (-not $Quiet -and -not $script:RUNAUTO) {
    $ans = Ask "    This test needs the '$pack' tools ($mb MB download). Download now? (y/n)" 'y'
    if ($ans -ne 'y') { return $false }
  }
  $base = 'https://github.com/NPasha1729/hw/releases/download/v1/'
  if ($env:HW_ASSET_BASE) { $base = $env:HW_ASSET_BASE }
  $zip = Join-Path $env:TEMP ("hw-pack-$pack.zip")
  $dst = $script:ASSETDIR
  try {
    New-Item -ItemType Directory -Path $dst -Force -ErrorAction Stop | Out-Null
    $free = (Get-PSDrive ($env:TEMP.Substring(0, 1))).Free
    if ($info -and $free -lt (3 * [double]$info.size)) { Say "    Not enough free space for $pack." 'Yellow'; return $false }
    Say "    downloading $pack ($mb MB)..." 'DarkGray'
    $ok = $false
    try { Invoke-WebRequest -UseBasicParsing -Uri ($base + $pack + '.zip') -OutFile $zip -ErrorAction Stop; $ok = $true } catch {
      try { & curl.exe -sSfL -o $zip ($base + $pack + '.zip'); if ($LASTEXITCODE -eq 0 -and (Test-Path $zip)) { $ok = $true } } catch {}
    }
    if (-not $ok) { Say "    download of $pack failed (no internet?). Skipping; use the USB stick for this test." 'Yellow'; return $false }
    if ($info -and $info.sha256) {
      $h = (Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower()
      if ($h -ne ([string]$info.sha256).ToLower()) { Say "    $pack failed its checksum (corrupt or tampered download). Skipping." 'Red'; return $false }
    }
    & tar.exe -xf $zip -C $dst 2>$null
    if ($LASTEXITCODE -ne 0) { Expand-Archive -Path $zip -DestinationPath $dst -Force -ErrorAction Stop }
    Get-ChildItem $dst -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
    return $true
  } catch { Say ("    could not install $pack" + ': ' + (Clean $_.Exception.Message 80)) 'Yellow'; return $false }
  finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }
}

function Verify-Asset([string]$path) {
  # Checks an .exe against assets\MANIFEST.txt when it is listed there. Download packs are hash-checked as zips.
  $man = Join-Path $script:ASSETDIR 'MANIFEST.txt'
  if (-not (Test-Path $man)) { return $true }
  if ($path -notmatch '\.exe$') { return $true }
  $rel = $path.Substring($script:ASSETDIR.Length).TrimStart('\').Replace('\', '/')
  $line = Select-String -Path $man -SimpleMatch ('  ' + $rel) -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $line) { return $true }
  $want = ($line.Line -split '\s+')[0]
  return ((Get-FileHash -Algorithm SHA256 $path).Hash.ToLower() -eq $want.ToLower())
}

function Asset([string]$rel, [switch]$Quiet) {
  # Find an asset; fetch its pack if missing (download mode); check its hash; copy to %TEMP% first when on a USB stick.
  $src = Join-Path $script:ASSETDIR $rel
  if (-not (Test-Path $src)) {
    $packKey = @($script:PACKS.Keys | Where-Object { $rel.StartsWith($_) })[0]
    if ($packKey -and (Test-Path (Join-Path $ROOT 'packs.json'))) { [void](Fetch-Pack $script:PACKS[$packKey] -Quiet:$Quiet) }
    if (-not (Test-Path $src)) { return $null }
  }
  if (-not (Verify-Asset $src)) { Say "    $rel does not match its checksum (corrupt or altered stick). Not running it." 'Red'; return $null }
  if ($script:USBROOT -and $src.StartsWith($script:USBROOT)) {
    $relDir = Split-Path $rel -Parent
    $dstDir = Join-Path (Join-Path $env:TEMP 'hw-kit-assets') $relDir
    $dstFile = Join-Path $dstDir (Split-Path $src -Leaf)
    if (-not (Test-Path $dstFile)) {
      Say "  copying $relDir from the USB stick to this PC's temp folder..." 'DarkGray'
      try {
        New-Item -ItemType Directory -Path $dstDir -Force -ErrorAction Stop | Out-Null
        Copy-Item -Path (Join-Path (Split-Path $src -Parent) '*') -Destination $dstDir -Recurse -Force -ErrorAction Stop
      } catch { Say '  copy failed (disk full?); running straight from the stick (slower).' 'Yellow'; return $src }
    }
    return $dstFile
  }
  return $src
}

function Cleanup-Leftovers {
  # A run closed with the X button skips every "finally": kill its children and delete its temp file.
  try {
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.CommandLine -and ($_.CommandLine.Contains('hw-gpu-prof') -or (($_.Name -in @('ffmpeg.exe', 'llama-bench.exe')) -and ($_.ExecutablePath -like '*hw-kit*' -or $_.ExecutablePath -like '*\assets\win\*')))
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  } catch {}
  foreach ($f in @((Join-Path ($env:SystemDrive + '\') 'hw-disktest.bin'), (Join-Path $env:TEMP 'hw-disktest.bin'))) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
}

function Run-Collector([switch]$Elevate, [switch]$NoRedact) {
  # Runs lib\collect.ps1 in a child PowerShell, loaded in memory (policy-proof), with a time limit.
  # Order: elevated (UAC) -> normal. A child that runs out of time still leaves partial results.
  $out = Join-Path $env:TEMP ('hw-raw-' + [guid]::NewGuid().ToString('N') + '.json')
  $lib = Join-Path $ROOT 'lib'
  $nr = if ($NoRedact) { ' -NoRedact' } else { '' }
  $code = "`$ErrorActionPreference='Continue'; `$c = Get-Content -Raw '" + (Join-Path $lib 'collect.ps1') + "'; & ([scriptblock]::Create(`$c)) -Out '" + $out + "' -KitRoot '" + $script:KIT + "' -LibDir '" + $lib + "' -AssetDir '" + $script:ASSETDIR + "'" + $nr
  $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($code))
  $pol = if ($env:HW_TEST_POLICY) { $env:HW_TEST_POLICY } else { 'Bypass' }
  $argl = "-NoProfile -ExecutionPolicy $pol -EncodedCommand $enc"
  $limit = 240
  if ($env:HW_COLLECT_LIMIT) { $limit = [int]$env:HW_COLLECT_LIMIT }
  if ($Elevate -and -not (Is-Admin)) {
    Say '  Disk health needs administrator rights. Windows will now ask; the seller may need to type the password.' 'Yellow'
    Say '  (Say No to continue without it; the report will then be INCOMPLETE.)' 'DarkGray'
    try {
      $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -Verb RunAs -PassThru -WindowStyle Minimized -ErrorAction Stop
      if (-not $p.WaitForExit($limit * 1000)) { try { $p.Kill() } catch {}; Say '  Admin collector took too long; using what it found so far.' 'Yellow' }
    } catch { Say '  Admin declined - continuing without it.' 'Yellow' }
  }
  $first = Load-Json $out
  $R = $first
  if (-not $R -or -not $R.kit.complete) {
    if ($R) { Say '  Admin collector stopped early; reading again without admin to fill the gaps.' 'Yellow' }
    Remove-Item $out -ErrorAction SilentlyContinue
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argl -NoNewWindow -PassThru
    $null = $p.Handle
    if (-not $p.WaitForExit($limit * 1000)) { try { $p.Kill() } catch {}; Say '  Collector took too long (broken WMI?); using what it found so far.' 'Yellow' }
    $R = Load-Json $out
    if (-not $R) { $R = $first }
  }
  Remove-Item $out -ErrorAction SilentlyContinue
  if ($R -and -not $R.kit.complete) { $R.kit | Add-Member -NotePropertyName partial -NotePropertyValue ('stopped after section ' + $R.kit.section) -Force }
  return $R
}

function Run-Proc([string]$exe, [string]$argline, [int]$timeoutSec) {
  # Runs a process with a hard timeout. Returns @{ code; out; err; secs; timeout }
  $o = Join-Path $env:TEMP ('hw-o-' + [guid]::NewGuid().ToString('N') + '.txt')
  $e = Join-Path $env:TEMP ('hw-e-' + [guid]::NewGuid().ToString('N') + '.txt')
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $exe -ArgumentList $argline -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  $null = $p.Handle  # PS 5.1: without this ExitCode stays null
  $done = $p.WaitForExit($timeoutSec * 1000)
  if (-not $done) { try { $p.Kill() } catch {} ; Start-Sleep -Milliseconds 500 }
  $sw.Stop()
  $res = @{ code = $(if ($done) { $p.ExitCode } else { -1 }); out = ''; err = ''; secs = [math]::Round($sw.Elapsed.TotalSeconds, 1); timeout = (-not $done) }
  if (Test-Path $o) { $res.out = Get-Content -Raw $o; Remove-Item $o -ErrorAction SilentlyContinue }
  if (Test-Path $e) { $res.err = Get-Content -Raw $e; Remove-Item $e -ErrorAction SilentlyContinue }
  return $res
}

function Reference { $p = Join-Path $script:KIT 'reference\reference.json'; if (-not (Test-Path $p)) { $p = Join-Path $ROOT 'reference\reference.json' }; return (Load-Json $p) }

# ---------------------------------------------------------------- 1. disk
function Test-Disk([int]$gb = 4) {
  $drive = $env:SystemDrive
  $free = (Get-PSDrive ($drive.TrimEnd(':'))).Free / 1GB
  if ($free -lt ($gb + 2)) { return @{ status = 'skipped'; level = 'INFO'; summary = "only $([math]::Round($free,1)) GB free on $drive (needs $($gb + 2))" } }
  $path = Join-Path ($drive + '\') 'hw-disktest.bin'
  if (-not (Test-Path ($drive + '\') -PathType Container)) { $path = Join-Path $env:TEMP 'hw-disktest.bin' }
  $block = 4MB; $n = [int]($gb * 1GB / $block)
  $buf = New-Object byte[] $block
  (New-Object Random 42).NextBytes($buf)
  try {
    try { $fs = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 1, [IO.FileOptions]::WriteThrough) }
    catch { $path = Join-Path $env:TEMP 'hw-disktest.bin'; $fs = New-Object IO.FileStream($path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, 1, [IO.FileOptions]::WriteThrough) }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    for ($i = 0; $i -lt $n; $i++) { $fs.Write($buf, 0, $block); if ($sw.Elapsed.TotalSeconds -gt 150) { break } }
    $fs.Flush(); $fs.Close(); $sw.Stop()
    $wMB = [math]::Round(($i * 4) / $sw.Elapsed.TotalSeconds)
    $mode = 'uncached'
    try { $rs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None, 1, [IO.FileOptions]0x20000000) ; $null = $rs.Read($buf, 0, $block); $rs.Position = 0 }
    catch { $mode = 'cached (OS may serve from RAM)'; $rs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None, 1, [IO.FileOptions]::SequentialScan) }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $j = 0
    try { while ($rs.Read($buf, 0, $block) -gt 0) { $j++; if ($sw.Elapsed.TotalSeconds -gt 90) { break } } }
    catch { $rs.Close(); $mode = 'cached (OS may serve from RAM)'; $rs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read); $sw.Restart(); $j = 0; while ($rs.Read($buf, 0, $block) -gt 0) { $j++ } }
    $rs.Close(); $sw.Stop()
    $rMB = [math]::Round(($j * 4) / $sw.Elapsed.TotalSeconds)
  } catch {
    return @{ status = 'error'; level = 'INCOMPLETE'; summary = 'disk test failed: ' + (Clean $_.Exception.Message 80) }
  } finally { Remove-Item $path -Force -ErrorAction SilentlyContinue }
  $lvl = 'GREEN'; $why = ''
  if ($rMB -lt 150 -or $wMB -lt 80) { $lvl = 'AMBER'; $why = ' - slow for an SSD (SATA SSD ~450, NVMe 1500+ MB/s)' }
  return @{ status = 'done'; level = $lvl; write_mbs = $wMB; read_mbs = $rMB; read_mode = $mode
    summary = "burst write $wMB MB/s, read $rMB MB/s ($mode, $([math]::Round($i*4/1024,1)) GB)$why" }
}

# ---------------------------------------------------------------- 2. render
function Test-Render {
  $ff = Asset 'win\ffmpeg\ffmpeg.exe'
  if (-not $ff) { return @{ status = 'skipped'; level = 'INFO'; summary = 'ffmpeg not in kit (assets\win\ffmpeg)' } }
  $rr = Run-Proc $ff '-hide_banner -nostats -f lavfi -i testsrc2=s=1920x1080:r=30 -t 20 -c:v libx264 -preset medium -crf 20 -f null -' 180
  if ($rr.timeout) { return @{ status = 'too slow'; level = 'RED'; summary = '1080p x264 encode of 600 frames did not finish in 3 min (<0.1x reference)'; ratio = 0.05 } }
  if ($rr.code -ne 0) { return @{ status = 'error'; level = 'INCOMPLETE'; summary = 'ffmpeg failed: ' + (Clean ($rr.err -split "`n" | Select-Object -Last 1) 100) } }
  $fps = [math]::Round(600 / $rr.secs, 1)
  $ref = Reference
  $ratio = $null
  if ($ref -and $ref.render_secs) { $ratio = [math]::Round([double]$ref.render_secs / $rr.secs, 2) }
  # NVENC probe
  $nv = Run-Proc $ff '-hide_banner -nostats -f lavfi -i testsrc2=s=1920x1080:r=30 -t 2 -c:v h264_nvenc -f null -' 60
  $nvenc = if ($nv.code -eq 0) { 'ok' } elseif ($nv.err -match 'Driver does not support the required nvenc API|minimum required Nvidia driver') { 'present but driver too old' } elseif ($nv.err -match 'No capable devices|Cannot load nvcuda|Cannot load nvEncodeAPI|unsupported device|OpenEncodeSessionEx failed') { 'none' } else { 'none (' + (Clean (@($nv.err -split "`n" | Where-Object { $_ -match 'nvenc|Cannot|Error|error' -and $_ -notmatch 'Conversion failed' }) + 'no detail' | Select-Object -First 1) 70) + ')' }
  $sum = "x264 1080p: $($rr.secs) s for 600 frames ($fps fps)"
  if ($null -ne $ratio) { $sum += ", $($ratio)x the reference" } else { $sum += ' (no reference yet)' }
  $sum += "; NVENC: $nvenc"
  $lvl = 'GREEN'
  if ($null -ne $ratio) { if ($ratio -lt 0.6) { $lvl = 'RED' } elseif ($ratio -lt 0.9) { $lvl = 'AMBER' } }
  return @{ status = 'done'; level = $lvl; secs = $rr.secs; fps = $fps; ratio = $ratio; nvenc = $nvenc; summary = $sum }
}

# ---------------------------------------------------------------- 3. LLM
function Test-LLM($R) {
  $model = Asset 'model\qwen2.5-0.5b-q4km.gguf'
  if (-not $model) { return @{ status = 'skipped'; level = 'INFO'; summary = 'model not in kit (assets\model)' } }
  $results = @()
  foreach ($build in @('llama-vulkan', 'llama-cpu')) {
    $exe = Asset "win\$build\llama-bench.exe"
    if (-not $exe) { continue }
    $ngl = if ($build -eq 'llama-cpu') { 0 } else { 99 }
    $rp = Run-Proc $exe "-m `"$model`" -p 256 -n 64 -r 2 -ngl $ngl -o json" 180
    if ($rp.timeout -or $rp.code -ne 0) { $results += @{ build = $build; ok = $false; err = $(if ($rp.timeout) { 'timeout' } else { Clean (($rp.err -split "`n" | Where-Object { $_ } | Select-Object -Last 1)) 100 }) }; continue }
    try {
      $j = $rp.out | ConvertFrom-Json
      $pp = @($j | Where-Object { $_.n_prompt -gt 0 })[0]; $tg = @($j | Where-Object { $_.n_gen -gt 0 })[0]
      $dev = [string]$pp.gpu_info; $be = [string]$pp.backends
      $results += @{ build = $build; ok = $true; pp = [math]::Round($pp.avg_ts, 1); tg = [math]::Round($tg.avg_ts, 1); backend = $be; device = $dev }
    } catch { $results += @{ build = $build; ok = $false; err = 'could not parse llama-bench output' } }
  }
  if ($results.Count -eq 0) { return @{ status = 'skipped'; level = 'INFO'; summary = 'llama-bench not in kit' } }
  $gpuRun = @($results | Where-Object { $_.ok -and $_.build -eq 'llama-vulkan' -and $_.backend -match 'Vulkan|CUDA|Metal' })[0]
  $vkCpu = @($results | Where-Object { $_.ok -and $_.build -eq 'llama-vulkan' -and $_.backend -notmatch 'Vulkan|CUDA|Metal' })[0]
  $cpuRun = @($results | Where-Object { $_.ok -and $_.build -eq 'llama-cpu' })[0]
  $hasDgpu = [bool]$R.gpu.dgpu
  $problem = $false
  $parts = @()
  if ($gpuRun) { $parts += "GPU (Vulkan, $($gpuRun.device)): $($gpuRun.tg) tok/s generate, $($gpuRun.pp) tok/s prompt" }
  elseif ($vkCpu) { $parts += 'GPU: no Vulkan-capable graphics driver (LLM engine fell back to CPU)'; if ($hasDgpu) { $problem = $true } }
  else { $e = @($results | Where-Object { $_.build -eq 'llama-vulkan' })[0]; if ($e) { $parts += "GPU (Vulkan) failed: $($e.err)" }; if ($hasDgpu) { $problem = $true } }
  if ($cpuRun) { $parts += "CPU: $($cpuRun.tg) tok/s generate, $($cpuRun.pp) tok/s prompt" }
  if ($gpuRun -and $hasDgpu -and ($gpuRun.device -match 'Intel|llvmpipe|Basic|Microsoft')) { $problem = $true; $parts += 'the LLM engine used the integrated GPU, not the graphics card' }
  $ref = Reference
  if ($ref -and $ref.llm_tg -and $gpuRun) { $parts += "($([math]::Round($gpuRun.tg / [double]$ref.llm_tg, 2))x the reference)" }
  $lvl = if ($problem) { 'INCOMPLETE' } else { 'GREEN' }
  return @{ status = 'done'; level = $lvl; backend_problem = $problem; runs = $results; summary = ($parts -join '; ') + ' [0.5B check model; capacity is judged from memory size]' }
}

# ---------------------------------------------------------------- sampling helpers
function Perf-Now { try { return [double](Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'").PercentProcessorPerformance } catch { return $null } }
function Nv-Now([string]$smi) {
  if (-not $smi) { return $null }
  try { $o = (& $smi --query-gpu=temperature.gpu,clocks.sm,power.draw,utilization.gpu --format=csv,noheader,nounits 2>$null) -join ''; return (Clean $o 80) } catch { return $null }
}
function Median($xs) { $a = @($xs | Where-Object { $null -ne $_ } | Sort-Object); if ($a.Count -eq 0) { return $null }; return $a[[int][math]::Floor($a.Count / 2)] }

# ---------------------------------------------------------------- 4. CPU stress
function Test-CPU([int]$seconds = 300) {
  $ff = Asset 'win\ffmpeg\ffmpeg.exe'
  if (-not $ff) { return @{ status = 'skipped'; level = 'INFO'; summary = 'ffmpeg not in kit' } }
  $o = Join-Path $env:TEMP 'hw-cpu-o.txt'; $e = Join-Path $env:TEMP 'hw-cpu-e.txt'
  $p = Start-Process -FilePath $ff -ArgumentList "-hide_banner -nostats -f lavfi -i testsrc2=s=1920x1080:r=30 -t 100000 -c:v libx264 -preset slow -f null -" -NoNewWindow -PassThru -RedirectStandardOutput $o -RedirectStandardError $e
  $null = $p.Handle
  $samples = @(); $t0 = Get-Date
  $null = Perf-Now
  try {
    while (((Get-Date) - $t0).TotalSeconds -lt $seconds) {
      Start-Sleep -Seconds 5
      if ($p.HasExited) { break }
      $v = Perf-Now; if ($null -ne $v) { $samples += $v }
      Heartbeat 'cpu'
      Write-Host ("`r  CPU load {0,4:N0} s / {1} s   clock {2,4:N0}% of rated   " -f ((Get-Date) - $t0).TotalSeconds, $seconds, $v) -NoNewline
    }
  } finally { if (-not $p.HasExited) { try { $p.Kill() } catch {} } ; Write-Host '' ; Remove-Item $o, $e -ErrorAction SilentlyContinue }
  $elapsed = [math]::Round(((Get-Date) - $t0).TotalSeconds)
  if ($p.ExitCode -ne $null -and $elapsed -lt ($seconds - 10) -and $p.HasExited -and $samples.Count -lt 3) { return @{ status = 'error'; level = 'RED'; summary = "load process died after $elapsed s" } }
  $s = @($samples | Select-Object -Skip 1)
  $first = Median (@($s | Select-Object -First 6)); $sustained = Median (@($s | Select-Object -Last ([math]::Max(1, [int]($s.Count / 2)))))
  if ($null -eq $sustained) { return @{ status = 'error'; level = 'INCOMPLETE'; summary = 'no clock samples (performance counter unreadable)' } }
  $lvl = 'GREEN'; $neg = ''
  if ($sustained -lt 50) { $lvl = 'RED'; $neg = 'Heavy throttling: needs cleaning/repaste; ask for that cost off' } elseif ($sustained -lt 70) { $lvl = 'AMBER'; $neg = 'Throttles under load: cleaning/repaste likely needed' }
  return @{ status = 'done'; level = $lvl; seconds = $elapsed; first_pct = $first; sustained_pct = $sustained; samples = $s.Count; negotiate = $neg
    summary = "all-core load $elapsed s: clock $first% of rated at start, $sustained% sustained (below 70% = throttling)" }
}

# ---------------------------------------------------------------- 5. GPU stress
function Find-Browsers {
  # Edge first (always on Windows 10/11), then Chrome, then Brave. Registry App Paths, then default install folders.
  $found = @()
  if ($env:HW_TEST_BROWSER1) { $found += $env:HW_TEST_BROWSER1 }
  foreach ($n in 'msedge.exe', 'chrome.exe', 'brave.exe') {
    foreach ($h in 'HKLM:', 'HKCU:') {
      $p = Get-ItemProperty "$h\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\$n" -ErrorAction SilentlyContinue
      if ($p -and $p.'(default)' -and (Test-Path $p.'(default)')) { $found += $p.'(default)' }
    }
  }
  foreach ($c in "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe") { if (Test-Path $c) { $found += $c } }
  return @($found | Select-Object -Unique)
}
function Find-Browser { $b = @(Find-Browsers); if ($b.Count) { return $b[0] } return $null }

function Test-GPU($R, [int]$seconds = 420) {
  $page = Join-Path $script:KIT 'stress\stress.html'
  if (-not (Test-Path $page)) { return @{ status = 'skipped'; level = 'INFO'; summary = 'stress page missing' } }
  $browsers = @(Find-Browsers)
  if ($browsers.Count -eq 0) { return @{ status = 'skipped'; level = 'INCOMPLETE'; summary = 'no Edge or Chrome found' } }
  $html = Get-Content -Raw $page
  $token = [guid]::NewGuid().ToString('N').Substring(0, 12)
  # Hyper-V/WSL reserve random port blocks, so try several ports in a low range.
  $l = $null; $lastErr = ''
  for ($try = 0; $try -lt 12 -and -not $l; $try++) {
    $port = Get-Random -Minimum 20000 -Maximum 32000
    $cand = New-Object System.Net.HttpListener
    $cand.Prefixes.Add("http://127.0.0.1:$port/")
    try { $cand.Start(); $l = $cand } catch { $lastErr = $_.Exception.Message; try { $cand.Close() } catch {} }
  }
  if (-not $l) { return @{ status = 'error'; level = 'INCOMPLETE'; summary = 'could not open a local port: ' + (Clean $lastErr 80) } }
  $prof = Join-Path $env:TEMP 'hw-gpu-prof'
  $url = "http://127.0.0.1:$port/$token/stress.html?secs=$seconds"
  $smi = $R.gpu.nvidia.path
  $samples = New-Object System.Collections.ArrayList
  $nvs = New-Object System.Collections.ArrayList
  $beats = New-Object System.Collections.ArrayList
  $renderer = ''; $final = $null; $hiddenSecs = 0
  $gk = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
  $used = ''
  $t0 = Get-Date
  try {
    $pending = $l.GetContextAsync()
    foreach ($br in $browsers) {
      # GPU preference: high performance for this browser (undo recorded first)
      $old = $null
      try { if (Test-Path $gk) { $old = (Get-ItemProperty $gk -Name $br -ErrorAction SilentlyContinue).$br } } catch {}
      Undo-Set ('gpu_pref:' + $br) @{ key = $gk; name = $br; old = $old }
      try { if (-not (Test-Path $gk)) { New-Item $gk -Force | Out-Null }; Set-ItemProperty $gk -Name $br -Value 'GpuPreference=2;' } catch {}
      $used = $br
      try { Start-Process -FilePath $br -ArgumentList "--user-data-dir=`"$prof`" --no-first-run --no-default-browser-check --start-fullscreen --disable-gpu-vsync --disable-frame-rate-limit --ignore-gpu-blocklist --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling --disable-features=msEdgeWelcomePage,SigninIntercept,CalculateNativeWinOcclusion `"--app=$url`"" | Out-Null }
      catch { Say "  could not start $(Split-Path $br -Leaf); trying the next browser" 'Yellow'; continue }
      $t0 = Get-Date; $lastNv = Get-Date; $gotAny = $false
      while (((Get-Date) - $t0).TotalSeconds -lt ($seconds + 40)) {
        if ($pending.Wait(1000)) {
          $ctx = $pending.Result; $pending = $l.GetContextAsync()
          $path = $ctx.Request.Url.AbsolutePath
          $resp = $ctx.Response
          if ($path -eq "/$token/stress.html") {
            $bytes = [Text.Encoding]::UTF8.GetBytes($html); $resp.ContentType = 'text/html'; $resp.OutputStream.Write($bytes, 0, $bytes.Length)
          } elseif ($path -eq "/$token/s" -and $ctx.Request.HttpMethod -eq 'POST') {
            $gotAny = $true
            $body = (New-Object IO.StreamReader($ctx.Request.InputStream)).ReadToEnd()
            try { $d = $body | ConvertFrom-Json; if ($d.renderer) { $renderer = Clean $d.renderer 120 }; if ($env:HW_DEBUG) { Add-Content (Join-Path $env:TEMP 'hw-gpu-debug.txt') $body }; if ($d.done) { $final = $d } elseif ($d.beat -or $d.err) { [void]$beats.Add($d) } else { [void]$samples.Add($d) } } catch {}
          } else { $resp.StatusCode = 404 }
          $resp.Close()
          if ($final) { break }
        }
        if (-not $gotAny -and ((Get-Date) - $t0).TotalSeconds -gt 30) { break }   # this browser never loaded the page
        if (((Get-Date) - $lastNv).TotalSeconds -ge 5) {
          $lastNv = Get-Date; $n = Nv-Now $smi; if ($n) { [void]$nvs.Add($n) }; Heartbeat 'gpu'
          $w = if ($samples.Count) { $samples[$samples.Count - 1].work } else { 0 }
          if ($beats.Count -and $beats[$beats.Count - 1].vis -eq 'hidden') { $hiddenSecs += 5; Write-Host "`r  !! Test window is hidden - click on it to bring it back to the front !!          " -ForegroundColor Yellow -NoNewline; continue }
          Write-Host ("`r  GPU load {0,4:N0} s / {1} s   work {2}   {3}   " -f ((Get-Date) - $t0).TotalSeconds, $seconds, $w, $n) -NoNewline
        }
      }
      if ($gotAny) { break }
      Write-Host ''
      Say "  $(Split-Path $br -Leaf) did not open the test page in 30 s; trying the next browser" 'Yellow'
      Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('hw-gpu-prof') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
      Undo-Restore ('gpu_pref:' + $br)
    }
  } finally {
    Write-Host ''
    try { $l.Stop() } catch {}
    Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains('hw-gpu-prof') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    foreach ($br in $browsers) { Undo-Restore ('gpu_pref:' + $br) }
  }
  if ($samples.Count -lt 3) {
    $lb = if ($beats.Count) { $beats[$beats.Count - 1] } else { $null }
    $why = if (-not $lb) { 'page never reported (browser blocked?)' } elseif ($lb.err) { 'page error: ' + (Clean $lb.err 60) } elseif ($lb.lost) { 'GPU context lost (driver reset - a GPU fault sign)' } elseif ($lb.vis -ne 'visible') { 'browser window was hidden' } else { "frames=$($lb.frames) iter=$($lb.iter)" }
    return @{ status = 'error'; level = 'INCOMPLETE'; renderer = $renderer; summary = "GPU test got $($samples.Count) samples: $why; renderer: $renderer; browser: $(Split-Path $used -Leaf)" }
  }
  $works = @($samples | ForEach-Object { [double]$_.work })
  $skip = if ($works.Count -ge 10) { 4 } else { 1 }
  $early = Median (@($works | Select-Object -Skip $skip -First 6))
  $late = Median (@($works | Select-Object -Last 6))
  $drop = if ($early -gt 0) { [math]::Round(100 * (1 - $late / $early)) } else { 0 }
  $wrong = $R.gpu.dgpu -and ($renderer -match 'Intel|SwiftShader|WARP|Basic Render|llvmpipe')
  $lvl = 'GREEN'; $neg = ''
  $sum = "GPU stress $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s on '$renderer': work score $early at start, $late at end ($drop% drop)"
  if ($nvs.Count) { $sum += "; NVIDIA temp,clock,W,util last: $($nvs[$nvs.Count-1])" }
  if ($hiddenSecs -gt 10) { $sum += "; window was hidden ~$hiddenSecs s (result partial)"; if ($lvl -eq 'GREEN') { $lvl = 'INCOMPLETE' } }
  if ($wrong) { $lvl = 'INCOMPLETE'; $sum += ' - ran on the integrated GPU; graphics card not tested' }
  elseif ($drop -gt 25) { $lvl = 'AMBER'; $neg = 'GPU slows down under load (heat): cleaning/repaste' }
  $ref = Reference
  if ($ref -and $ref.gpu_work -and $late) { $sum += ", $([math]::Round($late / [double]$ref.gpu_work, 2))x the reference" }
  return @{ status = 'done'; level = $lvl; renderer = $renderer; work_early = $early; work_late = $late; drop_pct = $drop; samples = $samples.Count; negotiate = $neg; summary = $sum }
}

# ---------------------------------------------------------------- undo + heartbeat + sleep block
function Undo-Set([string]$name, $val) {
  $f = Join-Path (State-Dir) 'undo.json'
  $u = @{}; $j = Load-Json $f; if ($j) { foreach ($p in $j.PSObject.Properties) { $u[$p.Name] = $p.Value } }
  if (-not $u.ContainsKey($name)) { $u[$name] = $val; Save-Json $u $f }
}
function Undo-Restore([string]$only = '') {
  $f = Join-Path (State-Dir) 'undo.json'
  $j = Load-Json $f; if (-not $j) { return }
  $left = @{}
  foreach ($p in $j.PSObject.Properties) {
    if ($only -and $p.Name -ne $only) { $left[$p.Name] = $p.Value; continue }
    $v = $p.Value
    try {
      switch ($p.Name) {
        { $_ -like 'gpu_pref*' } { if ($null -eq $v.old) { Remove-ItemProperty -Path $v.key -Name $v.name -ErrorAction SilentlyContinue } else { Set-ItemProperty -Path $v.key -Name $v.name -Value $v.old } }
        'sleep' { powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE $v.standby_ac | Out-Null; powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE $v.video_ac | Out-Null; powercfg /setactive SCHEME_CURRENT | Out-Null }
      }
    } catch { $left[$p.Name] = $v }
  }
  if ($left.Count) { Save-Json $left $f } else { Remove-Item $f -ErrorAction SilentlyContinue }
}
function Ac-Index([string]$sub, [string]$setting) {
  $t = (powercfg /q SCHEME_CURRENT $sub $setting) -join "`n"
  $m = [regex]::Matches($t, '0x[0-9a-fA-F]{8}')
  if ($m.Count -ge 5) { return [Convert]::ToInt32($m[3].Value, 16) }
  return $null
}
function Block-Sleep {
  $s = Ac-Index 'SUB_SLEEP' 'STANDBYIDLE'; $v = Ac-Index 'SUB_VIDEO' 'VIDEOIDLE'
  if ($null -eq $s -or $null -eq $v) { return $false }
  Undo-Set 'sleep' @{ standby_ac = $s; video_ac = $v }
  powercfg /setacvalueindex SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 0 | Out-Null
  powercfg /setacvalueindex SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 0 | Out-Null
  powercfg /setactive SCHEME_CURRENT | Out-Null
  return $true
}
function Heartbeat([string]$test) {
  $f = Join-Path (State-Dir) 'heartbeat.json'
  $ac = 'unknown'
  try { $bt = Get-CimInstance Win32_Battery -ErrorAction Stop; $ac = if (-not $bt) { 'no battery' } elseif ($bt.BatteryStatus -eq 2) { 'on AC' } else { 'on battery' } } catch {}
  Save-Json @{ uuid = $script:UUID; test = $test; ts = (Get-Date).ToString('s'); report = $script:REPORTDIR; ac = $ac } $f
}
function Check-PreviousCrash {
  # A heartbeat left mid-test plus a boot after it = the machine died during that test.
  $f = Join-Path (State-Dir) 'heartbeat.json'
  $h = Load-Json $f
  if (-not $h -or $h.test -eq 'done') { return $null }
  if ($h.uuid -ne $script:UUID) { Remove-Item $f -ErrorAction SilentlyContinue; return $null }
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  $res = $null
  if ($boot -gt [datetime]$h.ts) { $res = @{ test = $h.test; at = $h.ts; boot = $boot.ToString('s'); report = $h.report; ac = $h.ac } }
  else { $res = @{ test = $h.test; at = $h.ts; boot = 'no reboot'; report = $h.report; note = 'run was closed or killed (no reboot)' } }
  Remove-Item $f -ErrorAction SilentlyContinue
  return $res
}
