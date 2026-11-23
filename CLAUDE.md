# mac-monitor

Panel de telemetría local para macOS. Servidor HTTP en `127.0.0.1:8765` que
sirve un dashboard leído en el navegador. **Repositorio público**:
https://github.com/juanlumanmx29/mac-monitor

> Este archivo se publica junto al código. No incluir rutas personales,
> nombres de usuario, direcciones IP, seriales ni nada específico de un
> equipo concreto.

## Arquitectura

```
monitor.py               servidor HTTP + recolección de métricas
smc.py                   ventiladores y termistores vía IOKit (importado por monitor.py)
vigilancia.py            procesos olvidados, fantasmas y desbocados (hilo propio, importado por monitor.py)
dashboard.html           interfaz completa: HTML + CSS + JS en un solo archivo
Iniciar Monitor.command  lanzador estándar del skill `command` (versión 2.2)
```

El servidor expone `GET /` (el dashboard) y `GET /api/metrics` (JSON con todo
el estado). No hay endpoint de control: arrancar, reiniciar y detener se hace
desde la ventana del lanzador (teclas `a` `r` `d` `n` `l` `q`).
En `/api/metrics`, el bloque `vigilancia` trae alertas, bloqueos de reposo y
energía, y cada fila de `procesos`, `procesos_mem` y `puertos` lleva `info`
con la ficha del proceso (nombre completo, guion, vida, padre, huérfano).

La interfaz son tres filas de carrusel con tarjetas del mismo tamaño; el
detalle de cada una se abre en una ventana flotante (`.modal`), una a la vez.

## Reglas duras

1. **Sin dependencias.** Solo la stdlib del Python 3.9 que trae macOS. Nada
   de `pip install`, Homebrew ni Node. Si algo parece necesitar una
   librería, casi siempre hay una vía por `ctypes`, `ioreg` o `sysctl`.
2. **Nada del hardware va fijo en el código.** Núcleos, clusters, RAM,
   GPU y sensores se detectan en ejecución y viajan al frontend en
   `payload.equipo`. Escribir "14 núcleos" o "M4 Pro" rompe el proyecto en
   cualquier otro Mac.
3. **Idioma.** Identificadores y comentarios en español **sin acentos**
   (`nucleos`, `bateria`, `disponible`). Los acentos solo en cadenas que ve
   el usuario. En JS y HTML sí se acentúa con normalidad.
4. **Degradar, no romper.** Cada fuente de datos puede fallar: sin sudo no
   hay vatios, un Mac Intel no tiene clusters híbridos, un equipo sin
   ventiladores devuelve lista vacía. Siempre hay que seguir funcionando.

## Trampas ya encontradas

Cada una costó una sesión de depuración. No reintroducirlas.

### Frontend

- **Un `<span>` es `display:inline` y el navegador ignora su `width`.** Las
  barras de progreso necesitan `display:block` explícito o se quedan vacías
  sin dar ningún error.
- **Reescribir `innerHTML` de un elemento destruye los ids de sus hijos.**
  Si el código luego busca ese hijo, recibe `null` y la excepción aborta el
  resto del ciclo de render, dejando media interfaz en blanco. Ningún
  contenedor cuyo `innerHTML` se reescriba debe contener ids.
- **Un canvas oculto no tiene dimensiones.** Al mostrarlo hay que repintar
  tras **dos** `requestAnimationFrame`: el primero aplica el cambio de
  clase, el segundo garantiza que el layout ya está calculado.
- **Los canvas no heredan variables CSS.** Los colores se leen con
  `cssVar()` / `rgbVar()` en el momento de pintar, y hay que repintar al
  cambiar de tema. Por eso los colores viven como tripletas RGB en `:root`.
- **`tag()` acepta `null` a propósito.** Algunas etiquetas solo existen
  dentro de un panel de detalle que puede estar cerrado.
- **El `catch` del ciclo distingue fallo de red de error de render.**
  Tratarlos igual disfraza los bugs de JavaScript como desconexiones.
- **`hidden` no oculta un `<button>`.** La regla `button{display:flex}` pisa
  el estilo del navegador; por eso existe `[hidden]{display:none!important}`.
- **`overflow:hidden` en `.det` rompe la cabecera fija del detalle.** Convierte
  la sección en contenedor de desplazamiento y `position:sticky` deja de
  funcionar.
- **Las tarjetas de alerta se rehacen por `innerHTML`** dentro de
  `#alertasFila` (con `display:contents`, para que cuenten como tarjetas del
  carril): nada de ids dentro. Solo se reconstruyen cuando cambia su firma; si
  se rehacen cada segundo, un clic cae sobre un botón que ya no existe.
- **Todo texto que venga de un proceso se escapa** con `esc()`, y dentro de un
  `data-tip` con `escTip()` + `attr()`. Un proceso puede ponerse el nombre que
  quiera, y en los tooltips la barra `|` separa párrafos.
- **El lienzo de cada tarjeta se redimensiona por atributo**, no por CSS: su
  alto depende de la pantalla y estirarlo por CSS deforma la línea.

### Backend

- **`powermetrics` corre como root** porque se lanza con `sudo`. Un
  `terminate()` desde el proceso padre sin privilegios devuelve `EPERM` y
  lo deja vivo: hay que matarlo con `sudo -n kill`.
- **El descubrimiento del SMC recorre más de 3000 claves** y tarda cerca de
  un segundo. Corre en un hilo aparte para que el socket abra de inmediato;
  hacerlo en línea provoca que el navegador se abra antes que el servidor.
- **`InstantAmperage` de `ioreg` llega como entero sin signo de 64 bits.**
  Al descargar es negativo: sin revertir el complemento a dos salen
  consumos absurdos.
- **Los termistores de los núcleos P devuelven 0 con el cluster apagado.**
  Sus claves se conservan igualmente en el descubrimiento, o la familia
  desaparecería y reaparecería del panel de forma intermitente.
- **`ps -o thcount` es sintaxis de Linux.** El `ps` BSD de macOS no la
  tiene; los totales de procesos e hilos salen de la cabecera de `top`.
- **`lsof` sin sudo solo ve los procesos del propio usuario.** El código lo
  intenta con `sudo -n` primero y cae a la versión sin privilegios.
- Las llamadas costosas van cacheadas (`CacheSimple`, `CachePuertos`) para
  que la latencia de `/api/metrics` se mantenga por debajo de ~100 ms.

### Vigilancia

- **`comm` y `args` de `ps` pueden llevar espacios.** Cada uno tiene que ir
  en la última columna, así que son dos llamadas a `ps` unidas por pid.
- **El python de las Command Line Tools vive dentro de un `Python.app`.**
  Contarlo como app haría invisibles todos los guiones de Python olvidados.
- **Un proceso cuenta como olvidado solo si nadie lo mantiene**: subiendo por
  sus padres hasta launchd no aparece ninguna terminal, ninguna app, ningún
  trabajo de `launchctl list` ni ninguna ruta del sistema. Sin la lista de
  launchd la regla no se evalúa: sin ella, Redis o cualquier agente de
  usuario saldrían como huérfanos.
- **La CPU sostenida sale de fotos de CPU acumulada cada 30 s**, no del
  `%cpu` de `ps`, que decae. El promedio de toda la vida solo se usa como
  respaldo al arrancar, y solo si la vida es al menos diez veces la ventana.
- **Las notificaciones pasan los textos como argumentos de `osascript`**,
  nunca dentro del código AppleScript, y se lanzan en un hilo con `run()`: un
  `Popen` sin esperar deja zombis del propio monitor, que la vigilancia
  detectaría.
- **`top -o power` cuesta casi medio segundo de CPU.** Solo se mide cada 30 s
  y mientras alguien consultó el panel en el último minuto.

### Ciclo de vida

- **El lanzador es la plantilla del skill `command`, igual que el de los
  demás proyectos.** No se edita a mano: se regenera desde la plantilla
  conservando sus variables. Lo único propio es `ANTES`, que pide sudo una
  vez (con un renovador del ticket cada 50 s) y abre el navegador cuando el
  puerto responde. Ctrl+C en la contraseña solo la omite.
- **Se versiona aquí, a diferencia de los demás proyectos** (la regla 2 del
  skill): es la puerta de entrada del proyecto público y no lleva rutas ni
  nada de este equipo; `APP` se calcula desde su propia ubicación.
- **El servidor solo tiene que cerrar bien ante `SIGTERM`.** Al detener, el
  lanzador manda TERM a todo el árbol y KILL a los 5 s. El manejador cierra
  el socket, para la vigilancia y mata `powermetrics` con `sudo -n kill`
  (es de root); si eso falla, `powermetrics` muere igual al romperse su
  tubería con Python.
- El puerto sale de `MONITOR_PUERTO` (8765 por defecto) y tiene que
  coincidir con `PUERTO` en el lanzador.

## Verificación antes de publicar

No basta con que el servidor arranque. Comprobar siempre:

```bash
# Sintaxis
python3 -c "import ast;ast.parse(open('monitor.py').read())"
python3 -c "import ast;ast.parse(open('smc.py').read())"
python3 -c "import ast;ast.parse(open('vigilancia.py').read())"
bash -n "Iniciar Monitor.command"

# Sensores y vigilancia sin levantar el servidor
python3 smc.py
python3 vigilancia.py

# El servidor responde y entrega datos completos
python3 monitor.py &
curl -s --retry 20 --retry-connrefused --retry-delay 1 http://localhost:8765/api/metrics | python3 -m json.tool | head -40
```

Para el JavaScript, macOS trae un motor que permite validarlo de verdad
sin navegador (`new Function` parsea sin ejecutar):

```bash
python3 -c "import re;open('/tmp/p.js','w').write(re.search(r'<script>(.*?)</script>',open('dashboard.html').read(),re.S).group(1))"
osascript -l JavaScript -e 'function run(){var s=ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError("/tmp/p.js",4,null));try{new Function(s);return "OK"}catch(e){return "ERROR: "+e.message}}'
```

Y comprobar la coherencia del DOM: que ningún `$('id')` apunte a un
elemento inexistente, que no haya ids duplicados y que toda función
invocada desde un atributo `on*` esté definida.

## Cuidado al tocar

- `dashboard.html` supera las mil líneas. Editar con `sed` o scripts
  puntuales en vez de reescribir el archivo entero.
- El `.command` lleva un espacio en el nombre: siempre entre comillas.
- Al mover marcado entre zonas, verificar ids duplicados: es el fallo más
  probable de esas refactorizaciones.
- Una tarjeta nueva necesita las cuatro piezas: la tarjeta en su fila (ids
  `vv_`, `vs_`, `vx_`, `vc_` + clave corta), su `<section class="det">`, su
  entrada en `MODULOS` (fija el orden de las teclas 1-9) y sus claves en
  `UNIDAD`, `H` y `pintarVitales`.
- Para revisar el render sin tocar la pantalla: Chrome headless con un
  perfil temporal y `--screenshot`, apuntando a `/#clave` para abrir un
  detalle.
