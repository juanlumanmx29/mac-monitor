#!/bin/bash
# Lanzador del Monitor M4 Pro. Doble clic para iniciar.

cd "$(dirname "$0")" || exit 1

PUERTO=8765
URL="http://localhost:$PUERTO"
CODIGO_REINICIO=42
PIDFILE=".monitor.pid"

C_TIT='\033[1;36m'; C_AVI='\033[1;33m'; C_OK='\033[0;32m'
C_TEN='\033[0;90m'; C_OFF='\033[0m'
LINEA='────────────────────────────────────────────────────────'

titulo() { printf "\n${C_TIT}  %s${C_OFF}\n  ${C_TEN}%s${C_OFF}\n\n" "$1" "$LINEA"; }

clear 2>/dev/null
titulo "MONITOR DE SISTEMA · macOS"

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
printf "  A continuación macOS te pedirá tu contraseña de administrador.\n\n"
printf "  ${C_TEN}Para qué:${C_OFF} habilita el panel de ${C_TIT}Consumo${C_OFF} — vatios de CPU, GPU\n"
printf "  y Neural Engine, y frecuencia por cluster. Es lo único de todo\n"
printf "  el monitor que necesita privilegios.\n\n"
printf "  ${C_TEN}Puedes omitirla${C_OFF} con ${C_AVI}Ctrl+C${C_OFF}. Sin ella igual funcionan:\n"
printf "  ventiladores, sensores térmicos, CPU por núcleo, GPU, memoria,\n"
printf "  batería, red, disco, puertos en escucha y procesos.\n\n"
printf "  ${C_TEN}La pide el sistema, no este programa: la contraseña no se\n"
printf "  guarda, no se registra y no sale de tu equipo.${C_OFF}\n\n"

if sudo -v; then
  ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
  RENOVADOR=$!
  printf "  ${C_OK}✓${C_OFF} Sensores de consumo habilitados.\n"
else
  RENOVADOR=""
  printf "\n  ${C_AVI}·${C_OFF} Continuando sin sensores de consumo.\n"
  printf "    El panel de Consumo mostrará guiones; todo lo demás funciona.\n"
fi

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

# --- avisar y abrir el navegador cuando el servidor responda ----------------
# Se espera a que el puerto conteste de verdad: el arranque tarda un par de
# segundos y abrir antes mostraría una página de error.
(
  for _ in $(seq 1 40); do
    if curl -s -o /dev/null --max-time 1 "$URL" 2>/dev/null; then
      titulo "ACTIVO · $URL"
      printf "  ${C_AVI}⚠  Deja esta ventana abierta mientras uses el monitor.${C_OFF}\n"
      printf "     Al cerrarla el servidor se detiene y libera el puerto.\n\n"
      printf "  ${C_TEN}Teclas dentro del navegador:${C_OFF}\n"
      printf "     ${C_TIT}T${C_OFF}  tema claro / oscuro      ${C_TIT}R${C_OFF}  reiniciar\n"
      printf "     ${C_TIT}P${C_OFF}  pausar el refresco       ${C_TIT}D${C_OFF}  detener y salir\n\n"
      printf "  ${C_TEN}También puedes detenerlo con Ctrl+C aquí.${C_OFF}\n\n"
      open "$URL"
      exit 0
    fi
    sleep 0.5
  done
  printf "\n  ${C_AVI}El servidor tardó más de lo normal en responder.${C_OFF}\n"
  printf "  Abre manualmente: $URL\n\n"
) &

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
