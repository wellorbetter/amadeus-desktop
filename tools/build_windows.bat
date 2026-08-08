@echo off
rem ============================================================
rem TimePet Windows 构建脚本（本机专用）
rem
rem 背景：本机 Windows SDK 10.0.22621.0 安装不完整
rem   （Include 缺 ucrt、Lib 只有 um），而 VsDevCmd / Flutter
rem    会自动选中它，导致 cl 编译报 fatal error C1083:
rem    "assert.h"/"cassert" No such file or directory。
rem 解决：手动指定完整的 10.0.19041.0 SDK 头文件/库目录。
rem ============================================================
set INCLUDE=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC\14.29.30133\include;C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\ucrt;C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\shared;C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\um;C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\winrt;C:\Program Files (x86)\Windows Kits\10\Include\10.0.19041.0\cppwinrt
set LIB=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC\14.29.30133\lib\x64;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.19041.0\ucrt\x64;C:\Program Files (x86)\Windows Kits\10\Lib\10.0.19041.0\um\x64
set PATH=C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC\14.29.30133\bin\Hostx64\x64;C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64;%PATH%

cd /d %~dp0..
D:\flutter\bin\flutter.bat build windows --release
echo.
echo 产物：build\windows\x64\runner\timepet.exe（WebView2Loader.dll 已由构建自动复制）