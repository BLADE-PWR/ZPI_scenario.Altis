@echo off
rem Build zpi_telemetry_x64.dll with the MSVC build tools.
rem
rem   extension\build.bat                     build next to the source
rem   extension\build.bat "D:\Steam\steamapps\common\Arma 3"   build and install
rem
rem /MT links the runtime statically, so the DLL needs no redistributable on
rem whatever machine the game runs on.
rem
rem Set ZPI_VCVARS to a vcvars64.bat if the probing below does not find yours.
rem
rem A "vswhere.exe is not recognized" line during the build comes from Microsoft's
rem own vcvars64.bat, not from here. It is harmless: the compile still runs.

rem Delayed expansion throughout: the parentheses in ProgramFiles(x86) close an
rem "if (" or "for (" clause early when the line is parsed, so every path that
rem may contain them is read as !var! at run time instead.
setlocal enabledelayedexpansion
set "HERE=%~dp0"
set "NAME=zpi_telemetry_x64"

rem Already in a Developer Command Prompt? Then the tools are on PATH.
where cl >nul 2>nul && goto :compile

set "PF=%ProgramFiles%"
set "PF86=%ProgramFiles(x86)%"
set "TAIL=VC\Auxiliary\Build\vcvars64.bat"
set "VCVARS=%ZPI_VCVARS%"

for %%y in (2022 2019 2017 18) do for %%e in (BuildTools Community Professional Enterprise) do (
    if not defined VCVARS if exist "!PF!\Microsoft Visual Studio\%%y\%%e\!TAIL!" set "VCVARS=!PF!\Microsoft Visual Studio\%%y\%%e\!TAIL!"
    if not defined VCVARS if exist "!PF86!\Microsoft Visual Studio\%%y\%%e\!TAIL!" set "VCVARS=!PF86!\Microsoft Visual Studio\%%y\%%e\!TAIL!"
)

if not defined VCVARS goto :notools
if not exist "!VCVARS!" goto :notools
call "!VCVARS!" >nul || exit /b 1

:compile
pushd "%HERE%"
cl /nologo /std:c++17 /O2 /MT /EHsc /W4 /LD zpi_telemetry.cpp ^
   /Fe:%NAME%.dll /Fo:%NAME%.obj /link /INCREMENTAL:NO
set RC=%ERRORLEVEL%
del /q %NAME%.obj %NAME%.exp %NAME%.lib 2>nul
popd
if not "%RC%"=="0" exit /b %RC%
echo Built %HERE%%NAME%.dll

if "%~1"=="" goto :hint
if not exist "%~1\Arma3_x64.exe" goto :notgame
copy /y "%HERE%%NAME%.dll" "%~1\%NAME%.dll" >nul || exit /b 1
echo Installed to %~1\%NAME%.dll
exit /b 0

:hint
echo.
echo Copy it next to Arma3_x64.exe to install, or pass the game folder:
echo   extension\build.bat "D:\Steam\steamapps\common\Arma 3"
exit /b 0

:notools
echo ERROR: no MSVC x64 build tools found.
echo Install "Desktop development with C++" from the Visual Studio Build Tools,
echo or set ZPI_VCVARS to the full path of your vcvars64.bat.
exit /b 1

:notgame
echo ERROR: "%~1" does not look like the Arma 3 folder ^(no Arma3_x64.exe^).
exit /b 1
