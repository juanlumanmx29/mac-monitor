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
dashboard.html           interfaz completa: HTML + CSS + JS en un solo archivo
Iniciar Monitor.command  lanzador de doble clic
```

El servidor expone `GET /` (el dashboard), `GET /api/metrics` (JSON con todo
el estado) y `POST /api/control` (`{"accion":"detener"|"reiniciar"}`).

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

### Ciclo de vida

- **El servidor sale con código 42 para pedir reinicio.** El lanzador lo
  interpreta en su bucle y lo relanza. Cualquier otro código termina.
- **El lanzador debe atrapar `HUP`**, que es la señal que envía Terminal al
  cerrar la ventana, y ejecuta `python3` en segundo plano con `wait`: en
  primer plano bash no atiende señales hasta que el hijo termina.
- El servidor instala manejadores de `SIGTERM`, `SIGHUP` y `SIGINT` para
  cerrar el socket y matar `powermetrics` antes de salir.
- `.monitor.pid` permite al lanzador cerrar una instancia anterior. Está en
  `.gitignore`.

## Verificación antes de publicar

No basta con que el servidor arranque. Comprobar siempre:

```bash
# Sintaxis
python3 -c "import ast;ast.parse(open('monitor.py').read())"
python3 -c "import ast;ast.parse(open('smc.py').read())"
bash -n "Iniciar Monitor.command"

# Sensores sin levantar el servidor
python3 smc.py

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
