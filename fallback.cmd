@echo off
rem hw - basic collector for machines where PowerShell is blocked or broken. cmd + reg + wmic only.
setlocal
set "OUT=%USERPROFILE%\Desktop\hw-basic-%COMPUTERNAME%.txt"
echo hw BASIC report (PowerShell unavailable - limited facts) > "%OUT%"
echo Collected %DATE% %TIME% >> "%OUT%"
echo. >> "%OUT%"
echo == Try PowerShell CIM first == >> "%OUT%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_ComputerSystem | Format-List Manufacturer,Model,TotalPhysicalMemory; Get-CimInstance Win32_BIOS | Format-List SerialNumber,SMBIOSBIOSVersion,ReleaseDate; Get-CimInstance Win32_Processor | Format-List Name,NumberOfCores; Get-CimInstance Win32_VideoController | Format-List Name,PNPDeviceID; Get-PhysicalDisk | Format-List FriendlyName,MediaType,HealthStatus,Size" >> "%OUT%" 2>&1
echo. >> "%OUT%"
echo == Registry BIOS key == >> "%OUT%"
reg query HKLM\HARDWARE\DESCRIPTION\System\BIOS >> "%OUT%" 2>&1
reg query HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0 /v ProcessorNameString >> "%OUT%" 2>&1
echo. >> "%OUT%"
echo == WMIC (may not exist on Windows 11 24H2+) == >> "%OUT%"
where wmic >nul 2>&1 && (
  wmic bios get serialnumber,smbiosbiosversion,releasedate >> "%OUT%" 2>&1
  wmic csproduct get name,identifyingnumber,vendor >> "%OUT%" 2>&1
  wmic baseboard get product,serialnumber >> "%OUT%" 2>&1
  wmic memorychip get capacity,partnumber,speed,devicelocator >> "%OUT%" 2>&1
  wmic diskdrive get model,size,status >> "%OUT%" 2>&1
) || echo wmic not available - serial numbers may be missing above >> "%OUT%"
echo. >> "%OUT%"
echo == systeminfo == >> "%OUT%"
systeminfo >> "%OUT%" 2>&1
echo. >> "%OUT%"
echo == Battery == >> "%OUT%"
powercfg /batteryreport /output "%TEMP%\hw-batt.html" >nul 2>&1 && echo battery report saved to %TEMP%\hw-batt.html >> "%OUT%"
echo.
echo  Basic report saved to: %OUT%
echo  Manual checks: Settings ^> System ^> About, msinfo32, Task Manager ^> Performance, dxdiag.
echo.
if not "%HW_NOPAUSE%"=="1" pause
endlocal
