# mac-monitor

A local system telemetry dashboard for macOS. Double-click, read it in your
browser. **Zero dependencies** — it runs on the Python 3 that ships with
macOS, and nothing ever leaves your machine.

Reads **fan RPM and hundreds of thermal sensors without root**, which
`powermetrics` cannot do on Apple Silicon.

---

## English

### Why

Most Mac monitors either need a paid app, a kernel extension, or `sudo` for
everything. This one talks to the SMC directly through IOKit, so fans and
thermistors are readable as a normal user. The only thing that needs
privileges is power draw in watts, and the dashboard works fine without it.

### The interface

Three rows of cards, all the same size: **Machine** (CPU, GPU, RAM, thermal,
fans, power, battery), **Activity** (network, disk, processes, energy, ports,
sleep) and **Watch** (forgotten and ghost processes, one card per alert). Each
card shows the current value, a line of context, two extra figures and a
60-second sparkline. The width is computed so a whole number of cards fits
each row and every edge lines up; the height splits the screen between the
three rows.

A row that does not fit becomes a carousel: it advances on its own every few
seconds, and you can move it with the ‹ › arrows, the trackpad or the mouse
wheel. It holds still while the pointer is over it, for a few seconds after
you move it by hand, while a detail is open and while the tab is hidden. `E`
turns rotation off and the choice is remembered; if the system asks for
reduced motion, it starts off.

Click a card to open its **detail in a floating window**. `←` `→` move to the
neighbouring card; `Esc` or a click outside closes it. A detail can be linked
directly, e.g. `http://localhost:8765/#vigilancia`.

| Card | Summary | Detail | Needs sudo |
|---|---|---|---|
| **CPU** | Load, core count | Per-core heat grid split into efficiency and performance clusters, gauge, processes, threads, clock | no |
| **GPU** | Utilization, VRAM | Gauge, renderer, tiler, clock, residency, time per frequency state (sudo) | no |
| **RAM** | Percentage, GB used | App / wired / compressed / cached breakdown, swap, pressure, 60 s history | no |
| **Thermal** | Hottest reading and which family | Up to 8 sensor families (P-cores, E-cores, GPU, VRM, chassis, battery, SSD, intake) | no |
| **Fans** | RPM, state | Per-fan RPM with icons spinning proportionally to real speed, plus range | no |
| **Power** | Total watts | CPU, GPU and Neural Engine separately, per-cluster clock | **yes** |
| **Battery** | Charge, state | Flow in watts, cycles, health, cell temperature | no |
| **Network** | Throughput | In / out per second with its own chart | no |
| **Disk** | Throughput | Read / write per second with its own chart | no |
| **Processes** | Total, top consumer | Ranked by CPU and by memory, with lifetime, parent, full command and an orphan flag | no |
| **Energy** | Top energy consumer | Energy impact per process, the figure in Activity Monitor's Energy tab | no |
| **Ports** | Count, how many exposed | Listening TCP sockets flagged **local** or **exposed**, with what each known service is, how long it has been open and its parent | partial |
| **Sleep** | How many things keep the Mac awake | Who prevents sleep or display sleep, for how long and on whose behalf | no |
| **Watch** | Active alerts | Forgotten, runaway, zombie and suspended processes, with the command to stop them | no |

Everything is auto-detected at runtime: core counts, cluster topology, RAM,
GPU cores, sensor layout. The same code adapts to any Mac.

### Forgotten and ghost processes

A background thread reads the process table every 5 seconds, even when nobody
has the dashboard open. It exists because of a real case: a shell left behind
by a closed Terminal window spent two days burning two cores, unnoticed.

| Rule | Level | When |
|---|---|---|
| **Forgotten** | warning | A process of yours with no terminal window (neither it nor any of its parents has one) that no app and no launchd job keeps alive. Most likely the window that launched it was closed and it kept running. |
| **Forgotten, burning CPU** | critical | The same, holding 20 % of a core or more for 2 minutes. |
| **Runaway** | warning | Any process holding 90 % of a core for 10 minutes. |
| **Zombie** | warning | Finished, but its parent never collected it. Grouped by parent. |
| **Suspended** | info | Stopped with Ctrl+Z or SIGSTOP for more than 10 minutes. |
| **Sleep** | warning | Something has prevented sleep for over 30 minutes while on battery. |

Alerts appear as cards in the Watch row, as a counter in the header and in the
tab title. Critical ones also raise a **macOS notification**, once per
process; start the server with `MONITOR_NOTIFICAR=0` to turn that off. Each
alert can be silenced from its detail. Silencing applies to the program (rule
plus command line), so it survives a restart under a new PID, and it is kept
in that browser only.

Programs that detach from their terminal on purpose (`tmux`, `screen`,
`ssh-agent`, `gpg-agent` and similar) are never flagged as forgotten. The
thresholds live at the top of `vigilancia.py`.

### Requirements

- macOS with the Command Line Tools (provides `/usr/bin/python3`)
- Apple Silicon recommended. Intel Macs work with reduced detail: there are
  no efficiency/performance clusters, so cores render as a single group.

No Homebrew, no `pip install`, no Node.

### Usage

```bash
git clone https://github.com/juanlumanmx29/mac-monitor.git
cd mac-monitor
chmod +x "Iniciar Monitor.command"
```

Then **double-click `Iniciar Monitor.command`**.

It asks for your admin password once, to enable the power sensors. Press
`Ctrl+C` at that prompt to skip it — everything else still works. The server
starts and the browser opens at `http://localhost:8765`.

The Terminal window stays open as the server's control panel, one key each,
no Enter:

| Key | Action |
|---|---|
| `a` | Start |
| `r` | Restart |
| `d` | Stop |
| `n` | Open the browser |
| `l` | Show the server log |
| `q` | Stop and close |

**Closing that window stops the server** and everything it started. Opening
the launcher again while it is running just brings the existing window to the
front.

### Keyboard

The dashboard has no buttons; hover the status indicator in the header for a
reminder of these keys.

| Key | Action |
|---|---|
| `1`–`9` | Open that card's detail (the first nine) |
| `A` | Open the Watch detail |
| `←` `→` | Previous / next detail while one is open |
| `Esc` | Close the detail |
| `Tab`, `Enter` | Move between cards and open one |
| `E` | Turn automatic rotation of the rows on or off |
| `T` | Toggle light / dark theme |
| `P` | Pause / resume refresh |

The theme follows your system preference on first run. Once you pick one, your
choice wins and is remembered.

### Privacy

The server binds to `127.0.0.1` only — it is not reachable from your network.
There is no telemetry, no analytics, no outbound request of any kind. Nothing
is written to disk except the launcher's log and lock file in `/tmp`. Notifications
are shown locally through `osascript`, and preferences (theme, rotation,
silenced alerts) live in the browser's local storage.

### How it works

- **Per-core load** — `host_processor_info()` from Mach, via `ctypes`. Same
  source `psutil` uses, without the dependency.
- **Fans and temperatures** — the `AppleSMC` IOKit service, opened read-only.
  `powermetrics` dropped its `smc` sampler on Apple Silicon, so this is the
  only route to fan RPM. The SMC exposes thousands of keys; the code
  enumerates them once at startup, in a background thread so the server binds
  immediately, and groups the live thermistors into families.
- **GPU** — `IOAccelerator` performance statistics from the IOKit registry.
  `powermetrics` reports the same numbers but demands privileges.
- **Memory** — `vm_stat`, using Activity Monitor's definition:
  `used = (anonymous − purgeable) + wired + compressed`. Cached files are
  counted separately because the system releases them on demand.
- **Battery** — `ioreg -rn AppleSmartBattery`. Note that instant amperage
  arrives as an unsigned 64-bit integer, so discharge readings need two's
  complement reversal or you get absurd wattages.
- **Power** — `powermetrics` kept streaming in a background thread. Spawning
  it per sample would cost about a second each time.
- **Network and disk** — cumulative counters from `netstat -ib` and the
  `IOBlockStorageDriver` registry, differentiated into bytes per second.
- **Watch** — `ps` (two calls, because both the executable path and the full
  command line can contain spaces), `launchctl list` to know which processes
  launchd keeps alive, `pmset -g assertions` for sleep blockers and
  `top -o power` for energy impact. Sustained CPU comes from snapshots of
  cumulative CPU time taken every 30 s, not from `ps`'s decaying percentage.
  Energy is sampled only while the dashboard is open, since `top` itself
  costs some CPU.

### Notes and gotchas

- **0 RPM is normal.** Apple Silicon Macs dissipate through the aluminum
  chassis and only spin the fans under sustained load.
- **P-core thermistors read 0 while that cluster is powered down.** The panel
  shows *reposo* rather than a misleading zero.
- **Voltage regulators are usually the hottest thing in the machine.** They
  dissipate the loss of converting voltages; it does not mean the processor
  is struggling.
- **Listening ports are incomplete without sudo.** `lsof` only reveals your
  own processes otherwise; system daemons stay hidden.
- Change the port with the `MONITOR_PUERTO` environment variable, and set the
  same number in `PUERTO` inside the launcher.

### Files

```
monitor.py               HTTP server and metric collection
smc.py                   fan and thermistor access through IOKit
vigilancia.py            forgotten, ghost and runaway process watch
dashboard.html           interface
Iniciar Monitor.command  double-click launcher and server control window
```

`smc.py` and `vigilancia.py` run standalone, for a quick sensor dump and a
quick process check:

```bash
python3 smc.py
python3 vigilancia.py          # add --json for the raw block
```

### License

MIT

---

## Español

### Por qué

Casi todos los monitores para Mac requieren una app de pago, una extensión de
kernel o `sudo` para todo. Este habla directo con el SMC a través de IOKit, así
que los ventiladores y termistores se leen como usuario normal. Lo único que
necesita privilegios es el consumo en vatios, y el panel funciona igual sin eso.

### La interfaz

Tres filas de tarjetas, todas del mismo tamaño: **Equipo** (CPU, GPU, RAM,
térmico, ventiladores, consumo, batería), **Actividad** (red, disco, procesos,
energía, puertos, reposo) y **Vigilancia** (procesos olvidados y fantasmas,
una tarjeta por alerta). Cada tarjeta muestra el valor actual, una línea de
contexto, dos cifras extra y un minigráfico de 60 segundos. El ancho se
calcula para que en cada fila quepa un número entero de tarjetas y todos los
bordes calcen; el alto reparte la pantalla entre las tres filas.

Una fila que no cabe se convierte en carrusel: avanza sola cada pocos
segundos, y se mueve con las flechas ‹ ›, el trackpad o la rueda del ratón. Se
queda quieta con el cursor encima, unos segundos después de moverla a mano,
con un detalle abierto y con la pestaña oculta. `E` apaga el giro y la
elección se recuerda; si el sistema pide reducir el movimiento, arranca
apagado.

Al pulsar una tarjeta se abre su **detalle en una ventana flotante**. `←` `→`
pasan a la tarjeta vecina; `Esc` o un clic fuera la cierran. Un detalle se
puede enlazar directamente, por ejemplo `http://localhost:8765/#vigilancia`.

| Tarjeta | Resumen | Detalle | Requiere sudo |
|---|---|---|---|
| **CPU** | Carga, número de núcleos | Rejilla de calor por núcleo separada en clusters de eficiencia y rendimiento, medidor, procesos, hilos, frecuencia | no |
| **GPU** | Utilización, VRAM | Medidor, renderizador, teselador, frecuencia, residencia, tiempo por estado de frecuencia (sudo) | no |
| **RAM** | Porcentaje, GB usados | Desglose apps / anclada / comprimida / caché, swap, presión, histórico de 60 s | no |
| **Térmico** | Lectura más alta y de qué familia | Hasta 8 familias de sensores (núcleos P y E, GPU, reguladores, chasis, batería, SSD, entrada de aire) | no |
| **Ventiladores** | RPM, estado | RPM por ventilador, con iconos que giran a velocidad proporcional a la real, y su rango | no |
| **Consumo** | Vatios totales | CPU, GPU y Neural Engine por separado, frecuencia por cluster | **sí** |
| **Batería** | Carga, estado | Flujo en vatios, ciclos, salud, temperatura de celdas | no |
| **Red** | Caudal | Entrada y salida por segundo, con gráfico propio | no |
| **Disco** | Caudal | Lectura y escritura por segundo, con gráfico propio | no |
| **Procesos** | Total y quién lidera | Ordenados por CPU y por memoria, con tiempo de vida, padre, comando completo y marca de huérfano | no |
| **Energía** | Quién más consume | Impacto energético por proceso, la cifra de la pestaña Energía del Monitor de Actividad | no |
| **Puertos** | Cantidad y cuántos expuestos | Sockets TCP en escucha, marcados **local** o **expuesto**, con qué es cada servicio conocido, cuánto lleva abierto y su padre | parcial |
| **Reposo** | Cuántas cosas mantienen despierto el Mac | Quién impide dormir o apagar la pantalla, desde cuándo y en nombre de quién | no |
| **Vigilancia** | Alertas activas | Procesos olvidados, desbocados, zombis y suspendidos, con el comando para detenerlos | no |

Todo se detecta en ejecución: número de núcleos, topología de clusters, RAM,
núcleos de GPU y disposición de sensores. El mismo código se adapta a
cualquier Mac.

### Procesos olvidados y fantasmas

Un hilo aparte lee la tabla de procesos cada 5 segundos, aunque nadie tenga el
panel abierto. Existe por un caso real: una shell que quedó de una ventana de
Terminal cerrada pasó dos días consumiendo dos núcleos sin que nadie lo notara.

| Regla | Nivel | Cuándo |
|---|---|---|
| **Olvidado** | aviso | Un proceso tuyo sin ventana de terminal (ni él ni ninguno de sus padres la tiene) que ninguna app ni trabajo de launchd mantiene vivo. Lo más probable es que se cerró la ventana que lo lanzó y siguió corriendo. |
| **Olvidado y consumiendo CPU** | crítico | Lo mismo, con 20 % de un núcleo o más durante 2 minutos. |
| **Desbocado** | aviso | Cualquier proceso con 90 % de un núcleo durante 10 minutos. |
| **Zombi** | aviso | Terminó, pero su padre nunca lo recogió. Se agrupan por padre. |
| **Suspendido** | info | Detenido con Ctrl+Z o SIGSTOP desde hace más de 10 minutos. |
| **Reposo** | aviso | Algo impide dormir desde hace más de 30 minutos con el equipo en batería. |

Las alertas aparecen como tarjetas en la fila Vigilancia, como contador en la
cabecera y en el título de la pestaña. Las críticas además lanzan una
**notificación de macOS**, una por proceso; para desactivarlas, arranca el
servidor con `MONITOR_NOTIFICAR=0`. Cada alerta se puede silenciar desde su
detalle. El silencio se aplica al programa (regla más línea de comando), así
que sobrevive a que se relance con otro PID, y se guarda solo en ese
navegador.

Los programas que se separan de su terminal a propósito (`tmux`, `screen`,
`ssh-agent`, `gpg-agent` y similares) nunca se marcan como olvidados. Los
umbrales están al principio de `vigilancia.py`.

### Requisitos

- macOS con las Command Line Tools (aportan `/usr/bin/python3`)
- Apple Silicon recomendado. Los Mac Intel funcionan con menos detalle: no
  tienen clusters de eficiencia y rendimiento, así que los núcleos se
  muestran como un solo grupo.

Sin Homebrew, sin `pip install`, sin Node.

### Uso

```bash
git clone https://github.com/juanlumanmx29/mac-monitor.git
cd mac-monitor
chmod +x "Iniciar Monitor.command"
```

Luego **doble clic en `Iniciar Monitor.command`**.

Pide la contraseña de administrador una vez, para habilitar los sensores de
consumo. Con `Ctrl+C` en ese prompt lo omites: todo lo demás sigue funcionando.
El servidor arranca y el navegador se abre en `http://localhost:8765`.

La ventana de Terminal queda abierta como panel de control del servidor, con
una tecla por acción y sin Enter:

| Tecla | Acción |
|---|---|
| `a` | Arranca |
| `r` | Reinicia |
| `d` | Detiene |
| `n` | Abre el navegador |
| `l` | Muestra el registro del servidor |
| `q` | Detiene y cierra |

**Cerrar esa ventana detiene el servidor** y todo lo que arrancó. Si vuelves a
abrir el lanzador mientras corre, solo trae al frente la ventana que ya existe.

### Teclas

El panel no tiene botones; al pasar el cursor por el indicador de estado de la
cabecera aparece un recordatorio de estas teclas.

| Tecla | Acción |
|---|---|
| `1`–`9` | Abre el detalle de esa tarjeta (las nueve primeras) |
| `A` | Abre el detalle de Vigilancia |
| `←` `→` | Detalle anterior / siguiente mientras hay uno abierto |
| `Esc` | Cierra el detalle |
| `Tab`, `Enter` | Recorre las tarjetas y abre una |
| `E` | Enciende o apaga el giro automático de las filas |
| `T` | Alterna tema claro / oscuro |
| `P` | Pausa / reanuda el refresco |

El tema sigue la preferencia del sistema la primera vez. En cuanto eliges uno,
tu elección manda y se recuerda.

### Privacidad

El servidor escucha solo en `127.0.0.1`, así que no es alcanzable desde tu red.
No hay telemetría, ni analítica, ni ninguna petición saliente. Lo único que se
escribe a disco es el registro y el candado del lanzador, en `/tmp`. Las notificaciones
se muestran en local con `osascript`, y las preferencias (tema, giro, alertas
silenciadas) viven en el almacenamiento local del navegador.

### Cómo funciona

- **Carga por núcleo** — `host_processor_info()` de Mach, vía `ctypes`. Es la
  misma fuente que usa `psutil`, sin la dependencia.
- **Ventiladores y temperaturas** — el servicio IOKit `AppleSMC`, abierto solo
  para lectura. `powermetrics` eliminó su sampler `smc` en Apple Silicon, así
  que esta es la única vía a las RPM. El SMC expone miles de claves; el código
  las enumera una vez al arrancar, en un hilo aparte para que el servidor abra
  el socket de inmediato, y agrupa los termistores activos en familias.
- **GPU** — estadísticas de `IOAccelerator` del registro de IOKit.
  `powermetrics` da las mismas cifras pero exigiendo privilegios.
- **Memoria** — `vm_stat`, con el criterio del Monitor de Actividad:
  `usada = (anónimas − purgables) + anclada + comprimida`. Los archivos en
  caché van aparte porque el sistema los libera a demanda.
- **Batería** — `ioreg -rn AppleSmartBattery`. Ojo: el amperaje instantáneo
  llega como entero sin signo de 64 bits, así que al descargar hay que revertir
  el complemento a dos o salen consumos absurdos.
- **Consumo** — `powermetrics` en streaming desde un hilo aparte. Lanzarlo por
  muestra costaría cerca de un segundo cada vez.
- **Red y disco** — contadores acumulados de `netstat -ib` y del registro
  `IOBlockStorageDriver`, derivados a bytes por segundo.
- **Vigilancia** — `ps` (dos llamadas, porque tanto la ruta del ejecutable
  como la línea de comando pueden llevar espacios), `launchctl list` para
  saber qué procesos mantiene vivos launchd, `pmset -g assertions` para los
  bloqueos de reposo y `top -o power` para el impacto energético. La CPU
  sostenida sale de fotos de la CPU acumulada tomadas cada 30 s, no del
  porcentaje con decaimiento de `ps`. La energía solo se mide mientras el
  panel está abierto, porque `top` también gasta CPU.

### Detalles que conviene saber

- **0 RPM es normal.** Los Mac con Apple Silicon disipan por el chasis de
  aluminio y solo mueven los ventiladores bajo carga sostenida.
- **Los termistores de los núcleos P leen 0 mientras el cluster está apagado.**
  El panel muestra *reposo* en vez de un cero engañoso.
- **Los reguladores de voltaje suelen ser lo más caliente del equipo.**
  Disipan la pérdida de convertir voltajes; no significa que el procesador
  esté sufriendo.
- **Los puertos en escucha quedan incompletos sin sudo.** `lsof` solo revela
  tus propios procesos; los demonios del sistema no aparecen.
- El puerto se cambia con la variable de entorno `MONITOR_PUERTO`, poniendo el
  mismo número en `PUERTO` dentro del lanzador.

### Archivos

```
monitor.py               servidor HTTP y recolección de métricas
smc.py                   acceso a ventiladores y termistores vía IOKit
vigilancia.py            procesos olvidados, fantasmas y desbocados
dashboard.html           interfaz
Iniciar Monitor.command  lanzador de doble clic y ventana de control del servidor
```

`smc.py` y `vigilancia.py` se ejecutan por sí solos, para un volcado rápido de
sensores y una revisión rápida de procesos:

```bash
python3 smc.py
python3 vigilancia.py          # con --json, el bloque en bruto
```

### Licencia

MIT
