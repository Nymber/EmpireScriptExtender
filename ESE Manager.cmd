@echo off
setlocal
pushd "%~dp0"

:menu
cls
echo.
echo   Empire Script Extender
echo   ======================
echo.
echo   1. Install or repair ESE
echo   2. Check installation
echo   3. Show mods
echo   4. Enable a mod
echo   5. Disable a mod
echo   6. Launch Empire
echo   7. Uninstall ESE
echo   8. Exit
echo.
choice /c 12345678 /n /m "Choose 1-8: "

if errorlevel 8 goto done
if errorlevel 7 goto uninstall
if errorlevel 6 goto launch
if errorlevel 5 goto disable
if errorlevel 4 goto enable
if errorlevel 3 goto mods
if errorlevel 2 goto doctor
if errorlevel 1 goto install

:install
call :run install
goto menu

:doctor
call :run doctor
goto menu

:mods
call :run mods
goto menu

:enable
cls
set /p "modid=Mod id to enable: "
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0empire.ps1" enable "%modid%"
echo.
pause
goto menu

:disable
cls
set /p "modid=Mod id to disable: "
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0empire.ps1" disable "%modid%"
echo.
pause
goto menu

:launch
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0empire.ps1" launch
if errorlevel 1 goto launch_failed
goto done

:launch_failed
echo.
pause
goto menu

:uninstall
cls
echo Uninstall disables ESE but leaves generated packs and user mods alone.
choice /c YN /n /m "Continue? [Y/N]: "
if errorlevel 2 goto menu
call :run uninstall
goto menu

:run
cls
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0empire.ps1" %1
echo.
pause
exit /b

:done
popd
endlocal
