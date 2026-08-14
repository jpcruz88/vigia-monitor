#!/bin/bash
# Recompila Vigía y la reinstala en /Applications.
#
# Por omisión firma ad-hoc, que es lo que permite compilar sin cuenta de
# desarrollador de Apple. Si tienes una, pasar tu equipo evita tener que
# reconceder el permiso de Monitorización de entrada en cada compilación:
#
#   VIGIA_TEAM=XXXXXXXXXX ./rebuild.sh
#
# El identificador del equipo está en developer.apple.com → Membership.
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

# Sin equipo, la firma ad-hoc que trae el proyecto sirve tal cual y no hace
# falta cuenta de Apple.
FIRMA=()
if [ -n "${VIGIA_TEAM:-}" ]; then
  echo "    firmando con el equipo $VIGIA_TEAM"
  FIRMA=(
    CODE_SIGN_STYLE=Automatic
    CODE_SIGN_IDENTITY="Apple Development"
    DEVELOPMENT_TEAM="$VIGIA_TEAM"
  )
fi

xcodebuild -project Vigia.xcodeproj -scheme Vigia \
  -configuration Release -derivedDataPath build "${FIRMA[@]}" build \
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
