#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  Lanzador y monitor local — generado por el skill `command` (version 2.2, 2026-11-23).
#  Doble clic para abrirlo: arranca el servidor y queda una ventana que lo vigila, con una sola
#  tecla, sin Enter. Al cerrar esta ventana (o con q) se detiene todo lo del proyecto; los servicios
#  compartidos (bases de datos, el gateway de otro proyecto) siguen corriendo.
#
#  Las variables de abajo son lo unico especifico del proyecto. El resto, incluido el bloque
#  «Una sola ventana por proyecto», se copia tal cual.
# ─────────────────────────────────────────────────────────────────────────────
PROYECTO="Monitor del Mac"          # nombre que se muestra en la cabecera
APP="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CMD_DEV='python3 monitor.py'            # comando que levanta el servidor (corre en $APP)
PUERTO=8765                # puerto donde escucha
RUTAS=""                # rutas utiles, separadas por espacios
# Servicios compartidos que el servidor necesita: "etiqueta:puerto:comando_de_arranque" (comando vacio: solo se
# vigila). Se arrancan si faltan y NUNCA se detienen: sirven a otros proyectos.
SERVICIOS=()
# Procesos propios que van aparte del servidor: "etiqueta:puerto:directorio:comando" (directorio relativo a $APP).
# Se arrancan con el servidor y se detienen con el.
PROPIOS=()
# Otros puertos donde escucha algo del proyecto (lo que levanta el mismo comando, como el API de un `npm run dev`):
# "etiqueta:puerto". Se muestran y, al detener, se apaga lo que escuche ahi si es del proyecto.
OTROS=()
# Paso previo del proyecto: se ejecuta una vez en la ventana antes de arrancar (p. ej. pedir la contrasena de
# sudo). Ctrl+C ahi solo lo omite. Casi siempre vacio.
ANTES='echo; echo "  La contraseña de administrador habilita los vatios y las frecuencias (powermetrics)."; echo "  Ctrl+C la omite y todo lo demás funciona igual. La pide macOS: no se guarda ni sale del equipo."; echo; if sudo -v -p "  Contraseña: "; then ( while kill -0 $$ 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) & fi; ( for _ in $(seq 1 60); do vivo "$PUERTO" && { open "http://localhost:$PUERTO"; break; }; sleep 0.5; done ) &'
ESPERA=90                        # segundos que se espera a que el servidor escuche

SLUG="$(echo "$PROYECTO" | tr ' A-Z' '-a-z')"
LOG="/tmp/lanzador-$SLUG.log"
RAICES="/tmp/lanzador-$SLUG.raices"    # PID raiz de cada proceso que arranco este monitor (para detenerlo entero)
V=$'\e[32m'; R=$'\e[31m'; A=$'\e[33m'; G=$'\e[90m'; B=$'\e[1m'; N=$'\e[0m'

vivo()      { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
escuchan()  { lsof -nP -ti tcp:"$1" -sTCP:LISTEN 2>/dev/null; }   # quienes escuchan (no un navegador conectado)
cwd_de()    { lsof -a -p "$1" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
padre_de()  { ps -o ppid= -p "$1" 2>/dev/null | tr -d ' '; }
dentro_de() { case "$(cwd_de "$1")/" in "$2"/*) return 0 ;; esac; return 1; }   # su carpeta esta en $2
abs()       { (cd "$APP" && cd "$1" 2>/dev/null && pwd); }
campo()     { echo "$1" | cut -d: -f"$2"; }
campo_desde() { echo "$1" | cut -d: -f"$2"-; }

# El ancestro mas alto del proceso que sigue siendo de la carpeta $2: asi se detiene tambien el `npm` o el
# `bash -c` que lo lanzo, no solo quien escucha. Nunca sube a este monitor, a otro lanzador ni a launchd, y solo
# sube por programas que lanzan servidores (es_lanzador): una pestana de Terminal, el editor o Claude Code pueden
# tener su carpeta en el proyecto, y detenerlos cerraria la terminal o la sesion.
raiz_de() {
  local p="$1" q
  while :; do
    q=$(padre_de "$p")
    { [ -z "$q" ] || [ "$q" -le 1 ] || [ "$q" = "$$" ]; } && break
    ps -o args= -p "$q" 2>/dev/null | grep -q '\.command' && break
    es_lanzador "$q" || break
    dentro_de "$q" "$2" || break
    p=$q
  done
  echo "$p"
}

# Si el proceso es de los que lanzan servidores: una shell que corre un comando o un guion (no una interactiva, como
# -zsh o zsh -l), npm y parecidos, node, uv, python o make. Nada que diga «claude» (Claude Code corre tambien como node).
es_lanzador() {
  local a IFS=' '
  a=$(ps -o args= -p "$1" 2>/dev/null)
  case "$a" in ''|-*|*claude*) return 1 ;; esac
  set -f; set -- $a; set +f
  case "${1##*/}" in
    sh|bash|zsh|dash|ksh)
      shift
      for a in "$@"; do case "$a" in --*) ;; -*c*) return 0 ;; -*) ;; *) return 0 ;; esac; done
      return 1 ;;
    npm|npx|pnpm|yarn|bun|node|deno|tsx|uv|uvx|python|python3|python3.*|Python|make|env|nohup) return 0 ;;
  esac
  return 1
}

# El proceso y todos sus descendientes.
# Un solo awk con registro de lo ya visto: termina siempre, aunque le llegue basura en vez de PIDs.
arbol() {
  case "$1" in ''|*[!0-9]*) return ;; esac
  ps -axo pid=,ppid= | awk -v raiz="$1" '
    { hijos[$2] = hijos[$2] " " $1 }
    END {
      visto[raiz] = 1; cola[1] = raiz; n = 1; r = raiz
      for (i = 1; i <= n; i++) {
        k = split(hijos[cola[i]], hs, " ")
        for (j = 1; j <= k; j++)
          if (!(hs[j] in visto)) { visto[hs[j]] = 1; cola[++n] = hs[j]; r = r " " hs[j] }
      }
      print r
    }'
}

# Termina los arboles de estos procesos: primero con TERM y, a los 5 s, con KILL lo que quede.
terminar() {
  local pids="" p q vivos
  for p in "$@"; do
    for q in $(arbol "$p"); do case "$q" in ''|*[!0-9]*) ;; *) pids="$pids $q" ;; esac; done
  done
  [ -z "${pids// /}" ] && return 1
  kill -TERM $pids 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    vivos=""; for p in $pids; do kill -0 "$p" 2>/dev/null && vivos="$vivos $p"; done
    [ -z "$vivos" ] && return 0
    sleep 0.5
  done
  kill -KILL $vivos 2>/dev/null
  return 0
}

# Si el proceso es de la carpeta del proyecto o de la de uno de sus procesos propios.
del_proyecto() {
  local e dir
  dentro_de "$1" "$APP" && return 0
  for e in "${PROPIOS[@]}"; do
    [ -z "$e" ] && continue
    dir=$(abs "$(campo "$e" 3)"); [ -n "$dir" ] && dentro_de "$1" "$dir" && return 0
  done
  return 1
}

# Lo que hay que detener del proyecto: lo que arranco este monitor (si sigue siendo de su carpeta) y lo que
# escuche en sus puertos desde su carpeta (asi tambien lo que dejo un monitor anterior). Lo ajeno no se toca.
raices_del_proyecto() {
  local r="" p e pt dir
  # Un PID anotado por un monitor que murio de golpe puede ser hoy de otro programa: solo cuenta si sigue en la carpeta.
  for p in $(cat "$RAICES" 2>/dev/null); do kill -0 "$p" 2>/dev/null && del_proyecto "$p" && r="$r $p"; done
  for p in $(escuchan "$PUERTO"); do dentro_de "$p" "$APP" && r="$r $(raiz_de "$p" "$APP")"; done
  for e in "${OTROS[@]}"; do
    [ -z "$e" ] && continue
    for p in $(escuchan "$(campo "$e" 2)"); do dentro_de "$p" "$APP" && r="$r $(raiz_de "$p" "$APP")"; done
  done
  for e in "${PROPIOS[@]}"; do
    [ -z "$e" ] && continue
    pt=$(campo "$e" 2); dir=$(abs "$(campo "$e" 3)")
    [ -z "$dir" ] && continue
    for p in $(escuchan "$pt"); do dentro_de "$p" "$dir" && r="$r $(raiz_de "$p" "$dir")"; done
  done
  echo $r | tr ' ' '\n' | sort -u | tr '\n' ' '
}

# Quien ocupa el puerto sin ser del proyecto (para decirlo, nunca para detenerlo).
ajeno() {
  local p; for p in $(escuchan "$1"); do dentro_de "$p" "${2:-$APP}" || { ps -o comm= -p "$p" 2>/dev/null | sed 's#.*/##'; return; }; done
}

linea() {   # linea etiqueta puerto [carpeta]
  local quien
  if vivo "$2"; then
    quien=$(ajeno "$2" "$3")
    if [ -n "$quien" ]; then echo "  ${A}●${N} $(printf '%-13s' "$1"):$2   ${A}ocupado por otro programa ($quien)${N}"
    else echo "  ${V}●${N} $(printf '%-13s' "$1"):$2"; fi
  else
    echo "  ${R}○${N} $(printf '%-13s' "$1"):$2   ${R}detenido${N}"
  fi
}

pintar() {
  local s
  printf '\e[H\e[2J'
  echo "${B}  $PROYECTO${N}"
  echo "${G}  $APP${N}"
  echo
  linea "servidor" "$PUERTO"
  for s in "${OTROS[@]}"; do [ -n "$s" ] && linea "$(campo "$s" 1)" "$(campo "$s" 2)"; done
  for s in "${PROPIOS[@]}"; do [ -n "$s" ] && linea "$(campo "$s" 1)" "$(campo "$s" 2)" "$(abs "$(campo "$s" 3)")"; done
  for s in "${SERVICIOS[@]}"; do
    [ -z "$s" ] && continue
    if vivo "$(campo "$s" 2)"; then echo "  ${V}●${N} $(printf '%-13s' "$(campo "$s" 1)"):$(campo "$s" 2)   ${G}compartido${N}"
    else echo "  ${R}○${N} $(printf '%-13s' "$(campo "$s" 1)"):$(campo "$s" 2)   ${R}detenido${N} ${G}(compartido)${N}"; fi
  done
  echo
  if vivo "$PUERTO" && [ -z "$(ajeno "$PUERTO")" ]; then
    for s in ${RUTAS:-/}; do echo "  ${G}→${N} http://localhost:$PUERTO$s"; done
    echo
  fi
  echo "${G}  ─────────────────────────────────────────────${N}"
  echo "   ${B}a${N} arrancar    ${B}r${N} reiniciar    ${B}d${N} detener"
  echo "   ${B}n${N} navegador   ${B}l${N} registro     ${B}q${N} detener y cerrar"
  echo "${G}  ─────────────────────────────────────────────${N}"
  echo "${G}  Al cerrar esta ventana se detiene el servidor. Se refresca cada 3 s.${N}"
}

anotar_raiz() { echo "$1" >> "$RAICES"; }

arrancar_servicios() {
  local s et pt cmd
  for s in "${SERVICIOS[@]}"; do
    [ -z "$s" ] && continue
    et=$(campo "$s" 1); pt=$(campo "$s" 2); cmd=$(campo_desde "$s" 3)
    vivo "$pt" && continue
    [ -z "$cmd" ] && { echo "  ${A}$et no corre y no se como arrancarlo${N}"; continue; }
    echo "  arrancando $et..."
    # Compartido: aparte de este monitor (nohup), para que siga vivo al cerrar la ventana.
    ( cd "$APP" && nohup bash -c "$cmd" </dev/null >/dev/null 2>&1 & )
    for _ in $(seq 1 30); do vivo "$pt" && break; [ -n "$SALIR" ] && return; sleep 1; done
  done
}

arrancar_propios() {
  local s et pt dir cmd
  for s in "${PROPIOS[@]}"; do
    [ -z "$s" ] && continue
    et=$(campo "$s" 1); pt=$(campo "$s" 2); dir=$(abs "$(campo "$s" 3)"); cmd=$(campo_desde "$s" 4)
    vivo "$pt" && continue
    [ -z "$dir" ] && { echo "  ${R}no existe la carpeta de $et${N}"; continue; }
    echo "  arrancando $et..."
    ( cd "$dir" && exec bash -c "$cmd" ) </dev/null >>"$LOG" 2>&1 &
    anotar_raiz $!
    for _ in $(seq 1 30); do vivo "$pt" && break; [ -n "$SALIR" ] && return; sleep 1; done
  done
}

arrancar() {
  local raiz t=0
  arrancar_servicios
  if vivo "$PUERTO"; then
    if [ -n "$(ajeno "$PUERTO")" ]; then echo "  ${R}el puerto $PUERTO lo ocupa otro programa ($(ajeno "$PUERTO"))${N}"; sleep 2
    else echo "  ya estaba corriendo"; sleep 1; fi
    return
  fi
  : > "$LOG"
  arrancar_propios
  printf '  arrancando servidor...'
  # Hijo de este monitor (sin nohup): muere con el, y queda anotado para detenerlo entero.
  ( cd "$APP" && exec bash -c "$CMD_DEV" ) </dev/null >>"$LOG" 2>&1 &
  raiz=$!; anotar_raiz "$raiz"
  while [ $t -lt $ESPERA ]; do
    vivo "$PUERTO" && break
    [ -n "$SALIR" ] && return                  # se cerro la ventana: la limpieza la hace el ciclo principal
    kill -0 "$raiz" 2>/dev/null || break       # el comando termino: no va a escuchar
    sleep 1; t=$((t + 1)); printf '\r  arrancando servidor... %s s' "$t"
  done
  echo
  vaciar_teclado
  if vivo "$PUERTO"; then echo "  ${V}listo${N}"; sleep 1; return; fi
  echo "  ${R}no arranco. Lo ultimo del registro:${N}"; echo
  tail -15 "$LOG" 2>/dev/null | sed 's/^/    /'
  echo; echo "${G}  pulsa cualquier tecla${N}"; esperar_tecla
}

detener() {   # detener [silencio]
  local raices
  raices=$(raices_del_proyecto)
  if [ -z "${raices// /}" ]; then
    rm -f "$RAICES"
    [ -n "$1" ] && return
    if vivo "$PUERTO"; then echo "  el puerto $PUERTO lo ocupa otro programa: no lo toco"; else echo "  no estaba corriendo"; fi
    sleep 1; return
  fi
  [ -z "$1" ] && echo "  deteniendo..."
  terminar $raices
  rm -f "$RAICES"
  for _ in 1 2 3 4 5 6 7 8 9 10; do vivo "$PUERTO" || break; sleep 0.5; done   # que el puerto quede libre
  [ -n "$1" ] && return
  vaciar_teclado
  echo "  ${V}detenido${N}"; sleep 1
}

# Una tecla. Una flecha u otra tecla especial llega como Esc y varias letras («Esc [ D» es la flecha izquierda):
# se descarta entera, para que no se lea como «d». Lo que se tecleo mientras arrancaba o se detenia se descarta en
# cuanto termina, antes de decir «listo» (al instante, con tcflush: el bash del Mac no sabe mirar el teclado sin
# esperar): asi una tecla repetida por impaciencia no reinicia dos veces, y la que se pulsa al ver «listo» no se pierde.
leer_tecla() {
  k=""
  IFS= read -rsn1 -t 3 k || return 1
  if [ "$k" = $'\e' ]; then IFS= read -rsn5 -t 1 _ 2>/dev/null; k=""; fi
  return 0
}
vaciar_teclado() { perl -MPOSIX -e 'tcflush(0, TCIFLUSH)' 2>/dev/null; }
# «Pulsa cualquier tecla»: si es una flecha, lo que sigue al Esc se descarta (si no, de «Esc [ D» quedaria la D, que
# detendria el servidor al volver al monitor).
esperar_tecla() { IFS= read -rsn1 _; vaciar_teclado; }

# ── Una sola ventana por proyecto ───────────────────────────────────────────
# Dos monitores del mismo servidor se pisan. Si ya hay uno abierto, esta ventana le avisa y
# termina: el abierto pasa al frente y cierra esta cuando ya no tiene procesos (asi Terminal no
# pregunta nada). El candado guarda el PID del monitor abierto. No lo quites al regenerar.
CANDADO="/tmp/lanzador-$SLUG.pid"
ESTE="${BASH_SOURCE[0]##*/}"
MI_TTY="$(tty 2>/dev/null)"; case "$MI_TTY" in /dev/*) ;; *) MI_TTY="" ;; esac

otro_monitor() {
  local p; p=$(cat "$CANDADO" 2>/dev/null)
  [ -n "$p" ] && [ "$p" != "$$" ] && kill -0 "$p" 2>/dev/null \
    && ps -p "$p" -o args= 2>/dev/null | grep -qF "$ESTE"
}
escribir_candado() { ( set -o noclobber; echo "$$" > "$CANDADO" ) 2>/dev/null; }
tomar_candado() {
  escribir_candado && return 0
  otro_monitor && return 1
  rm -f "$CANDADO"                         # quedo de un monitor que ya no existe
  escribir_candado
}
soltar_candado() { local p=""; read -r p < "$CANDADO" 2>/dev/null; [ "$p" = "$$" ] && rm -f "$CANDADO"; }

# La ventana de Terminal cuya pestana tiene esa tty pasa al frente o se cierra.
ventana() {   # ventana frente|cerrar /dev/ttysNNN
  osascript -e 'on run argv' -e 'tell application "Terminal"' \
    -e 'repeat with w in windows' -e 'repeat with p in tabs of w' \
    -e 'if tty of p is (item 2 of argv) then' \
    -e 'if item 1 of argv is "cerrar" then' -e 'close w' -e 'else' \
    -e 'set miniaturized of w to false' -e 'set selected of p to true' -e 'set index of w to 1' -e 'activate' \
    -e 'end if' -e 'return' -e 'end if' \
    -e 'end repeat' -e 'end repeat' -e 'end tell' -e 'end run' "$1" "$2" >/dev/null 2>&1
}

# El monitor abierto recibe USR1 de la ventana nueva: pasa al frente y la cierra cuando ya termino.
al_llamado() {
  local nueva=""; read -r nueva < "$CANDADO.nueva" 2>/dev/null; rm -f "$CANDADO.nueva"
  [ -n "$MI_TTY" ] && ventana frente "$MI_TTY" &
  [ -n "$nueva" ] && ( sleep 1; ventana cerrar "$nueva" ) &
}

if ! tomar_candado; then
  printf '\e[H\e[2J'
  echo "${B}  $PROYECTO${N}"; echo
  echo "  Ya hay un monitor abierto: te llevo a esa ventana."
  [ -n "$MI_TTY" ] && echo "$MI_TTY" > "$CANDADO.nueva"
  kill -USR1 "$(cat "$CANDADO" 2>/dev/null)" 2>/dev/null
  exit 0
fi

# Antes de las trampas: aqui un Ctrl+C solo corta el paso previo, no cierra el monitor.
[ -n "$ANTES" ] && eval "$ANTES"

# ── Al cerrar, se detiene todo lo del proyecto ──────────────────────────────
# Cerrar la ventana manda HUP; Ctrl+C, INT. Las senales solo marcan que hacer: el bash del Mac (3.2) se
# cuelga si la rutina de una senal lanza comandos (queda un hijo «defunct» y bash gira sin fin), asi que
# la limpieza la hace el ciclo principal. Solo el monitor con el candado llega aqui: la ventana repetida
# de arriba sale antes y no detiene nada.
SALIR=""; LLAMADO=""; RAPIDAS=0
trap 'SALIR=1' HUP INT TERM
trap 'LLAMADO=1' USR1
trap soltar_candado EXIT
cerrar() {
  trap '' HUP INT TERM
  # Si la ventana ya no existe, lo que se intento pintar despues quedo en el bufer de salida de bash (la
  # escritura fallo) y cada subshell lo hereda y lo vuelca dentro de su $(...). Asi entraba el texto de la
  # pantalla en la lista de PIDs de la limpieza, que crecia sin fin: un hijo al 100% de CPU durante dias.
  # Se vacia contra /dev/null antes de limpiar (echo fuerza el vaciado).
  exec </dev/null >/dev/null 2>&1
  echo
  # Y con tope de tiempo: pase lo que pase, la limpieza no puede quedarse girando.
  detener silencio &
  local limpieza=$! t=0
  while kill -0 "$limpieza" 2>/dev/null && [ $t -lt 60 ]; do sleep 0.5; t=$((t + 1)); done
  kill -KILL "$limpieza" 2>/dev/null
  soltar_candado
}

vivo "$PUERTO" || arrancar        # al abrir, arranca; si ya corria (de antes), lo vigila y lo detiene al cerrar
while [ -z "$SALIR" ]; do
  [ -n "$LLAMADO" ] && { LLAMADO=""; al_llamado; }
  pintar
  t0=$SECONDS
  if ! leer_tecla; then
    # Sin ventana, read vuelve al instante: varias veces seguidas es que se cerro aunque no llegara el HUP.
    if [ $((SECONDS - t0)) -lt 1 ]; then RAPIDAS=$((RAPIDAS + 1)); [ $RAPIDAS -ge 5 ] && SALIR=1; else RAPIDAS=0; fi
    continue
  fi
  RAPIDAS=0
  case "$k" in
    a|A) echo; arrancar ;;
    r|R) echo; detener; arrancar ;;
    d|D) echo; detener ;;
    n|N) if vivo "$PUERTO" && [ -z "$(ajeno "$PUERTO")" ]; then for r in ${RUTAS:-/}; do open "http://localhost:$PUERTO$r"; done
         else echo; echo "  no esta corriendo"; sleep 1; fi ;;
    l|L) printf '\e[H\e[2J'; echo "${B}  registro — ultimas 45 lineas${N}"; echo
         tail -45 "$LOG" 2>/dev/null || echo "  todavia no hay registro"
         echo; echo "${G}  pulsa cualquier tecla${N}"; esperar_tecla ;;
    q|Q) printf '\e[H\e[2J'; echo; detener
         echo "  Todo detenido. Ya puedes cerrar esta ventana."; echo
         SALIR=1 ;;
  esac
done
cerrar
exit 0
