# hw kit - Phase A collector (read-only). Can run elevated as a child: collect.ps1 -Out <json> -KitRoot <dir>
# Every probe is isolated; a failure becomes UNKNOWN(reason) and the run continues.
param([string]$Out = '', [string]$KitRoot = '', [switch]$NoRedact, [string]$LibDir = '', [string]$AssetDir = '')

$ErrorActionPreference = 'Stop'
if (-not $LibDir) { $LibDir = $PSScriptRoot }
if (-not $AssetDir) { $AssetDir = Join-Path $KitRoot 'assets' }
# loaded in memory, so it works even when execution policy blocks .ps1 files
. ([scriptblock]::Create((Get-Content -Raw (Join-Path $LibDir 'common.ps1'))))

function Checkpoint($obj, [string]$section) {
  # Save after every section, so a hang or a kill still leaves everything collected so far.
  $obj.kit.section = $section
  if ($Out) { try { Save-Json $obj $Out } catch {} }
}

function Redact([string]$s) {
  if ($NoRedact -or [string]::IsNullOrEmpty($s)) { return $s }
  return ($s.Substring(0, 1) + '***')
}

function Collect-All {
  $R = [ordered]@{}
  $R.kit = [ordered]@{ version = $script:HW_VERSION; collected = (Get-Date).ToString('s'); redacted = (-not $NoRedact); complete = $false; section = 'start' }

  # ---- 1. environment
  $os = Try-Get { Get-CimInstance Win32_OperatingSystem }
  $R.env = [ordered]@{
    admin    = (Is-Admin)
    langmode = [string]$ExecutionContext.SessionState.LanguageMode
    sac      = Try-Get {
      $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction SilentlyContinue
      if ($p -and ($p.PSObject.Properties.Name -contains 'VerifiedAndReputablePolicyState')) {
        @('off', 'on', 'evaluation')[[int]$p.VerifiedAndReputablePolicyState]
      } else { 'off/not supported' }
    }
    locale   = Try-Get { (Get-Culture).Name }
    clock    = Try-Get { (Get-Date).ToString('s') }
    ac       = Try-Get { $b = Get-CimInstance Win32_Battery; if (-not $b) { 'no battery (desktop?)' } elseif ($b.BatteryStatus -eq 2) { 'on AC' } else { 'on battery' } }
    plan     = Try-Get { $t = (powercfg /getactivescheme) -join ' '; $m = [regex]::Match($t, '\(([^)]+)\)'); if ($m.Success) { Clean $m.Groups[1].Value } else { [regex]::Match($t, '[0-9a-fA-F-]{36}').Value } }
  }
  $R.os = [ordered]@{
    caption = Try-Get { Clean $os.Caption }
    build   = Try-Get { [string]$os.BuildNumber }
    sku     = Try-Get { [int]$os.OperatingSystemSKU }
    install = Try-Get { $os.InstallDate.ToString('yyyy-MM-dd') }
    lastboot = Try-Get { $os.LastBootUpTime.ToString('s') }
    home    = Try-Get { [bool]($os.Caption -match 'Home') }
  }

  Checkpoint $R 'environment'
  # ---- 2. identity
  $cs = Try-Get { Get-CimInstance Win32_ComputerSystem }
  $csp = Try-Get { Get-CimInstance Win32_ComputerSystemProduct }
  $enc = Try-Get { Get-CimInstance Win32_SystemEnclosure }
  $bios = Try-Get { Get-CimInstance Win32_BIOS }
  $bb = Try-Get { Get-CimInstance Win32_BaseBoard }
  $id = [ordered]@{}
  $id.maker = Try-Get { Clean $cs.Manufacturer }
  $id.model_code = Try-Get { Clean $cs.Model }
  $id.model = Try-Get {
    $v = Clean $csp.Version
    if ($v -and $v -notmatch '^(None|System Version|To be filled|Default string|\d+(\.\d+)*)$' -and $v.Length -gt 3) { $v } else { Clean $cs.Model }
  }
  if (IsUnk $id.model) { $id.model = Try-Get { Clean (Get-ItemProperty HKLM:\HARDWARE\DESCRIPTION\System\BIOS).SystemProductName } }
  $id.serials = [ordered]@{
    system    = Try-Get { Clean $csp.IdentifyingNumber }
    baseboard = Try-Get { Clean $bb.SerialNumber }
    enclosure = Try-Get { Clean $enc.SerialNumber }
    bios      = Try-Get { Clean $bios.SerialNumber }
  }
  $id.uuid = Try-Get { [string]$csp.UUID }
  $id.chassis_codes = Try-Get { @($enc.ChassisTypes) -join ',' }
  $id.chassis = Try-Get {
    $codes = @($enc.ChassisTypes)
    $lap = @(8, 9, 10, 14, 30, 31, 32)
    $desk = @(3, 4, 5, 6, 7, 13, 15, 16, 35, 36)
    if ($codes | Where-Object { $lap -contains $_ }) { 'laptop' }
    elseif ($codes | Where-Object { $desk -contains $_ }) { 'desktop' }
    elseif (Get-CimInstance Win32_Battery) { 'laptop' } else { 'desktop' }
  }
  $id.bios = [ordered]@{
    version = Try-Get { Clean $bios.SMBIOSBIOSVersion }
    date    = Try-Get { $bios.ReleaseDate.ToString('yyyy-MM-dd') }
    maker   = Try-Get { Clean $bios.Manufacturer }
  }
  $R.id = $id

  Checkpoint $R 'identity'
  # ---- CPU, GPU, RAM
  $cpu = Try-Get { Get-CimInstance Win32_Processor | Select-Object -First 1 }
  $R.cpu = [ordered]@{
    name    = Try-Get { Clean $cpu.Name }
    cores   = Try-Get { [int]$cpu.NumberOfCores }
    threads = Try-Get { [int]$cpu.NumberOfLogicalProcessors }
    max_mhz = Try-Get { [int]$cpu.MaxClockSpeed }
    virt_fw = Try-Get { [bool]$cpu.VirtualizationFirmwareEnabled }
    slat    = Try-Get { [bool]$cpu.SecondLevelAddressTranslationExtensions }
  }

  $vramMap = @{}
  try {
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in (Get-ChildItem $base -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
      $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
      if (-not $p -or -not $p.MatchingDeviceId) { continue }
      $bytes = $null; $kind = 'dedicated'
      $q = $p.'HardwareInformation.qwMemorySize'
      $m = $p.'HardwareInformation.MemorySize'
      if ($null -ne $q) { $bytes = [double]$q }
      elseif ($m -is [byte[]] -and $m.Length -ge 4) { $bytes = [double]([BitConverter]::ToUInt32($m, 0)); $kind = 'shared' }
      elseif ($null -ne $m) { $bytes = [double]$m }
      if ($null -ne $bytes) { $vramMap[[string]$p.MatchingDeviceId.ToUpper()] = @($bytes, $kind) }
    }
  } catch {}

  $gpus = @()
  foreach ($g in @(Try-Get { Get-CimInstance Win32_VideoController })) {
    if (IsUnk $g) { break }
    $pnp = [string]$g.PNPDeviceID
    $ven = ''; $dev = ''
    $mm = [regex]::Match($pnp, 'VEN_([0-9A-F]{4})&DEV_([0-9A-F]{4})')
    if ($mm.Success) { $ven = $mm.Groups[1].Value; $dev = $mm.Groups[2].Value }
    $vendor = switch ($ven) { '10DE' { 'NVIDIA' } '1002' { 'AMD' } '8086' { 'Intel' } '1414' { 'Microsoft (basic)' } default { 'other' } }
    $vram = Unk 'not found'; $vkind = ''
    foreach ($key in $vramMap.Keys) {
      if ($pnp.ToUpper().StartsWith($key)) { $vram = [math]::Round($vramMap[$key][0] / 1GB, 1); $vkind = $vramMap[$key][1]; break }
    }
    if ((IsUnk $vram) -and $g.AdapterRAM) { $vram = [math]::Round([double]$g.AdapterRAM / 1GB, 1); $vkind = 'capped at 4 GB' }
    $gpus += [ordered]@{
      name = Clean $g.Name; vendor = $vendor; ven = $ven; dev = $dev
      driver = Clean $g.DriverVersion; driver_date = Try-Get { $g.DriverDate.ToString('yyyy-MM-dd') }
      vram_gb = $vram; vram_kind = $vkind
    }
  }
  $nv = [ordered]@{ path = $null }
  $smi = Find-NvidiaSmi
  if ($smi) {
    $nv.path = $smi
    $nv.info = Try-Get { Clean ((& $smi --query-gpu=name,memory.total,driver_version,pcie.link.gen.max,pcie.link.width.max,vbios_version --format=csv,noheader 2>&1) -join ' ') 200 }
    $nv.compute_cap = Try-Get { $o = (& $smi --query-gpu=compute_cap --format=csv,noheader 2>&1) -join ' '; if ($o -match 'not a valid') { Unk 'old driver' } else { Clean $o } }
  }
  $R.gpu = [ordered]@{ adapters = $gpus; nvidia = $nv; dgpu = [bool]($gpus | Where-Object { $_.vendor -in @('NVIDIA', 'AMD') -and $_.vram_kind -ne 'shared' }) }

  $sticks = @()
  foreach ($m in @(Try-Get { Get-CimInstance Win32_PhysicalMemory })) {
    if (IsUnk $m) { break }
    $sticks += [ordered]@{
      slot = Clean $m.DeviceLocator; gb = [math]::Round([double]$m.Capacity / 1GB)
      maker = Clean $m.Manufacturer; part = Clean $m.PartNumber
      mhz = [int]$m.Speed; configured_mhz = [int]$m.ConfiguredClockSpeed; form = [int]$m.FormFactor
    }
  }
  $arr = Try-Get { Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1 }
  $slots = Try-Get { [int]$arr.MemoryDevices }
  $total = 0; foreach ($s in $sticks) { $total += $s.gb }
  $ram = [ordered]@{
    total_gb = $total
    usable_gb = Try-Get { [math]::Round([double]$cs.TotalPhysicalMemory / 1GB, 1) }
    sticks = $sticks; slots = $slots
    max_gb = Try-Get { [math]::Round([double]$arr.MaxCapacityEx / 1MB) }
  }
  $n = $sticks.Count
  $ram.channel = if ($n -eq 0) { Unk 'no sticks listed' } elseif ($n -eq 1) { 'single' } else { 'dual or more' }
  $ram.free_slots = if ((IsUnk $slots) -or $slots -lt $n) { Unk 'slot count unreliable' } else { $slots - $n }
  $sodimm = @($sticks | Where-Object { $_.form -in @(8, 12) }).Count
  $ram.soldered = if ($n -gt 0 -and $sodimm -eq 0) { 'likely soldered' } elseif ($sodimm -eq $n) { 'removable sticks' } else { 'mixed' }
  $R.ram = $ram

  Checkpoint $R 'cpu-gpu-ram'
  # ---- licence
  $lic = Try-Get { Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'" | Select-Object -First 1 }
  $R.os.lic_channel = Try-Get { Clean $lic.ProductKeyChannel }
  $R.os.activated = Try-Get { [int]$lic.LicenseStatus -eq 1 }
  $R.os.oem_key = Try-Get { $k = (Get-CimInstance SoftwareLicensingService).OA3xOriginalProductKey; if ($k) { 'present ...' + $k.Substring($k.Length - 5) } else { 'absent' } }

  Checkpoint $R 'licence'
  # ---- 3. locks / ownership
  $own = [ordered]@{}
  $own.asset_tag = Try-Get { $t = Clean $enc.SMBIOSAssetTag; if (-not $t -or $t -match '^(No Asset Tag|Asset Tag.*|Default string|None|To be filled.*|0+)$') { 'none' } else { $t } }
  $own.reg_owner = Try-Get { Redact (Clean (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').RegisteredOwner) }
  $own.reg_org = Try-Get { $o = Clean (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').RegisteredOrganization; if ($o) { $o } else { 'none' } }
  $own.join = Try-Get {
    $t = (dsregcmd /status) -join "`n"
    $j = [ordered]@{}
    foreach ($f in 'AzureAdJoined', 'DomainJoined', 'EnterpriseJoined') { $mm = [regex]::Match($t, "$f\s*:\s*(\w+)"); $j[$f] = if ($mm.Success) { $mm.Groups[1].Value } else { 'UNKNOWN' } }
    $j
  }
  $own.mdm = Try-Get {
    $ids = @(Get-ChildItem HKLM:\SOFTWARE\Microsoft\Enrollments -ErrorAction SilentlyContinue | ForEach-Object { (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).ProviderID } | Where-Object { $_ })
    if ($ids.Count -eq 0) { 'none' } else { ($ids | Sort-Object -Unique | ForEach-Object { Clean $_ }) -join ', ' }
  }
  $own.bitlocker = Try-Get { if (-not (Is-Admin)) { return (Unk 'needs admin') }; [string](Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop 2>$null).ProtectionStatus }
  $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
  $apps = @(Get-ItemProperty $keys -ErrorAction SilentlyContinue | ForEach-Object { $_.DisplayName } | Where-Object { $_ })
  $own.remote_tools = @($apps | Where-Object { $_ -match 'AnyDesk|TeamViewer|RustDesk|UltraViewer|Chrome Remote Desktop|ScreenConnect|Splashtop|LogMeIn|Radmin|Ammyy' } | ForEach-Object { Clean $_ } | Sort-Object -Unique)
  $own.persistence = @($apps | Where-Object { $_ -match 'Absolute|Computrace|LoJack' } | ForEach-Object { Clean $_ } | Sort-Object -Unique)
  $own.startup = Try-Get { @(Get-CimInstance Win32_StartupCommand | ForEach-Object { Clean $_.Name 60 }) }
  $R.own = $own

  Checkpoint $R 'ownership'
  # ---- 4. health
  $disks = @()
  foreach ($d in @(Try-Get { Get-PhysicalDisk })) {
    if (IsUnk $d) { break }
    $disks += [ordered]@{
      name = Clean $d.FriendlyName; media = [string]$d.MediaType; bus = [string]$d.BusType
      gb = [math]::Round([double]$d.Size / 1GB); health = [string]$d.HealthStatus; number = [string]$d.DeviceId
    }
  }
  $smart = @()
  $sc = $null
  foreach ($c in @((Join-Path $AssetDir 'win\smartctl\smartctl.exe'), (Join-Path $KitRoot 'assets\win\smartctl\smartctl.exe'))) { if ($c -and (Test-Path $c)) { $sc = (Resolve-Path $c).Path; break } }
  if (-not $sc) { $smart = Unk 'smartctl not in kit' }
  elseif (-not (Is-Admin)) { $smart = Unk 'needs admin' }
  else {
    foreach ($line in (& $sc --scan-open 2>$null)) {
      $dev = ($line -split '\s+')[0]
      if (-not $dev) { continue }
      try {
        $j = (& $sc -a -j $dev 2>$null) -join "`n" | ConvertFrom-Json
        $s = [ordered]@{ dev = $dev; model = Clean $j.model_name; serial_tail = '' ; passed = $j.smart_status.passed }
        if ($j.serial_number) { $sn = [string]$j.serial_number; $s.serial_tail = $sn.Substring([math]::Max(0, $sn.Length - 4)) }
        $s.power_on_hours = $j.power_on_time.hours
        $s.power_cycles = $j.power_cycle_count
        if ($j.nvme_smart_health_information_log) {
          $h = $j.nvme_smart_health_information_log
          $s.type = 'nvme'; $s.pct_used = $h.percentage_used; $s.media_errors = $h.media_errors
          $s.critical_warning = $h.critical_warning; $s.tb_written = [math]::Round([double]$h.data_units_written * 512000 / 1e12, 1)
        } elseif ($j.ata_smart_attributes) {
          $s.type = 'ata'
          foreach ($a in $j.ata_smart_attributes.table) {
            switch ([int]$a.id) {
              5 { $s.reallocated = $a.raw.value } 197 { $s.pending = $a.raw.value } 198 { $s.uncorrectable = $a.raw.value }
              231 { $s.life_left = $a.value } 241 { $s.lbas_written = $a.raw.value } 9 { if (-not $s.power_on_hours) { $s.power_on_hours = $a.raw.value } }
            }
          }
          if ($s.lbas_written) { $s.written_raw_attr241 = $s.lbas_written; $s.Remove('lbas_written') }  # units are vendor-specific on SATA; not converted
        }
        $smart += $s
      } catch { $smart += [ordered]@{ dev = $dev; error = Clean $_.Exception.Message 80 } }
    }
    if ($smart.Count -eq 0) { $smart = Unk 'no devices (RAID/VMD hides disks?)' }
  }
  if ((IsUnk $smart) -and (Is-Admin)) {
    $rc = Try-Get { @(Get-PhysicalDisk | Get-StorageReliabilityCounter | ForEach-Object { [ordered]@{ power_on_hours = $_.PowerOnHours; wear = $_.Wear; read_errors = $_.ReadErrorsTotal } }) }
    if (-not (IsUnk $rc)) { $smart = @($rc | ForEach-Object { $_.source = 'windows reliability counter'; $_ }) }
  }

  $batt = [ordered]@{ present = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue) }
  if ($batt.present) {
    try {
      $f = Join-Path $env:TEMP ('hw-batt-' + [guid]::NewGuid().ToString('N') + '.xml')
      powercfg /batteryreport /xml /output $f | Out-Null
      [xml]$x = Get-Content -Raw $f
      Remove-Item $f -ErrorAction SilentlyContinue
      $b = @($x.BatteryReport.Batteries.Battery)[0]
      $batt.design_mwh = [int]$b.DesignCapacity
      $batt.full_mwh = [int]$b.FullChargeCapacity
      $batt.cycles = if ([int]$b.CycleCount -gt 0) { [int]$b.CycleCount } else { Unk 'battery does not report cycles' }
      $batt.maker = Clean $b.Manufacturer
      if ($batt.design_mwh -gt 0) { $batt.health_pct = [math]::Round(100 * $batt.full_mwh / $batt.design_mwh) }
    } catch { $batt.error = Clean $_.Exception.Message 80 }
    if (-not $batt.design_mwh) {
      # fallback: WMI battery classes (no powercfg)
      try { $batt.full_mwh = [int](Get-CimInstance -Namespace root\wmi BatteryFullChargedCapacity -ErrorAction Stop | Select-Object -First 1).FullChargedCapacity } catch {}
      try { $batt.design_mwh = [int](Get-CimInstance -Namespace root\wmi BatteryStaticData -ErrorAction Stop | Select-Object -First 1).DesignedCapacity } catch {}
      if ($batt.design_mwh -gt 0 -and $batt.full_mwh -gt 0) { $batt.health_pct = [math]::Round(100 * $batt.full_mwh / $batt.design_mwh); $batt.source = 'wmi' }
    }
  }

  $since = (Get-Date).AddDays(-90)
  function CountEv($h) { try { @(Get-WinEvent -FilterHashtable $h -ErrorAction Stop).Count } catch { if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*' -or $_.Exception.Message -match 'No events') { 0 } else { Unk (Clean $_.Exception.Message 60) } } }
  $health = [ordered]@{
    whea_90d       = CountEv @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
    whea_fatal_90d = CountEv @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; Id = 18, 20, 46; StartTime = $since }
    kp41_90d       = CountEv @{ LogName = 'System'; Id = 41; ProviderName = 'Microsoft-Windows-Kernel-Power'; StartTime = $since }
    bsod_90d       = CountEv @{ LogName = 'System'; Id = 1001; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; StartTime = $since }
    disk_err_90d   = CountEv @{ LogName = 'System'; ProviderName = 'disk', 'Ntfs', 'stornvme', 'storahci'; Level = 2; StartTime = $since }
    log_oldest     = Try-Get { (Get-WinEvent -LogName System -MaxEvents 1 -Oldest).TimeCreated.ToString('yyyy-MM-dd') }
  }
  $R.disk = [ordered]@{ physical = $disks; smart = $smart; system_free_gb = Try-Get { [math]::Round((Get-PSDrive ($env:SystemDrive.TrimEnd(':'))).Free / 1GB, 1) } }
  $R.battery = $batt
  $R.health = $health

  Checkpoint $R 'health'
  # ---- 5. manufacture date signals
  $date = [ordered]@{}
  $date.panel = Try-Get {
    $ids = @(Get-CimInstance -Namespace root\wmi WmiMonitorID)
    $conn = @{}
    foreach ($c in @(Get-CimInstance -Namespace root\wmi WmiMonitorConnectionParams -ErrorAction SilentlyContinue)) { $conn[$c.InstanceName] = [uint32]$c.VideoOutputTechnology }
    $panels = @()
    foreach ($m in $ids) {
      $mk = -join ([char[]]($m.ManufacturerName | Where-Object { $_ -ne 0 }))
      $vot = $conn[$m.InstanceName]
      $internal = ($vot -eq 2147483648) -or ($vot -eq 11) -or ($vot -eq 10)
      $panels += [ordered]@{ maker = Clean $mk; year = [int]$m.YearOfManufacture; week = [int]$m.WeekOfManufacture; internal = $internal }
    }
    ,$panels
  }
  $date.os_install = $R.os.install
  $date.source_os = Try-Get {
    $s = @(Get-ChildItem HKLM:\SYSTEM\Setup -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like 'Source OS*' } | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath; if ($p.InstallDate) { ([datetime]'1970-01-01').AddSeconds([double]$p.InstallDate).ToString('yyyy-MM-dd') } })
    if ($s.Count -eq 0) { 'none recorded' } else { ($s | Sort-Object) -join ', ' }
  }
  $date.bios_date = $id.bios.date
  $date.hp_serial = $null
  if ((-not (IsUnk $id.maker)) -and $id.maker -match '^(HP|Hewlett)') {
    $sn = [string]$id.serials.system
    if ($sn.Length -eq 10 -and $sn.Substring(3, 1) -match '\d' -and $sn.Substring(4, 2) -match '^\d\d$') {
      $date.hp_serial = "year digit $($sn.Substring(3,1)), week $($sn.Substring(4,2)) (decade from CPU generation)"
    }
  }
  $R.date = $date

  Checkpoint $R 'date'
  # ---- 6. previous users
  $prev = [ordered]@{}
  $prev.accounts = Try-Get {
    @(Get-LocalUser | Where-Object { $_.Enabled -and ($_.SID.Value -notmatch '-(500|501|503|504)$') } | ForEach-Object {
        [ordered]@{ name = (Redact (Clean $_.Name)); source = [string]$_.PrincipalSource; last_logon = $(if ($_.LastLogon) { $_.LastLogon.ToString('yyyy-MM-dd') } else { 'never' }) } })
  }
  $prev.profiles = Try-Get {
    @(Get-CimInstance Win32_UserProfile -Filter 'Special=False' | ForEach-Object {
        $it = Get-Item -LiteralPath $_.LocalPath -Force -ErrorAction SilentlyContinue
        if ($it) {
          $lu = if ($_.Loaded) { 'in use now' } elseif ($_.LastUseTime) { $_.LastUseTime.ToString('yyyy-MM-dd') } else { 'unknown' }
          [ordered]@{ name = (Redact (Clean (Split-Path $_.LocalPath -Leaf))); created = $it.CreationTime.ToString('yyyy-MM-dd'); last_use = $lu }
        } })
  }
  $prev.wifi_count = Try-Get { @((netsh wlan show profiles) | Where-Object { $_ -match '^\s{4}\S.*:\s*\S' }).Count }
  $prev.ghost_monitors = Try-Get {
    $active = @($date.panel | ForEach-Object { $_.maker })
    @(Get-ChildItem HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName } | Where-Object { $_ -ne 'Default_Monitor' -and $active -notcontains $_.Substring(0, [math]::Min(3, $_.Length)) })
  }
  $prev.windows_old = Test-Path "$env:SystemDrive\Windows.old"
  $R.prev = $prev

  Checkpoint $R 'previous-users'
  # ---- 7. fit
  $hyp = Try-Get { [bool]$cs.HypervisorPresent }
  $virt = if ($hyp -eq $true) { 'yes (inferred: hypervisor running)' } elseif ($R.cpu.virt_fw -eq $true -and $R.cpu.slat -eq $true) { 'yes' } elseif ($R.cpu.virt_fw -eq $false) { 'disabled in firmware' } else { Unk 'not readable' }
  $R.fit = [ordered]@{
    virtualization = $virt
    tpm = Try-Get { if (-not (Is-Admin)) { return (Unk 'needs admin') }; $t = Get-Tpm; if ($t.TpmPresent) { 'present' + $(if ($t.TpmReady) { ', ready' } else { '' }) } else { 'absent' } }
    secure_boot = Try-Get { [string](Confirm-SecureBootUEFI) }
    nics = Try-Get { @(Get-NetAdapter -Physical | ForEach-Object { Clean $_.InterfaceDescription 80 }) }
  }
  $R.kit.complete = $true
  $R.kit.section = 'done'
  return $R
}

$data = Collect-All
if ($Out) { Save-Json $data $Out } else { $data }
