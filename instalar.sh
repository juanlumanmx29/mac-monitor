#!/bin/bash
# Instala Telemetría en la carpeta Aplicaciones. Por defecto no arranca sola:
# se abre cuando la abres. Todo es reversible.
#
#   ./instalar.sh                 compila e instala (sin arranque al iniciar sesión)
#   ./instalar.sh --al-iniciar    además la deja arrancando al iniciar sesión, solo en la barra de menú
#   ./instalar.sh --desinstalar   detiene y borra la app, el arranque automático y las preferencias
set -euo pipefail
cd "$(dirname "$0")"

ETIQUETA="local.telemetria"
AGENTE="$HOME/Library/LaunchAgents/$ETIQUETA.plist"
DOMINIO="gui/$(id -u)"
# /Applications si el usuario puede escribir en ella (administradores); si
# no, la carpeta Aplicaciones personal.
if [ -w /Applications ]; then
    APP_DESTINO="/Applications/Telemetría.app"
else
    APP_DESTINO="$HOME/Applications/Telemetría.app"
fi
BINARIO="$APP_DESTINO/Contents/MacOS/Telemetria"

detener() {
    launchctl bootout "$DOMINIO/$ETIQUETA" 2>/dev/null || true
    # Espera a que launchd termine de soltar el servicio antes de volver a
    # registrarlo; si no, bootstrap falla con "Input/output error".
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "$DOMINIO/$ETIQUETA" >/dev/null 2>&1 || break
        sleep 0.3
    done
    pkill -x Telemetria 2>/dev/null || true
}

if [ "${1:-}" = "--desinstalar" ]; then
    detener
    rm -f "$AGENTE"
    rm -rf "/Applications/Telemetría.app" "$HOME/Applications/Telemetría.app"
    defaults delete "$ETIQUETA" 2>/dev/null || true
    echo "Telemetría desinstalada (app, arranque automático y preferencias)."
    exit 0
fi

./construir.sh
detener

mkdir -p "$(dirname "$APP_DESTINO")"
rm -rf "$APP_DESTINO"
cp -R "build.noindex/Telemetría.app" "$APP_DESTINO"

# Registra la app en LaunchServices para que Spotlight y el lanzador la
# muestren con su icono.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_DESTINO" || true

if [ "${1:-}" != "--al-iniciar" ]; then
    # Sin arranque automático: si quedó de una instalación anterior, se quita.
    rm -f "$AGENTE"
    echo "Telemetría instalada en $APP_DESTINO. Ábrela desde Aplicaciones o Spotlight."
    echo "No arranca al iniciar sesión (para eso: ./instalar.sh --al-iniciar)."
    exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENTE" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$ETIQUETA</string>
	<key>ProgramArguments</key>
	<array>
		<string>$BINARIO</string>
		<string>--fondo</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "$AGENTE" >/dev/null
launchctl bootstrap "$DOMINIO" "$AGENTE"
echo "Telemetría instalada en $APP_DESTINO y en marcha en la barra de menú."
echo "Arranca sola al iniciar sesión. Para quitarla: ./instalar.sh --desinstalar"
