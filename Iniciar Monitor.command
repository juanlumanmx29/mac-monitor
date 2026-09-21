#!/bin/bash
# Lanzador del Monitor M4 Pro. Doble clic para iniciar.

cd "$(dirname "$0")" || exit 1

PUERTO=8765
URL="http://localhost:$PUERTO"
CODIGO_REINICIO=42
PIDFILE=".monitor.pid"

printf '\033[1m Monitor M4 Pro \033[0m\n\n'

# --- instancia anterior -----------------------------------------------------
# Se mira el pidfile antes que el puerto: si un monitor quedó vivo de una
# sesión anterior, se cierra sin preguntar. Preguntar aquí obligaba a
# responder un prompt cada vez que la ventana se había cerrado mal.
if [ -f "$PIDFILE" ]; then
  ANTERIOR=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$ANTERIOR" ] && kill -0 "$ANTERIOR" 2>/dev/null; then
    echo "  Cerrando monitor anterior (pid $ANTERIOR)…"
    kill -TERM "$ANTERIOR" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$ANTERIOR" 2>/dev/null || break
      sleep 0.3
    done
    kill -0 "$ANTERIOR" 2>/dev/null && kill -KILL "$ANTERIOR" 2>/dev/null
  fi
  rm -f "$PIDFILE"
fi

# Red de seguridad: si algo quedó ocupando el puerto sin pidfile.
RESTO=$(lsof -ti :$PUERTO 2>/dev/null)
if [ -n "$RESTO" ]; then
  echo "  Liberando el puerto $PUERTO…"
  echo "$RESTO" | xargs kill -TERM 2>/dev/null
  sleep 1
  RESTO=$(lsof -ti :$PUERTO 2>/dev/null)
  [ -n "$RESTO" ] && echo "$RESTO" | xargs kill -KILL 2>/dev/null
fi

# --- sudo para powermetrics -------------------------------------------------
# Sin esto el panel funciona igual, pero sin vatios ni frecuencias:
# powermetrics es el único camino a esos sensores y exige privilegios.
echo "  Los datos de consumo (vatios, frecuencias) requieren privilegios"
echo "  de administrador. Puedes omitirlo con Ctrl+C: el resto del"
echo "  monitor funciona igual."
echo
if sudo -v; then
  ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
  RENOVADOR=$!
  echo "  Sensores de potencia habilitados."
else
  RENOVADOR=""
  echo "  Continuando sin sensores de potencia."
fi
echo

SERVIDOR_PID=""

limpiar() {
  # El orden importa: primero el servidor, que a su vez mata powermetrics
  # con sudo (es un proceso de root y no se deja matar de otro modo).
  if [ -n "$SERVIDOR_PID" ] && kill -0 "$SERVIDOR_PID" 2>/dev/null; then
    kill -TERM "$SERVIDOR_PID" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      kill -0 "$SERVIDOR_PID" 2>/dev/null || break
      sleep 0.3
    done
    kill -0 "$SERVIDOR_PID" 2>/dev/null && kill -KILL "$SERVIDOR_PID" 2>/dev/null
  fi
  [ -n "$RENOVADOR" ] && kill "$RENOVADOR" 2>/dev/null
  # Por si powermetrics sobrevivió: es de root, así que necesita sudo.
  sudo -n pkill -f "powermetrics --samplers" 2>/dev/null
  rm -f "$PIDFILE"
}

# HUP es la señal que manda Terminal al cerrar la ventana. Sin ella, cerrar
# la ventana dejaba el servidor vivo con el puerto tomado.
trap limpiar EXIT HUP INT TERM

# --- abrir navegador una sola vez -------------------------------------------
( sleep 1.5; open "$URL" ) &

# --- bucle: exit 42 = reiniciar, cualquier otro = salir ---------------------
while true; do
  # En segundo plano y con wait: así el trap puede dispararse mientras el
  # servidor corre. En primer plano, bash no atiende señales hasta que el
  # hijo termina, que es justo lo que impedía la limpieza.
  python3 monitor.py &
  SERVIDOR_PID=$!
  wait $SERVIDOR_PID
  codigo=$?
  SERVIDOR_PID=""

  if [ "$codigo" -eq "$CODIGO_REINICIO" ]; then
    echo
    echo "  Reiniciando…"
    sleep 1
    continue
  fi
  break
done

echo
echo "  Monitor detenido."
sleep 1
