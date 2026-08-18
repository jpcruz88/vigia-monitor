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
  -configuration Release -derivedDataPath build ${FIRMA[@]+"${FIRMA[@]}"} build \
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

# Con firma ad-hoc, macOS liga el permiso de Monitorización de entrada al hash
# del binario: tras recompilar, la entrada de Ajustes sigue "activada" pero
# apunta a la app anterior, así que la nueva se ve denegada y —como la entrada
# ya existe— ni siquiera vuelve a pedir el permiso. Borrarla obliga a pedirlo
# de nuevo al abrir. Con equipo propio la firma es estable y esto sobra.
if [ -z "${VIGIA_TEAM:-}" ]; then
  echo
  echo "==> Reiniciando el permiso de Monitorización de entrada (firma ad-hoc)"
  tccutil reset ListenEvent com.jpcruz.vigia >/dev/null 2>&1 || true
  echo "    al abrir Vigía volverá a pedirlo; actívalo y elige 'Reiniciar para medir el mouse'"
fi

echo
# La ruta va explícita: `open -a Vigia` puede resolver a la copia que quedó en
# el directorio de compilación, y esa no tiene el permiso concedido a la
# instalada —TCC lo liga también a la ubicación.
echo "Listo. Ábrela con:  open $DESTINO/Vigia.app"
