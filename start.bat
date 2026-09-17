@echo off
REM Start xmoat. Config comes from xmoat.cfg (and xmoat.local.cfg, which is
REM loaded first and wins); override any key on the command line, e.g.
REM   start.bat LISTEN_PORT=9000
cd /d "%~dp0"
bin\xnet.exe main.lua SERVER_NAME=xmoat %*
