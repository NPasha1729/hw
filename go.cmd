@echo off
rem hw inspection kit - double-click me.
rem Chain: 1) PowerShell runs go.ps1 as a file  2) if policy blocks files, load it in memory  3) else basic cmd collector.
rem No ( ) blocks on purpose: a path like "D:\hw (1)\" breaks them.
setlocal
set "KIT=%~dp0"
set "KITNS=%KIT:~0,-1%"
set "RUN=%TEMP%\hw-kit-run"
set "FLAG=%TEMP%\hw-started.flag"
echo.
echo  hw inspection kit - starting...

if exist "%KIT%lib\common.ps1" goto havekit
echo.
echo  The kit files are missing next to go.cmd.
echo  If you opened this inside a ZIP file: right-click the ZIP, choose "Extract All", then run go.cmd from the extracted folder.
echo.
pause
goto :eof

:havekit
set "PS=powershell.exe"
if "%HW_TEST_NOPS%"=="1" set "PS=hw-no-such-powershell.exe"
set "POL=Bypass"
if not "%HW_TEST_POLICY%"=="" set "POL=%HW_TEST_POLICY%"

rem copy scripts to this PC's temp folder (safer than running from the stick); fall back to the stick
if exist "%RUN%" rmdir /s /q "%RUN%" >nul 2>&1
mkdir "%RUN%" >nul 2>&1
xcopy /e /i /q /y "%KIT%lib" "%RUN%\lib" >nul 2>&1
xcopy /e /i /q /y "%KIT%stress" "%RUN%\stress" >nul 2>&1
if exist "%KIT%reference" xcopy /e /i /q /y "%KIT%reference" "%RUN%\reference" >nul 2>&1
copy /y "%KIT%go.ps1" "%RUN%\" >nul 2>&1
copy /y "%KIT%fallback.cmd" "%RUN%\" >nul 2>&1
copy /y "%KIT%PROMPT.md" "%RUN%\" >nul 2>&1
if exist "%KIT%packs.json" copy /y "%KIT%packs.json" "%RUN%\" >nul 2>&1
if exist "%RUN%\lib\common.ps1" goto copied
echo  Could not copy the kit to %RUN% - running it from the stick instead.
set "RUN=%KITNS%"
:copied

rem is PowerShell there and new enough (5+)?
"%PS%" -NoProfile -Command "if ($PSVersionTable.PSVersion.Major -lt 5) { exit 3 } else { exit 0 }" >nul 2>&1
if errorlevel 9009 goto nops
if errorlevel 3 goto oldps

rem try 1: normal file run
if exist "%FLAG%" del /q "%FLAG%" >nul 2>&1
"%PS%" -NoProfile -ExecutionPolicy %POL% -File "%RUN%\go.ps1" -KitRoot "%KITNS%" %*
if exist "%FLAG%" goto done

rem try 2: script files are blocked by policy - load go.ps1 into memory instead
echo.
echo  Script files are blocked on this PC. Loading the kit into memory instead...
"%PS%" -NoProfile -ExecutionPolicy %POL% -Command "$env:HW_KIT='%RUN%'; & ([scriptblock]::Create((Get-Content -Raw '%RUN%\go.ps1'))) -KitRoot '%KITNS%' %*"
if exist "%FLAG%" goto done

rem try 3: PowerShell itself is unusable
:nops
echo.
echo  PowerShell could not run here. Running the basic collector instead...
call "%KIT%fallback.cmd"
goto done

:oldps
echo.
echo  This PC has an old PowerShell (Windows 7/8?). Running the basic collector instead...
call "%KIT%fallback.cmd"
goto done

:done
if exist "%FLAG%" del /q "%FLAG%" >nul 2>&1
endlocal
