# Telemetría

Repositorio `mac-monitor`. Desde la versión 2 es una app nativa de macOS
(AppKit + SwiftUI): icono con cifras en la barra de menú, desplegable con el
resumen y ventana con el detalle de cada módulo. Sin servidor, sin sudo y sin
dependencias. Ver `README.md` para el uso. La versión 1 (servidor Python y
panel web) está en la etiqueta `v1-python`.

> **Repositorio público**: https://github.com/juanlumanmx29/mac-monitor.
> Nada de lo que se escriba aquí puede contener rutas personales, nombres de
> usuario, direcciones IP, seriales ni datos de un equipo concreto (tampoco en
> ejemplos ni capturas).

## Arquitectura

```
Sources/Telemetria/
  main.swift            arranque, instancia única, modos --volcar / --medir / --icono / --capturas / --pagina / --fondo
  Motor.swift           qué se lee y cada cuánto (visible 1 s, fondo 5 s, Demanda por página); Foto, Historial, Preferencias
  Sistema.swift         sysctl, procesos auxiliares, IOKit, reloj monótono
  Equipo.swift          topología detectada al arrancar, CPU por núcleo, memoria
  SMC.swift             ventiladores, termistores, potencia del equipo (PSTR)
  IOReport.swift        vatios de CPU/GPU/ANE/DRAM, frecuencias por cluster y por núcleo, estados de la GPU, presión térmica
  Hardware.swift        GPU, batería, red, disco
  Procesos.swift        tabla de procesos (kinfo + libproc + ps para ajenos), launchd
  Servicios.swift       puertos (libproc), reposo (IOPM), energía (top), total de hilos
  Vigilancia.swift      reglas: olvidado, desbocado, zombi, detenido, reposo
  Ventanas.swift        app responsable de un proceso, para traer su ventana al frente
  Modelo.swift          Modulo, Interfaz (estado observable y acciones), Resumen de cada módulo
  Tema.swift            paleta dinámica (oscuro/claro), Rotulo, Insignia
  Componentes.swift     Panel, FilaDato, Cifra, Anillo, barras, Grafico, Celda, Helice, Reticula
  VistaPrincipal.swift  NavigationSplitView, barra lateral, pie con el gasto propio, marco de página
  Resumen.swift         página de tarjetas
  DetallesEquipo.swift, DetallesActividad.swift   una vista por módulo
  Ventana.swift         NSWindow (se destruye al cerrar) y menú principal con atajos
  BarraMenu.swift       NSStatusItem, menú y desplegable
  Notificaciones.swift  UNUserNotificationCenter, con osascript de respaldo
  Logo.swift            icono de la app (Core Graphics)
  Volcado.swift, Capturas.swift   diagnóstico
```

## Reglas duras

1. **Solo Command Line Tools, sin Xcode.** Las macros de SwiftUI no compilan:
   nada de `@State`, `@Entry`, `@Observable` ni `#Preview`. En su lugar
   `private let x = State(initialValue:)` con `x.wrappedValue` y
   `x.projectedValue`, y `ObservableObject` + `@Published`.
2. **Sin dependencias y sin sudo.** Todo se lee como usuario normal. Si algo
   parece exigir root, casi siempre hay una vía por IOKit, IOReport, libproc o
   sysctl; si no la hay, se degrada (como los puertos de otros usuarios).
3. **Nada del hardware va fijo en el código.** Núcleos, clusters, RAM, GPU,
   sensores y tablas de frecuencia se detectan en ejecución.
4. **Degradar, no romper.** Cada fuente puede faltar (Mac Intel, Mac de
   escritorio, API privada que cambie): la vista muestra «—» o «sin datos».
5. **Idioma.** Identificadores y comentarios en español sin acentos; acentos
   solo en los textos que ve el usuario.
6. **Gasto mínimo.** Con la ventana cerrada solo corren la vigilancia y lo que
   muestre la barra de menú, cada 5 s. Antes de añadir una lectura, decidir en
   qué régimen y con qué cadencia va, y medir con `--medir`.

## Trampas ya encontradas

### Fuentes de datos

- **macOS 27 filtra `net.inet.tcp.pcblist_n`** para cualquier proceso que no
  sea de Apple y para sus hijos, también lanzado como .app: `netstat -anv`
  lanzado desde la app devuelve la lista vacía (desde una terminal funciona,
  lo que despista). Los puertos salen de libproc (`PROC_PIDLISTFDS` +
  `PROC_PIDFDSOCKETINFO`), como `lsof`: solo procesos propios.
- **`PROC_PIDTASKINFO` y `proc_pid_rusage` fallan con los procesos de otros
  usuarios.** Su CPU y memoria salen de `ps` (setuid root), solo para esos
  pids (`-p`), cada 5 s si la página muestra procesos y cada 30 s si no. Cada
  medida guarda su instante (`tsCPU`): las fotos de la vigilancia mezclan
  cadencias y la CPU sostenida se calcula con esos instantes.
- **Los tiempos de CPU de libproc vienen en unidades de Mach**, no en
  nanosegundos: en Apple Silicon la base es 125/3 (`Sys.segundos(mach:)`).
- **`devname` cuesta ~0,6 ms por llamada**: se cachea por dispositivo. Sin
  caché eran 15 ms por ciclo.
- **`KERN_PROCARGS2`** se lee con un búfer de `kern.argmax` reutilizado y se
  cachea por (pid, inicio). `proc_pidpath` funciona para todos los procesos.
- **La estructura del SMC se arma byte a byte** (80 bytes, desplazamientos de
  C). Una struct de Swift pone el campo siguiente en el relleno final de la
  struct anidada `keyInfo` y desalinea todo. El byte 40 es el resultado del
  SMC: distinto de 0 es error aunque IOKit devuelva éxito.
- **El descubrimiento del SMC (~3000 claves) se guarda en las preferencias**
  por modelo y versión del sistema; solo se recorre la primera vez.
- **IOReport es privado**: se enlaza con `dlsym` y se suscribe solo a los
  canales usados. El subgrupo «CPU Complex Performance States» trae también
  `ECPM`, `PCPM_IDLE`…: solo cuentan `ECPU`, `PCPU`, `PCPU1`.
- **Las tablas de frecuencia están en el nodo `pmgr`** (`voltage-states1-sram`
  E, `5-sram` P, `9` GPU): pares de 32 bits (frecuencia, voltaje), en Hz hasta
  M3 y en kHz desde M4. La de la GPU empieza con un 0 que no es un estado. Si
  el número de estados no cuadra se busca otra tabla plausible o se omiten los
  MHz.
- **Con batería, IOReport congela la energía de CPU, DRAM y ANE** (comprobado
  con intervalos de 1 a 10 s y en todos los grupos: solo avanza `GPU Energy`).
  Si la CPU está activa y su contador no se mueve, esos bloques quedan en nil
  (`bloquesCongelados`) y la página lo explica. El total (`PSTR`) sí funciona.
  El SMC tiene más claves de potencia (`PHPC`, `PMVC`, `PZC0`…) pero sin
  significado documentado: no usarlas sin verificarlas.
- **Dos lecturas de IOReport o de la CPU con menos de 0,3 s** dan ruido (pasa
  al cambiar la visibilidad, que fuerza un ciclo inmediato): se repite la
  última.
- **La batería en macOS 27** ya no publica `Temperature` ni `DesignCapacity`
  en el nivel superior: van dentro de `BatteryData` o faltan. La temperatura
  sale de la familia `TB` del SMC. La salud sale de `system_profiler` (cada
  6 h, aparte): la proporción del registro da un punto menos que Ajustes.
- **Consumo del equipo**: con batería, lo que entrega la batería (amperaje ×
  voltaje); enchufado, `SystemLoad` de `PowerTelemetryData` (la carga del
  sistema, sin lo que va a la batería); sin batería, `PSTR`. `PSTR` del SMC
  se queda corto frente a los otros dos (7,6 W frente a 22,3 W de descarga,
  18,8 frente a 28,2 W enchufado): no cuenta todos los componentes. Se
  muestra aparte como referencia.
- **Red**: contadores de 64 bits (`NET_RT_IFLIST2`), solo interfaces `en*`.
  Los `utun` de una VPN repetirían el mismo tráfico.
- **`top -o power` cuesta medio segundo de CPU.** Solo se lanza si la página
  lo pide (`Demanda`): cada 30 s con Energía abierta, cada 2 min en el
  resumen. Su cabecera trae el total de hilos; si no corre, `top -l 1` cada
  30 s con la página de CPU.
- **La app responsable de un proceso** sale de
  `responsibility_get_pid_responsible_for_pid` (privada, `dlsym`): un
  `WebContent` lleva a Safari y un `node` de la terminal integrada a VS Code.
  Si falta, se sube por los padres.

### Interfaz

- **La ventana se destruye al cerrarse** (vista de SwiftUI incluida) y la app
  vuelve a `.accessory`. Mantenerla oculta seguiría recalculando vistas.
- **En fondo la `Foto` es parcial** (`completa = false`): `Interfaz.recibir`
  la ignora y solo la usa la barra de menú.
- **El título de la barra de menú es AppKit**, no SwiftUI, y solo se reasigna
  si cambia el texto: cada cambio redibuja las réplicas del ítem (~0,4 % de CPU
  a 1 s).
- **Los gráficos solo siguen el cursor si son interactivos** (`Lector`): en
  las miniaturas el seguimiento era trabajo sin uso.
- **La hélice gira con `CABasicAnimation`** en el servidor de render. Una
  animación de SwiftUI o un `TimelineView` gastaría CPU por cuadro.
- **El eje x de los gráficos es tiempo real**: los huecos de más de 12 s
  (ventana cerrada) se dibujan como cortes.
- **`ImageRenderer` no dibuja `Table` ni vistas de AppKit**: `--capturas`
  usa la ventana real, transparente e ignorando el ratón. La memoria en ese
  modo no es representativa (los mapas de bits se acumulan).
- **La tabla de procesos va aislada** (`TablaDeProcesos`, `.equatable()`) y
  sus filas se renuevan cada 3 s (`procesosTabla`): redibujar ~1000 filas cada
  segundo costaba 7 % de CPU, más que el resto de la ventana junta. Sin
  tooltips por fila.
- **Asunto abierto**: al montar la tabla de procesos, AppKit avisa una vez de
  «reentrant operation in its NSTableView delegate». No viene de los bindings
  (comprobado: no se llaman al montar) ni sale con la tabla de puertos; parece
  interno del `Table` de SwiftUI con muchas filas. Vigilar si en otra versión
  de macOS pasa a ser un assert.
- **Sin menú Edición, el buscador no acepta ⌘C ni ⌘V**: `Menus` lo incluye.
- **Los textos de procesos van en `Text`**, que no interpreta marcado: no hace
  falta escapar nada (en el panel web sí).

## Verificación

No basta con que compile:

```bash
./construir.sh
F="build.noindex/Telemetría.app/Contents/MacOS/Telemetria"

# Datos reales de cada fuente; con TELEMETRIA_PERFIL=1, ms por tramo del ciclo
$F --volcar

# Gasto del motor sin interfaz, en cada régimen
$F --medir 40 fondo
$F --medir 40 visible

# Todas las páginas y el desplegable en PNG (revisarlos), en oscuro y claro
$F --capturas /ruta/temporal/capturas
$F --capturas /ruta/temporal/capturas claro

# La app real: CPU con `ps -o time= -p <pid>` en dos instantes y memoria con
# `vmmap -summary <pid>` (Physical footprint), con la ventana cerrada (--fondo)
# y abierta en una página (--pagina resumen|cpu|procesos...)
```
