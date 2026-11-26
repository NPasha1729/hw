# hw SPEC - probe table, thresholds, pinned tools

Every probe in the kit is a row here. Code implements this table; if code and table disagree, the table wins
and the code is the bug. Admin = needs an elevated process. Every probe writes UNKNOWN(<reason>) on failure;
UNKNOWN never counts as a pass.

## 1. Run environment (recorded first, drives what runs)

| Item | Windows source | Fallback | Admin | Field |
|---|---|---|---|---|
| Elevated | `[Security.Principal.WindowsPrincipal]` IsInRole Administrator | `whoami /groups` contains S-1-16-12288 | - | env.admin |
| Language mode | `$ExecutionContext.SessionState.LanguageMode` | - | - | env.langmode |
| Smart App Control | `HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy` VerifiedAndReputablePolicyState (0 off, 1 on, 2 eval) | property absent = "off/not supported" (TESTED absent on Win10) | - | env.sac |
| OS build, edition, SKU | `Win32_OperatingSystem` Caption, BuildNumber, OperatingSystemSKU | `reg query ...\Windows NT\CurrentVersion` | - | os.* |
| On AC | `Win32_Battery.BatteryStatus` (2 = AC) | `powercfg /getactivescheme` + no battery = desktop | - | env.ac |
| Power plan | `powercfg /getactivescheme` (GUID by regex) | - | - | env.plan |
| Locale | `Get-Culture` Name | - | - | env.locale |
| Run mode | `$PSScriptRoot` empty = iex | - | - | env.mode (iex/usb/file) |

## 2. Identity and genuineness

| Item | Windows source | Fallback | Admin | Field | Rule |
|---|---|---|---|---|---|
| Maker, model | `Win32_ComputerSystem` Manufacturer, Model; `Win32_ComputerSystemProduct` Version (Lenovo friendly name) | `reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS` SystemManufacturer, SystemProductName | - | id.maker, id.model | claim mismatch = AMBER |
| Serials (4) | `Win32_ComputerSystemProduct.IdentifyingNumber`, `Win32_BaseBoard.SerialNumber`, `Win32_SystemEnclosure.SerialNumber`, `Win32_BIOS.SerialNumber` | wmic same classes | - | id.serials[] | sticker matches none = RED; generic (`To Be Filled`, `Default string`, `0`, `123456789`, all-same-char) = AMBER |
| UUID | `Win32_ComputerSystemProduct.UUID` | - | - | id.uuid | used for crash/undo matching only, never shown |
| Chassis | `Win32_SystemEnclosure.ChassisTypes` (8,9,10,14,31,32 laptop; 3-7,13,15,16,35 desktop) | battery present = laptop | - | id.chassis | picks laptop/tower checklist |
| BIOS | `Win32_BIOS` SMBIOSBIOSVersion, ReleaseDate, Manufacturer | reg BIOS key | - | id.bios | date = BIOS installed, not manufacture |
| Asset tag | `Win32_SystemEnclosure.SMBIOSAssetTag` | - | - | own.assettag | non-empty and not generic (`No Asset Tag`, `Asset Tag`, `Default string`, spaces - TESTED) = AMBER (ex-corporate) |
| Registered owner/org | `HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion` RegisteredOwner, RegisteredOrganization | - | - | own.regowner (redacted) | org non-empty = AMBER |
| CPU | `Win32_Processor` Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | reg `HARDWARE\DESCRIPTION\System\CentralProcessor\0` ProcessorNameString | - | cpu.* | claim mismatch = RED |
| GPU adapters | `Win32_VideoController` Name, PNPDeviceID (VEN/DEV), DriverVersion, DriverDate | `Get-PnpDevice -Class Display` | - | gpu[] | claim vs PCI VEN/DEV mismatch = RED |
| VRAM | `HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\00NN` HardwareInformation.qwMemorySize (Int64), matched to live adapter by MatchingDeviceId vs PNPDeviceID prefix | HardwareInformation.MemorySize: UInt32 OR Byte[4] little-endian (TESTED: both occur; Intel iGPU gives Byte[] = shared memory, label "shared"), then AdapterRAM (caps 4 GB, label "capped") | - | gpu[].vram_gb | claim mismatch = RED |
| nvidia-smi | search PATH, `C:\Program Files\NVIDIA Corporation\NVSMI\`, `C:\Windows\System32\`, `C:\Windows\System32\DriverStore\FileRepository\nv*\` | - | - | gpu.nvsmi_path | |
| NVIDIA detail | `nvidia-smi --query-gpu=name,memory.total,driver_version,pcie.link.gen.max,pcie.link.width.max,vbios_version --format=csv,noheader` (TESTED: `compute_cap` is rejected by old drivers and kills the whole query, so it is a separate second query; `[Not Supported]` = UNKNOWN) | - | - | gpu.nv.* | |
| RAM per slot | `Win32_PhysicalMemory` BankLabel, DeviceLocator, Capacity, Manufacturer, PartNumber, Speed, ConfiguredClockSpeed, FormFactor | - | - | ram.sticks[] | claim total mismatch = RED |
| RAM array | `Win32_PhysicalMemoryArray` MemoryDevices (slots), MaxCapacityEx (KB) | - | - | ram.slots, ram.max_gb | |
| Channels | count of populated sticks; 1 stick in >=2 slots = single channel | - | - | ram.channel | single channel with free slot = AMBER (ask for a matching stick) |
| Soldered | FormFactor 0/12 (SODIMM=12, DIMM=8); DeviceLocator containing "ONBOARD"/"DIMM 0" heuristics; slots == populated and FormFactor not 8/12 = soldered | - | - | ram.soldered | soldered = capacity ceiling note |
| Licence channel | `Get-CimInstance SoftwareLicensingProduct -Filter "PartialProductKey IS NOT NULL AND ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f'"` ProductKeyChannel, LicenseStatus | `cscript slmgr.vbs /dli` | - | os.lic_channel, os.lic_status | Volume:MAK/GVLK = AMBER ex-corporate; LicenseStatus != 1 = AMBER not activated |
| OEM key | `SoftwareLicensingService.OA3xOriginalProductKey` | - | - | os.oemkey = "present ...XXXXX" | never store full key |
| Edition | os.Caption | - | - | os.edition | Home = no Hyper-V role |

## 3. Locks and ownership

| Item | Source | Admin | Field | Rule |
|---|---|---|---|---|
| Join state | `dsregcmd /status` AzureAdJoined, DomainJoined, EnterpriseJoined | - | own.join | any YES = AMBER; ask for paperwork |
| MDM enrollment | `HKLM\SOFTWARE\Microsoft\Enrollments\*` subkeys with ProviderID (MS DM Server = Intune) | - | own.mdm | Intune present = RED until seller shows release |
| BitLocker | `Get-BitLockerVolume` ProtectionStatus | yes | own.bitlocker | on + seller has no recovery key = RED |
| Remote access | uninstall keys (HKLM + HKCU, 32/64) DisplayName matching AnyDesk, TeamViewer, RustDesk, UltraViewer, Chrome Remote Desktop, ScreenConnect, Splashtop, LogMeIn, Radmin | - | own.remote[] | present = AMBER (remove before use) |
| Startup entries | `Win32_StartupCommand` Name, Command | - | own.startup[] (names only) | listed, not judged |
| Computrace/AMT | uninstall/services matching "Absolute", "rpcnet", "Intel Management Engine" + `Win32_Service` LMS | - | own.persist | Absolute present = AMBER |
| BIOS password | manual (Phase C) | - | manual.biospw | present and seller will not remove = RED |

## 4. Health and wear

| Item | Source | Fallback | Admin | Field | Rule |
|---|---|---|---|---|---|
| Disks | `Get-PhysicalDisk` FriendlyName, MediaType, BusType, Size, HealthStatus | `Win32_DiskDrive` | - | disk[] | HealthStatus != Healthy = RED |
| SMART | `smartctl.exe --scan-open` then `smartctl.exe -a -j <dev>` per device: power_on_time.hours, power_cycle_count, nvme_smart_health_information_log.percentage_used, data_units_written (x512000 bytes), media_errors, critical_warning; ATA: attribute 9, 5, 197, 198, 241/246 | `Get-StorageReliabilityCounter` PowerOnHours, Wear, ReadErrorsTotal | yes | disk[].smart | percentage_used >= 80 = RED, >= 50 = AMBER; media_errors > 0 = RED; critical_warning != 0 = RED; reallocated (5) > 0 = AMBER, > 50 = RED; pending (197) > 0 = RED; all UNKNOWN = INCOMPLETE |
| Battery | `powercfg /batteryreport /xml /output "%TEMP%\hw-batt.xml"` DesignCapacity, FullChargeCapacity, CycleCount | `root\wmi BatteryFullChargedCapacity` + `BatteryStaticData` | - | batt.* | health = Full/Design; < 60% = RED, < 80% = AMBER; CycleCount 0 = UNKNOWN |
| WHEA | `Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WHEA-Logger'}` count, last 90 d | - | - | health.whea | > 0 corrected = AMBER, any fatal (Id 18/20/46) = RED |
| Crashes | System log Id 41 (Kernel-Power) and Id 1001 BugCheck (provider Microsoft-Windows-WER-SystemErrorReporting), both with StartTime = now-90 d | - | - | health.kp41, health.bsod | bsod >= 3 in 90 d = AMBER; kp41 > 5 in 90 d = AMBER (power/battery/heat; dev laptop: 18 with a 24% battery) |
| Disk errors | System log providers disk, Ntfs, stornvme, storahci with Level 2 (Error), last 90 d | - | - | health.diskerr | > 0 = AMBER |

## 5. Manufacture date (a RANGE: lower bound .. upper bound)

| Signal | Source | Bound | Confidence |
|---|---|---|---|
| CPU/model release | claude.ai lookup of cpu.name + id.model | lower | high |
| Internal panel EDID | `Get-CimInstance -Namespace root\wmi WmiMonitorID` (active only) joined on InstanceName with `WmiMonitorConnectionParams.VideoOutputTechnology` in (0x80000000 internal, 11 eDP, 10 DP-embedded) ; YearOfManufacture, WeekOfManufacture (0 = unspecified) | lower (panel can predate, can be replaced) | medium |
| OS install | `Win32_OperatingSystem.InstallDate` | upper (if older than claim, claim is wrong) | high when not reset |
| Previous installs | `HKLM\SYSTEM\Setup\Source OS (Updated on *)` InstallDate (often absent) | upper | high when present |
| HP serial | maker = HP and serial length 10: char 4 = year digit (decade resolved by CPU release), chars 5-6 = week | point | medium |
| Apple | model identifier (e.g. MacBookPro18,1) -> release year via claude.ai; 12-char pre-2021 serial char 4 = half-year code | lower | high / medium |
| Lenovo, Dell, others | none in serial; manual warranty page lookup | - | - |
| Battery date | mac `ioreg -rn AppleSmartBattery` ManufactureDate (packed: day + month*32 + (year-1980)*512) | lower | low (replaced batteries) |
| BIOS date | id.bios.ReleaseDate | none (BIOS updates after manufacture) | - |
Report: `Estimated: 2021-Q2 .. 2022-Q1 (lower: CPU release, panel 2021; upper: OS install 2022-02)`.
Claim older/newer than the range by > 6 months = AMBER, > 18 months = RED.

## 6. Previous users and usage (redacted by default)

| Item | Source | Field | Rule |
|---|---|---|---|
| Local accounts | `Get-LocalUser` where Enabled and SID RID not in 500,501,503,504 (TESTED: built-ins otherwise inflate the count) | prev.accounts[] | names redacted to first letter |
| Profiles | `Win32_UserProfile` where Special = False: LocalPath, Loaded; created = `(Get-Item LocalPath).CreationTime` only if `Test-Path LocalPath` (TESTED: stale profiles point at deleted folders); LastUseTime only if Loaded = False | prev.profiles[] | > 2 real profiles = AMBER |
| Wi-Fi networks | `netsh wlan show profiles` count of "All User Profile" lines (locale: count lines with ':' after the header block) | prev.wifi_count | count only; names only with --no-redact |
| Ghost monitors | `HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\*` minus active internal | prev.monitors[] (maker code + EDID year) | info |
| Windows.old | `Test-Path C:\Windows.old` | prev.winold | info (upgrade history) |
| Usage hours | disk[].smart.power_on_hours, batt.cycles | prev.hours | claim "1 year" vs hours > 8760 x 0.5 heavy = AMBER |

## 7. Fit facts per profile

| Profile | Facts | GREEN | AMBER | RED |
|---|---|---|---|---|
| Render | CPU cores/threads, render ratio, NVENC class | ratio >= 0.9 x reference | 0.6 - 0.9 | < 0.6 |
| Local LLM | VRAM, RAM, unified (mac), channel, max RAM | VRAM >= 8 GB or unified >= 32 GB or RAM >= 32 GB dual-channel | VRAM 6 GB or RAM 16-31 GB | VRAM < 4 GB and RAM < 16 GB |
| Security labs | virt (inferred when HypervisorPresent), edition, RAM, TPM 2.0, SecureBoot | RAM >= 32 GB, virt yes | RAM 16-31 GB | RAM < 16 GB or virt no |
Largest Q4 model that fits ~= (VRAM_GB - 1) / 0.6 billion params on GPU; (RAM_GB - 6) / 0.6 on CPU; label as estimate.
Virtualisation: if `Win32_ComputerSystem.HypervisorPresent` = True -> "yes (inferred, hypervisor running)"; else
`Win32_Processor` VirtualizationFirmwareEnabled and SecondLevelAddressTranslationExtensions. TPM: `Get-Tpm` (admin)
else `Win32_Tpm` namespace root\cimv2\security\microsofttpm (admin). SecureBoot: `Confirm-SecureBootUEFI` (admin).
Wi-Fi chipset: `Get-NetAdapter -Physical` InterfaceDescription (footnote only).
Upgradeability: M.2 / SATA free slots cannot be read from Windows -> manual (Phase C) + claude.ai lookup by model.

## 8. Phase B tests

| Test | Command | Time cap | Verdict |
|---|---|---|---|
| Disk burst | .NET FileStream 4 GB, WriteThrough, 4 MB blocks, on `$env:SystemDrive\hw-disktest.bin`; read back with FileOptions 0x20000000 (NO_BUFFERING) | 3 min | write MB/s and read MB/s; < 300 MB/s read on NVMe = AMBER; SKIP if free < 6 GB |
| Render | `ffmpeg -hide_banner -y -i bench/clip.mp4 -c:v libx264 -preset medium -crf 20 -f null -` timed; NVENC probe `ffmpeg -f lavfi -i testsrc2=s=1920x1080:d=2 -c:v h264_nvenc -f null -` | 3 min | ratio = reference_seconds / seconds; NVENC: ok / "Driver does not support" -> old-driver / "No capable devices" or not NVIDIA -> none |
| LLM | `llama-bench -m model.gguf -p 256 -n 64 -r 2 -o json` (Vulkan build) | 3 min | tokens/s tg + pp; backend field; NVIDIA present and backend CPU = UNKNOWN |
| CPU stress | ffmpeg x264 loop on clip (threads = logical cores), 5 min; sample `Win32_PerfFormattedData_Counters_ProcessorInformation` `_Total` PercentProcessorPerformance every 5 s, drop first | 5 min | sustained median perf% x MaxClockSpeed vs base: < 70% of base = AMBER, < 50% = RED; crash = RED |
| GPU stress | browser on `http://127.0.0.1:<port>/<token>/stress.html`, adaptive shader 7 min; POST every 5 s {fps, work, renderer}; `\GPU Engine(*engtype_3D)\Utilization Percentage`; nvidia-smi temp, clocks.sm, power.draw, clocks_throttle_reasons.active every 5 s | 7 min | renderer contains Intel/SwiftShader/WARP/Basic while dGPU expected = RED (wrong GPU) or UNKNOWN; work rate drop > 25% after minute 2 = AMBER; crash = RED |

## 9. Pinned tools (filled at build time from official release pages; SHA256 verified before every run)

| Tool | Source | Version | File | SHA256 |
|---|---|---|---|---|
| smartctl | smartmontools.org Windows installer, unpacked with 7-Zip | TBD | bin/win/smartctl.exe | TBD |
| ffmpeg (win) | ffmpeg.org -> BtbN builds, lgpl static if available | TBD | render/ffmpeg.exe | TBD |
| llama-bench (win) | github.com/ggml-org/llama.cpp releases, win-vulkan-x64 | TBD | llm/ | TBD |
| llama-bench (mac) | same, macos-arm64 and macos-x64 | TBD | llm-mac/ | TBD |
| model | Qwen2.5-0.5B-Instruct GGUF Q4_K_M (Apache-2.0) from the Qwen org on Hugging Face | TBD | model/qwen0.5b.gguf | TBD |

## 10. Report shape

`reports/hw-<maker>-<model>-<serial-last4>-<yyyymmdd-HHmm>/` (sanitised: [A-Za-z0-9-] only, UNKNOWN if missing, local time)
- `REPORT.md`: PROMPT block, stall summary (<= 25 lines: headline colour, 3 profile lines, top 3 reasons,
  negotiation lines, date range), claims vs facts table (Claim | Measured | Source | Match), red flags, Phase B
  results, Phase C answers, raw facts in a fenced UNTRUSTED DATA block.
- `raw.json`: every field above.
- `heartbeat.json`: {uuid, phase, test, ts}. `undo.json`: original values before any change.
Seller-controlled strings: control chars stripped, capped at 120 chars, only inside fenced blocks.
