#!/bin/bash
# Mac / Linux: sobe o banco PostgreSQL e o servidor com Docker
cd "$(dirname "$0")"
command -v docker >/dev/null || { echo "Instale o Docker Desktop: https://www.docker.com/products/docker-desktop"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Abra o Docker Desktop, espere ficar pronto e rode de novo."; exit 1; }
IP=$( (ipconfig getifaddr en0 || ipconfig getifaddr en1 || hostname -I | awk "{print \$1}") 2>/dev/null | head -1)
echo "HOST_IP=${IP:-localhost}" > .env
echo "Endereço deste computador na rede: ${IP:-localhost}"
docker compose up -d --build || exit 1
sleep 8; docker compose logs app
(open "https://${IP:-localhost}:8443/painel.html" || xdg-open "https://${IP:-localhost}:8443/painel.html") >/dev/null 2>&1
echo "Para desligar: docker compose down   (os dados continuam guardados)"
