#!/bin/bash
# Compila, firma, notariza y empaqueta Vigía para repartirla a otra gente.
#
#   ./release.sh 1.0.1              compila, notariza y deja el .dmg listo
#   ./release.sh 1.0.1 --publish    además lo sube como release de GitHub
#
# Requiere dos cosas que solo se hacen una vez; el script avisa si faltan:
#
#   1. Un certificado "Developer ID Application". Es OTRO distinto del
#      "Apple Distribution" que sirve para la App Store: aquel no vale para
#      repartir fuera de ella. Se crea en Xcode → Settings → Accounts →
#      Manage Certificates → + → Developer ID Application.
#
#   2. Las credenciales de notarización guardadas en el llavero:
#
#      xcrun notarytool store-credentials "vigia-notary" \
#        --apple-id TU_APPLE_ID --team-id MS4534M938 \
#        --password CONTRASEÑA_ESPECIFICA_DE_APP
#
#      La contraseña específica se genera en appleid.apple.com, no es la de
#      tu cuenta. Se guarda en el llavero: no vuelve a hacer falta.
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EQUIPO="MS4534M938"
PERFIL_NOTARIA="vigia-notary"
IDENTIDAD="Developer ID Application"
REPO="jpcruz88/vigia-monitor"

VERSION="${1:-}"
PUBLICAR="${2:-}"

if [ -z "$VERSION" ]; then
  echo "Falta la versión.  Uso:  ./release.sh 1.0.1 [--publish]" >&2
  exit 1
fi

# ---------------------------------------------------------------- requisitos

echo "==> Comprobando requisitos"

# Se comprueba ANTES de compilar. Descubrir que falta el certificado después
# de cinco minutos de compilación y notarización es tiempo tirado.
if ! security find-identity -v -p codesigning | grep -q "$IDENTIDAD"; then
  cat >&2 <<'FALTA'
No hay ningún certificado "Developer ID Application" en el llavero.

Es el único que sirve para repartir la app fuera de la App Store. El
"Apple Distribution" que quizá ya tengas NO vale para esto: sirve para
subir a la tienda, no para descarga directa.

Créalo en Xcode:
  Settings → Accounts → (tu cuenta) → Manage Certificates → + →
  Developer ID Application

Y vuelve a lanzar este script.
FALTA
  exit 1
fi

if ! xcrun notarytool history --keychain-profile "$PERFIL_NOTARIA" >/dev/null 2>&1; then
  cat >&2 <<FALTA
No están guardadas las credenciales de notarización ("$PERFIL_NOTARIA").

Genera una contraseña específica de app en appleid.apple.com (no es la
contraseña de tu cuenta) y guárdala una sola vez:

  xcrun notarytool store-credentials "$PERFIL_NOTARIA" \\
    --apple-id TU_APPLE_ID --team-id $EQUIPO --password LA_CONTRASEÑA

Y vuelve a lanzar este script.
FALTA
  exit 1
fi

echo "    certificado y credenciales en su sitio"

# ------------------------------------------------------------------ pruebas

echo
echo "==> Pruebas"
cd "$RAIZ"
swift test

# ---------------------------------------------------------------- compilar

echo
echo "==> Compilando $VERSION firmada para distribución"
cd "$RAIZ/App"
xcodegen generate

SALIDA="$RAIZ/release"
rm -rf "$SALIDA"
mkdir -p "$SALIDA"

# Firma manual y explícita. Con firma automática, Xcode busca un perfil de
# aprovisionamiento que una app de Developer ID no necesita, y falla.
# --timestamp es obligatorio para notarizar: sin sello de tiempo, Apple
# rechaza el envío.
xcodebuild -project Vigia.xcodeproj -scheme Vigia \
  -configuration Release -derivedDataPath build \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTIDAD" \
  DEVELOPMENT_TEAM="$EQUIPO" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  build | grep -E "error:|BUILD" || true

APP="$RAIZ/App/build/Build/Products/Release/Vigia.app"
[ -d "$APP" ] || { echo "La compilación no produjo la app." >&2; exit 1; }

echo
echo "==> Verificando la firma"
codesign --verify --strict --deep --verbose=1 "$APP"
# El tiempo de ejecución reforzado es requisito de notarización, y es fácil
# perderlo sin darse cuenta al tocar los ajustes de compilación.
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" \
  || { echo "La app no tiene el tiempo de ejecución reforzado." >&2; exit 1; }

# --------------------------------------------------------------------- dmg

echo
echo "==> Empaquetando el .dmg"
ESCENARIO="$SALIDA/escenario"
mkdir -p "$ESCENARIO"
cp -R "$APP" "$ESCENARIO/"
# El enlace a /Applications es lo que convierte el .dmg en "arrastra el icono
# aquí": sin él, el usuario tiene que saber dónde copiarla.
ln -s /Applications "$ESCENARIO/Applications"

DMG="$SALIDA/Vigia-$VERSION.dmg"
hdiutil create -volname "Vigía" -srcfolder "$ESCENARIO" \
  -ov -format UDZO "$DMG" >/dev/null
rm -rf "$ESCENARIO"

# El .dmg se firma también: si no, macOS avisa al montarlo aunque la app de
# dentro esté impecable.
codesign --force --sign "$IDENTIDAD" --timestamp "$DMG"

# --------------------------------------------------------------- notarizar

echo
echo "==> Notarizando (Apple tarda unos minutos)"
# --wait bloquea hasta el veredicto. Sin esto habría que sondear a mano, y
# graparíamos un paquete que quizá no está aprobado.
xcrun notarytool submit "$DMG" \
  --keychain-profile "$PERFIL_NOTARIA" --wait

echo
echo "==> Grapando el resultado"
# Grapar mete el comprobante dentro del propio .dmg, para que Gatekeeper lo
# acepte aunque el usuario lo abra sin conexión.
xcrun stapler staple "$DMG"

echo
echo "==> Comprobación final, como la haría el Mac de otra persona"
spctl --assess --type open --context context:primary-signature -v "$DMG"

# --------------------------------------------------------------- publicar

if [ "$PUBLICAR" = "--publish" ]; then
  echo
  echo "==> Publicando en GitHub Releases"
  gh release create "v$VERSION" "$DMG" \
    --repo "$REPO" \
    --title "Vigía $VERSION" \
    --notes "Descarga el .dmg, ábrelo y arrastra Vigía a Aplicaciones."
  echo
  echo "Enlace permanente a la última versión, para poner en jpsoftware.dev:"
  echo "  https://github.com/$REPO/releases/latest/download/Vigia-$VERSION.dmg"
fi

echo
echo "Listo:  $DMG"
[ "$PUBLICAR" = "--publish" ] || echo "Para subirlo:  ./release.sh $VERSION --publish"
