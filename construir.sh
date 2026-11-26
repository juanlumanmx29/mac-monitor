#!/bin/bash
# Compila Grigory en modo release y la empaqueta como
# build.noindex/Grigory.app, firmada ad hoc. Solo requiere las Command
# Line Tools (sin Xcode).
set -euo pipefail
cd "$(dirname "$0")"

# La carpeta termina en .noindex para que Spotlight no la indexe: si no, la
# copia de compilación aparece como una segunda app en el lanzador.

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Grigory"

APP="build.noindex/Grigory.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Grigory"
cp Recursos/Info.plist "$APP/Contents/Info.plist"

# Icono: lo dibuja el propio binario (Logo.swift) y iconutil lo empaqueta.
rm -rf build.noindex/icono
"$BIN" --icono build.noindex/icono
iconutil -c icns build.noindex/icono/Grigory.iconset -o "$APP/Contents/Resources/Grigory.icns"
codesign --force --sign - "$APP" >/dev/null

echo "Listo: $(pwd)/$APP"
