#!/bin/bash
# Gera o projeto e compila em Release.
#   ./scripts/build.sh            → build/Liland.app
#   ./scripts/build.sh --install  → instala em /Applications e abre (sem deixar cópia em build/)
set -euo pipefail
cd "$(dirname "$0")/.."

# ".noindex" faz o Spotlight ignorar a pasta, para o Launchpad não mostrar outro "Liland".
DERIVED=build/DerivedData.noindex
PRODUCT="$DERIVED/Build/Products/Release/Liland.app"

xcodegen generate --quiet
xcodebuild \
  -project Liland.xcodeproj \
  -scheme Liland \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  -quiet \
  build

rm -rf build/Liland.app

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Liland 2>/dev/null || true
  # Espera a versão antiga fechar de vez antes de abrir a nova.
  for _ in {1..50}; do pgrep -x Liland >/dev/null || break; sleep 0.1; done
  rm -rf /Applications/Liland.app
  cp -R "$PRODUCT" /Applications/Liland.app
  open /Applications/Liland.app
  echo "✓ Instalado em /Applications/Liland.app"
else
  cp -R "$PRODUCT" build/Liland.app
  echo "✓ build/Liland.app"
fi
