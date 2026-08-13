#!/bin/bash
# Recompila Vigía y la reinstala en /Applications.
#
# Se reinstala en la misma ruta a propósito: macOS asocia el permiso de
# Monitoreo de Entrada a la identidad y la ubicación de la app, así que
# moverla obligaría a concederlo otra vez.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DESTINO="/Applications"

echo "==> Pruebas del paquete"
cd "$RAIZ"
swift test

echo
echo "==> Regenerando el proyecto desde project.yml"
cd "$RAIZ/App"
xcodegen generate

echo
echo "==> Compilando"
xcodebuild -project Vigia.xcodeproj -scheme Vigia \
  -configuration Release -derivedDataPath build build \
  | grep -E "error:|warning:|BUILD" || true

APP="$RAIZ/App/build/Build/Products/Release/Vigia.app"
if [ ! -d "$APP" ]; then
  echo "La compilación no produjo la app. Revisa los errores de arriba." >&2
  exit 1
fi

echo
echo "==> Instalando en $DESTINO"
# Cerrar la copia en ejecución antes de reemplazarla.
osascript -e 'quit app "Vigia"' 2>/dev/null || true
sleep 1
rm -rf "$DESTINO/Vigia.app"
cp -R "$APP" "$DESTINO/"
codesign --verify --strict "$DESTINO/Vigia.app"

echo
echo "Listo. Ábrela con:  open -a Vigia"
