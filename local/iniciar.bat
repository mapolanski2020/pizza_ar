@echo off
chcp 65001 >nul
title Monte a Pizza - servidor local
cd /d "%~dp0"
where node >nul 2>nul
if errorlevel 1 (
  echo.
  echo  O Node.js nao esta instalado.
  echo  Baixe e instale a versao LTS em https://nodejs.org e rode este arquivo de novo.
  echo.
  start https://nodejs.org
  pause
  exit /b 1
)
if not exist node_modules (
  echo Instalando, so na primeira vez...
  call npm install --no-audit --no-fund
)
start "" https://localhost:8443/painel.html
node servidor.mjs
pause
