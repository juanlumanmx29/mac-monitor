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

### What it shows

| Panel | Detail | Needs sudo |
|---|---|---|
| **CPU** | Per-core heat grid, split into efficiency and performance clusters | no |
| **GPU** | Device / renderer / tiler utilization, VRAM in use | no |
| **Fans** | Real RPM per fan, icons spin proportionally to actual speed | no |
| **Thermal** | Up to 8 sensor families (P-cores, E-cores, GPU, VRM, chassis, battery, SSD, intake) | no |
| **Memory** | App / wired / compressed / cached breakdown, swap, pressure | no |
| **Battery** | Charge, flow in watts, cycles, health, cell temperature | no |
| **Throughput** | Network and disk, bytes per second | no |
| **Ports** | Listening TCP sockets, flagged **local** vs **exposed** | partial |
| **Processes** | Top consumers by CPU and by memory | no |
| **Power** | Watts for CPU, GPU and Neural Engine, plus per-cluster clock | **yes** |

Everything is auto-detected at runtime: core counts, cluster topology, RAM,
GPU cores, sensor layout. The same code adapts to any Mac.

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
`Ctrl+C` at that prompt to skip it — everything else still works.

The browser opens at `http://localhost:8765`.

### Keyboard

| Key | Action |
|---|---|
| `T` | Toggle light / dark theme |
| `P` | Pause / resume refresh |
| `R` | Restart the server |
| `D` | Stop and quit |

### Privacy

The server binds to `127.0.0.1` only — it is not reachable from your network.
There is no telemetry, no analytics, no outbound request of any kind. Nothing
is written to disk except a PID file that is deleted on exit.

### How it works

- **Per-core load** — `host_processor_info()` from Mach, via `ctypes`. Same
  source `psutil` uses, without the dependency.
- **Fans and temperatures** — the `AppleSMC` IOKit service, opened read-only.
  `powermetrics` dropped its `smc` sampler on Apple Silicon, so this is the
  only route to fan RPM. The SMC exposes thousands of keys; the code
  enumerates them once at startup and groups the live thermistors into
  families.
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

### Notes and gotchas

- **0 RPM is normal.** Apple Silicon Macs dissipate through the aluminum
  chassis and only spin the fans under sustained load.
- **P-core thermistors read 0 while that cluster is powered down.** The panel
  shows *reposo* rather than a misleading zero.
- **Listening ports are incomplete without sudo.** `lsof` only reveals your
  own processes otherwise; system daemons stay hidden.
- Change the port by editing `PUERTO` in `monitor.py`.

### Files

```
monitor.py               HTTP server and metric collection
smc.py                   fan and thermistor access through IOKit
dashboard.html           interface
Iniciar Monitor.command  double-click launcher
```

`smc.py` runs standalone for a quick sensor dump:

```bash
python3 smc.py
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

### Qué muestra

| Panel | Detalle | Requiere sudo |
|---|---|---|
| **CPU** | Rejilla de calor por núcleo, separada en clusters de eficiencia y rendimiento | no |
| **GPU** | Utilización de dispositivo, renderizador y teselador; VRAM en uso | no |
| **Ventiladores** | RPM reales, los iconos giran a velocidad proporcional | no |
| **Térmico** | Hasta 8 familias de sensores (núcleos P y E, GPU, reguladores, chasis, batería, SSD, entrada de aire) | no |
| **Memoria** | Desglose apps / anclada / comprimida / caché, swap y presión | no |
| **Batería** | Carga, flujo en vatios, ciclos, salud, temperatura de celdas | no |
| **Caudal** | Red y disco, bytes por segundo | no |
| **Puertos** | Sockets TCP en escucha, marcados **local** o **expuesto** | parcial |
| **Procesos** | Mayores consumidores por CPU y por memoria | no |
| **Consumo** | Vatios de CPU, GPU y Neural Engine, más frecuencia por cluster | **sí** |

Todo se detecta en ejecución: número de núcleos, topología de clusters, RAM,
núcleos de GPU y disposición de sensores. El mismo código se adapta a
cualquier Mac.

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

El navegador se abre en `http://localhost:8765`.

### Teclas

| Tecla | Acción |
|---|---|
| `T` | Alternar tema claro / oscuro |
| `P` | Pausar / reanudar el refresco |
| `R` | Reiniciar el servidor |
| `D` | Detener y salir |

### Privacidad

El servidor escucha solo en `127.0.0.1`, así que no es alcanzable desde tu red.
No hay telemetría, ni analítica, ni ninguna petición saliente. Lo único que se
escribe a disco es un archivo de PID que se borra al salir.

### Cómo funciona

- **Carga por núcleo** — `host_processor_info()` de Mach, vía `ctypes`. Es la
  misma fuente que usa `psutil`, sin la dependencia.
- **Ventiladores y temperaturas** — el servicio IOKit `AppleSMC`, abierto solo
  para lectura. `powermetrics` eliminó su sampler `smc` en Apple Silicon, así
  que esta es la única vía a las RPM. El SMC expone miles de claves; el código
  las enumera una vez al arrancar y agrupa los termistores activos en familias.
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

### Detalles que conviene saber

- **0 RPM es normal.** Los Mac con Apple Silicon disipan por el chasis de
  aluminio y solo mueven los ventiladores bajo carga sostenida.
- **Los termistores de los núcleos P leen 0 mientras el cluster está apagado.**
  El panel muestra *reposo* en vez de un cero engañoso.
- **Los puertos en escucha quedan incompletos sin sudo.** `lsof` solo revela
  tus propios procesos; los demonios del sistema no aparecen.
- El puerto se cambia editando `PUERTO` en `monitor.py`.

### Archivos

```
monitor.py               servidor HTTP y recolección de métricas
smc.py                   acceso a ventiladores y termistores vía IOKit
dashboard.html           interfaz
Iniciar Monitor.command  lanzador de doble clic
```

`smc.py` se ejecuta por sí solo para un volcado rápido de sensores:

```bash
python3 smc.py
```

### Licencia

MIT
