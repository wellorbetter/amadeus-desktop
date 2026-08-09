@echo off
setlocal
rem Build with the complete Windows SDK installed on this machine.
set "VS_ROOT=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools"
set "MSVC_ROOT=%VS_ROOT%\VC\Tools\MSVC\14.29.30133"
set "SDK_ROOT=C:\Program Files (x86)\Windows Kits\10"
set "SDK_VER=10.0.19041.0"
set "INCLUDE=%MSVC_ROOT%\include;%SDK_ROOT%\Include\%SDK_VER%\ucrt;%SDK_ROOT%\Include\%SDK_VER%\shared;%SDK_ROOT%\Include\%SDK_VER%\um;%SDK_ROOT%\Include\%SDK_VER%\winrt;%SDK_ROOT%\Include\%SDK_VER%\cppwinrt"
set "LIB=%MSVC_ROOT%\lib\x64;%SDK_ROOT%\Lib\%SDK_VER%\ucrt\x64;%SDK_ROOT%\Lib\%SDK_VER%\um\x64"
set "LIBPATH=%MSVC_ROOT%\lib\x64;%SDK_ROOT%\UnionMetadata;%SDK_ROOT%\References\%SDK_VER%\"
set "PATH=%MSVC_ROOT%\bin\Hostx64\x64;%SDK_ROOT%\bin\%SDK_VER%\x64;%PATH%"

if not exist "%MSVC_ROOT%\bin\Hostx64\x64\cl.exe" goto :missing_msvc
if not exist "%SDK_ROOT%\Include\%SDK_VER%\ucrt\assert.h" goto :missing_sdk

cd /d "%~dp0.."
call D:\flutter\bin\flutter.bat build windows --release
set "BUILD_EXIT=%ERRORLEVEL%"
echo.
echo Output: build\windows\x64\runner\timepet.exe
exit /b %BUILD_EXIT%

:missing_msvc
echo ERROR: MSVC toolchain not found: %MSVC_ROOT%
exit /b 1

:missing_sdk
echo ERROR: Windows SDK not found: %SDK_VER%
exit /b 1
