#!/bin/bash
# Mac / Linux: dois cliques (Mac) ou ./iniciar.command
cd "$(dirname "$0")"
if ! command -v node >/dev/null 2>&1; then
  echo "O Node.js nao esta instalado. Baixe a versao LTS em https://nodejs.org e rode de novo."
  exit 1
fi
[ -d node_modules ] || npm install --no-audit --no-fund
( sleep 4; (open "https://localhost:8443/painel.html" || xdg-open "https://localhost:8443/painel.html") >/dev/null 2>&1 ) &
node servidor.mjs
