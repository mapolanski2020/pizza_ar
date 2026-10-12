@echo off
chcp 65001 >nul
title Monte a Pizza - Docker
cd /d "%~dp0"
where docker >nul 2>nul
if errorlevel 1 (
  echo.
  echo  O Docker Desktop nao esta instalado.
  echo  Instale em https://www.docker.com/products/docker-desktop e rode este arquivo de novo.
  start https://www.docker.com/products/docker-desktop
  pause
  exit /b 1
)
docker info >nul 2>nul
if errorlevel 1 (
  echo.
  echo  Abra o Docker Desktop, espere ele ficar pronto e rode este arquivo de novo.
  pause
  exit /b 1
)
set HOST_IP=
for /f "usebackq delims=" %%i in (`powershell -NoProfile -Command "(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.InterfaceAlias -notlike '*vEthernet*' } | Sort-Object { if ($_.IPAddress -like '192.168.*') {0} else {1} } | Select-Object -First 1).IPAddress"`) do set HOST_IP=%%i
if "%HOST_IP%"=="" set HOST_IP=localhost
echo HOST_IP=%HOST_IP%> .env
echo.
echo  Endereco deste computador na rede: %HOST_IP%
echo  Subindo o banco de dados e o servidor (a primeira vez demora alguns minutos)...
echo.
docker compose up -d --build
if errorlevel 1 ( pause & exit /b 1 )
echo.
echo  Aguardando o servidor...
timeout /t 8 /nobreak >nul
docker compose logs app
start "" https://%HOST_IP%:8443/painel.html
echo.
echo  Para desligar: docker compose down     (os dados continuam guardados)
pause
