#!/usr/bin/env python3
"""
Monitor de sistema para Mac.

Servidor HTTP local sin dependencias externas: solo stdlib de Python 3.9,
que es lo que trae macOS de fabrica. Toda la informacion del equipo
(nucleos, memoria, GPU, sensores) se detecta en ejecucion, asi que el
mismo codigo sirve en cualquier Mac.

Codigos de salida:
    0   detencion limpia (boton Detener)
    42  reinicio solicitado (el lanzador .command lo relanza)
"""

import ctypes
import ctypes.util
import json
import os
import platform
import re
import signal
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import smc as modulo_smc

PUERTO = 8765
RAIZ = os.path.dirname(os.path.abspath(__file__))

CODIGO_REINICIO = 42


# --------------------------------------------------------------------------
# CPU por nucleo: host_processor_info() via ctypes
# --------------------------------------------------------------------------

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libc.mach_host_self.restype = ctypes.c_uint

_CPU_STATE_MAX = 4
_CPU_STATE_IDLE = 2
_PROCESSOR_CPU_LOAD_INFO = 2


def _ticks_por_nucleo():
    """Devuelve [[user, system, idle, nice], ...] en ticks acumulados."""
    n = ctypes.c_uint(0)
    info = ctypes.POINTER(ctypes.c_uint)()
    count = ctypes.c_uint(0)
    rc = _libc.host_processor_info(
        _libc.mach_host_self(), _PROCESSOR_CPU_LOAD_INFO,
        ctypes.byref(n), ctypes.byref(info), ctypes.byref(count))
    if rc != 0:
        raise OSError("host_processor_info fallo con codigo %d" % rc)
    return [[info[i * _CPU_STATE_MAX + s] for s in range(_CPU_STATE_MAX)]
            for i in range(n.value)]


class LectorCPU:
    """Calcula uso por nucleo entre dos lecturas consecutivas."""

    def __init__(self):
        self.previo = _ticks_por_nucleo()

    def leer(self):
        actual = _ticks_por_nucleo()
        nucleos = []
        for i, (ant, act) in enumerate(zip(self.previo, actual)):
            delta = [b - a for a, b in zip(ant, act)]
            total = sum(delta)
            uso = 100.0 * (total - delta[_CPU_STATE_IDLE]) / total if total else 0.0
            nucleos.append({
                "id": i,
                # Los nucleos de eficiencia se enumeran primero. Sin cluster
                # de eficiencia (Intel) todos quedan marcados como P.
                "tipo": "E" if i < NUCLEOS_E else "P",
                "uso": round(max(0.0, min(100.0, uso)), 1),
            })
        self.previo = actual

        eficiencia = [c["uso"] for c in nucleos if c["tipo"] == "E"]
        rendimiento = [c["uso"] for c in nucleos if c["tipo"] == "P"]
        promedio = lambda xs: round(sum(xs) / len(xs), 1) if xs else 0.0

        return {
            "nucleos": nucleos,
            "total": promedio([c["uso"] for c in nucleos]),
            "e_promedio": promedio(eficiencia),
            "p_promedio": promedio(rendimiento),
            "carga": [round(x, 2) for x in os.getloadavg()],
        }


# --------------------------------------------------------------------------
# Memoria: vm_stat + sysctl
# --------------------------------------------------------------------------

def _sysctl(clave):
    try:
        out = subprocess.check_output(["sysctl", "-n", clave],
                                      stderr=subprocess.DEVNULL, timeout=3)
        return out.decode().strip()
    except Exception:
        return ""


_RAM_TOTAL = int(_sysctl("hw.memsize") or 0)
_TAM_PAGINA = int(_sysctl("vm.pagesize") or 16384)


# --------------------------------------------------------------------------
# Topologia del equipo, detectada al arrancar
# --------------------------------------------------------------------------

def _entero(clave, por_defecto=0):
    try:
        return int(_sysctl(clave))
    except ValueError:
        return por_defecto


# En Apple Silicon perflevel0 es el cluster de rendimiento y perflevel1 el de
# eficiencia. Los Mac Intel no publican estas claves: ahi todos los nucleos
# son equivalentes y se tratan como un unico grupo.
NUCLEOS_P = _entero("hw.perflevel0.logicalcpu")
NUCLEOS_E = _entero("hw.perflevel1.logicalcpu")
NUCLEOS_TOTAL = _entero("hw.ncpu", 1)

if not NUCLEOS_P:                      # Intel o topologia desconocida
    NUCLEOS_P, NUCLEOS_E = NUCLEOS_TOTAL, 0

HIBRIDO = NUCLEOS_E > 0


def _nucleos_gpu():
    try:
        salida = subprocess.check_output(
            ["ioreg", "-r", "-d", "1", "-c", "IOAccelerator", "-w0"],
            stderr=subprocess.DEVNULL, timeout=5).decode()
        m = re.search(r'"gpu-core-count"\s*=\s*(\d+)', salida)
        return int(m.group(1)) if m else None
    except Exception:
        return None


def _version_macos():
    try:
        return subprocess.check_output(
            ["sw_vers", "-productVersion"],
            stderr=subprocess.DEVNULL, timeout=5).decode().strip()
    except Exception:
        return ""


EQUIPO = {
    "chip": _sysctl("machdep.cpu.brand_string") or "CPU",
    "modelo": _sysctl("hw.model"),
    "cpu_total": NUCLEOS_TOTAL,
    "cpu_e": NUCLEOS_E,
    "cpu_p": NUCLEOS_P,
    "hibrido": HIBRIDO,
    "ram": _RAM_TOTAL,
    "gpu_nucleos": _nucleos_gpu(),
    "macos": _version_macos(),
    "arquitectura": platform.machine(),
}


def leer_memoria():
    """Replica el calculo de 'Memoria usada' del Monitor de Actividad."""
    try:
        salida = subprocess.check_output(["vm_stat"], timeout=3).decode()
    except Exception:
        return {"disponible": False}

    paginas = {}
    for linea in salida.splitlines():
        m = re.match(r'^"?([^":]+)"?:\s+(\d+)', linea.strip())
        if m:
            paginas[m.group(1).strip()] = int(m.group(2))

    p = lambda k: paginas.get(k, 0) * _TAM_PAGINA

    libre = p("Pages free")
    anonimas = p("Anonymous pages")
    purgables = p("Pages purgeable")
    ancladas = p("Pages wired down")
    comprimidas = p("Pages occupied by compressor")

    # Mismo criterio que el Monitor de Actividad: la memoria "usada" no
    # incluye los archivos cacheados, que el sistema libera a demanda.
    apps = max(0, anonimas - purgables)
    usada = apps + ancladas + comprimidas
    cache = p("File-backed pages")

    # Swap
    swap_usado = swap_total = 0
    m = re.search(r"total = ([\d.]+)([MG]).*used = ([\d.]+)([MG])",
                  _sysctl("vm.swapusage"))
    if m:
        escala = {"M": 1024 ** 2, "G": 1024 ** 3}
        swap_total = int(float(m.group(1)) * escala[m.group(2)])
        swap_usado = int(float(m.group(3)) * escala[m.group(4)])

    return {
        "disponible": True,
        "total": _RAM_TOTAL,
        "usada": usada,
        "apps": apps,
        "ancladas": ancladas,
        "comprimidas": comprimidas,
        "cache": cache,
        "libre": libre,
        "swap_total": swap_total,
        "swap_usado": swap_usado,
        "pct": round(100.0 * usada / _RAM_TOTAL, 1) if _RAM_TOTAL else 0.0,
    }


# --------------------------------------------------------------------------
# Bateria: ioreg (rapido) + system_profiler (lento, cacheado)
# --------------------------------------------------------------------------

_cache_salud = {"valor": None, "ts": 0}


def _salud_bateria():
    """Capacidad maxima en %. Consulta lenta, se refresca cada 5 minutos."""
    ahora = time.time()
    if _cache_salud["valor"] is not None and ahora - _cache_salud["ts"] < 300:
        return _cache_salud["valor"]
    try:
        out = subprocess.check_output(
            ["system_profiler", "SPPowerDataType"],
            stderr=subprocess.DEVNULL, timeout=15).decode()
        m = re.search(r"Maximum Capacity:\s*(\d+)", out)
        _cache_salud["valor"] = int(m.group(1)) if m else None
    except Exception:
        _cache_salud["valor"] = None
    _cache_salud["ts"] = ahora
    return _cache_salud["valor"]


def leer_bateria():
    try:
        out = subprocess.check_output(
            ["ioreg", "-rn", "AppleSmartBattery"],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return {"disponible": False}

    def campo(nombre):
        m = re.search(r'"%s"\s*=\s*(-?\d+)' % nombre, out)
        return int(m.group(1)) if m else None

    def booleano(nombre):
        m = re.search(r'"%s"\s*=\s*(Yes|No)' % nombre, out)
        return (m.group(1) == "Yes") if m else None

    pct = campo("CurrentCapacity")
    amperaje = campo("InstantAmperage")
    voltaje = campo("Voltage")

    # ioreg entrega el amperaje como entero sin signo de 64 bits.
    # Al descargar el valor es negativo, asi que hay que revertir el
    # complemento a dos o aparecen consumos absurdos.
    if amperaje is not None and amperaje > 2 ** 63:
        amperaje -= 2 ** 64

    vatios = None
    if amperaje is not None and voltaje:
        vatios = round(abs(amperaje) * voltaje / 1e6, 2)

    temp = campo("Temperature")
    enchufado = booleano("ExternalConnected")
    cargando = booleano("IsCharging")

    if enchufado and cargando:
        estado = "cargando"
    elif enchufado:
        estado = "enchufado"
    else:
        estado = "descargando"

    restante = campo("TimeRemaining")
    if restante in (None, 0, 65535) or restante > 1440:
        restante = None

    return {
        "disponible": True,
        "pct": pct,
        "estado": estado,
        "vatios": vatios,
        "minutos_restantes": restante,
        "ciclos": campo("CycleCount"),
        "salud": _salud_bateria(),
        "temperatura": round(temp / 100.0, 1) if temp else None,
    }


# --------------------------------------------------------------------------
# powermetrics: potencia, frecuencias y presion termica (requiere sudo)
# --------------------------------------------------------------------------

class SensorPotencia:
    """
    Mantiene powermetrics corriendo en streaming y parsea su salida.

    Lanzarlo una vez por muestra costaria ~1s cada vez, asi que se deja
    abierto y se lee de forma continua desde un hilo aparte.
    """

    def __init__(self):
        self.datos = {"disponible": False, "motivo": "iniciando"}
        self.proceso = None
        self._parar = threading.Event()
        self._hilo = threading.Thread(target=self._bucle, daemon=True)
        self._hilo.start()

    def _bucle(self):
        if not self._hay_sudo():
            self.datos = {"disponible": False,
                          "motivo": "sin permisos de sudo"}
            return

        cmd = ["sudo", "-n", "powermetrics",
               "--samplers", "cpu_power,gpu_power,ane_power,thermal",
               "-i", "1000"]
        try:
            self.proceso = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                bufsize=1, universal_newlines=True)
        except Exception as e:
            self.datos = {"disponible": False, "motivo": str(e)}
            return

        parcial = {}
        for linea in self.proceso.stdout:
            if self._parar.is_set():
                break
            linea = linea.strip()

            def num(patron):
                m = re.search(patron, linea)
                return float(m.group(1)) if m else None

            v = num(r"^CPU Power:\s+([\d.]+)\s*mW")
            if v is not None:
                parcial["cpu_mw"] = v
            v = num(r"^GPU Power:\s+([\d.]+)\s*mW")
            if v is not None:
                parcial["gpu_mw"] = v
            v = num(r"^ANE Power:\s+([\d.]+)\s*mW")
            if v is not None:
                parcial["ane_mw"] = v
            v = num(r"^Combined Power \(CPU \+ GPU \+ ANE\):\s+([\d.]+)\s*mW")
            if v is not None:
                parcial["total_mw"] = v
            v = num(r"^E-Cluster HW active frequency:\s+([\d.]+)\s*MHz")
            if v is not None:
                parcial["e_mhz"] = v
            v = num(r"^P-Cluster HW active frequency:\s+([\d.]+)\s*MHz")
            if v is not None:
                parcial["p_mhz"] = v
            v = num(r"^GPU HW active frequency:\s+([\d.]+)\s*MHz")
            if v is not None:
                parcial["gpu_mhz"] = v
            v = num(r"^GPU HW active residency:\s+([\d.]+)%")
            if v is not None:
                parcial["gpu_uso"] = v

            m = re.search(r"pressure level:\s*(\w+)", linea)
            if m:
                parcial["termico"] = m.group(1)

            # El bloque de una muestra termina con la linea de potencia
            # combinada; ahi se publica el conjunto completo.
            if "total_mw" in parcial:
                parcial["disponible"] = True
                self.datos = dict(parcial)
                parcial = {}

    @staticmethod
    def _hay_sudo():
        try:
            return subprocess.call(
                ["sudo", "-n", "true"],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                timeout=5) == 0
        except Exception:
            return False

    def detener(self):
        self._parar.set()
        if not self.proceso:
            return
        pid = self.proceso.pid
        # powermetrics corre como root porque se lanza con sudo, asi que un
        # terminate() desde este proceso sin privilegios devuelve EPERM y lo
        # deja vivo. Hay que pedirle a sudo que lo mate.
        for cmd in (["sudo", "-n", "kill", "-TERM", str(pid)],
                    ["sudo", "-n", "kill", "-KILL", str(pid)]):
            try:
                subprocess.call(cmd, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=4)
                if self.proceso.poll() is not None:
                    return
            except Exception:
                pass
        try:
            self.proceso.terminate()
        except Exception:
            pass


# --------------------------------------------------------------------------
# Procesos
# --------------------------------------------------------------------------

def leer_procesos(limite=8):
    """
    Los procesos mas pesados por CPU y por memoria.

    Una sola llamada a ps y dos ordenaciones en memoria: invocarlo dos
    veces (-r y -m) duplicaba el coste del muestreo sin necesidad.
    """
    try:
        out = subprocess.check_output(
            ["ps", "-Ao", "pid,pcpu,rss,comm"],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return [], []

    procesos = []
    for linea in out.splitlines()[1:]:
        partes = linea.split(None, 3)
        if len(partes) < 4:
            continue
        try:
            procesos.append({
                "pid": int(partes[0]),
                "cpu": float(partes[1]),
                "rss": int(partes[2]) * 1024,
                "nombre": os.path.basename(partes[3].strip())[:40],
            })
        except ValueError:
            continue

    por_cpu = sorted(procesos, key=lambda p: -p["cpu"])[:limite]
    por_mem = sorted(procesos, key=lambda p: -p["rss"])[:limite]
    return por_cpu, por_mem


# --------------------------------------------------------------------------
# GPU: IOAccelerator via ioreg
# --------------------------------------------------------------------------

def leer_gpu():
    """
    Uso de GPU sin privilegios.

    powermetrics tambien lo da, pero exige sudo. El driver AGX publica las
    mismas cifras en el registro de IOKit, legibles por cualquier usuario.
    """
    try:
        salida = subprocess.check_output(
            ["ioreg", "-r", "-d", "1", "-c", "IOAccelerator", "-w0"],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return {"disponible": False}

    m = re.search(r'"PerformanceStatistics"\s*=\s*\{([^}]*)\}', salida)
    if not m:
        return {"disponible": False}

    stats = {}
    for par in m.group(1).split(","):
        if "=" not in par:
            continue
        k, _, v = par.partition("=")
        stats[k.strip().strip('"')] = v.strip()

    def num(clave):
        try:
            return float(stats.get(clave, ""))
        except ValueError:
            return None

    nucleos = re.search(r'"gpu-core-count"\s*=\s*(\d+)', salida)
    en_uso = num("In use system memory")
    reservada = num("Alloc system memory")

    return {
        "disponible": True,
        "uso": num("Device Utilization %"),
        "render": num("Renderer Utilization %"),
        "tiler": num("Tiler Utilization %"),
        "vram_uso": en_uso,
        "vram_reservada": reservada,
        "nucleos": int(nucleos.group(1)) if nucleos else None,
    }


# --------------------------------------------------------------------------
# Sistema: procesos, hilos, arranque
# --------------------------------------------------------------------------

_ARRANQUE = 0.0
_m = re.search(r"sec\s*=\s*(\d+)", _sysctl("kern.boottime"))
if _m:
    _ARRANQUE = float(_m.group(1))


def leer_sistema():
    # 'thcount' es sintaxis de ps de Linux; el ps BSD de macOS no la tiene.
    # top publica ambos totales en su cabecera.
    procesos = hilos = None
    try:
        out = subprocess.check_output(["top", "-l", "1", "-n", "0"],
                                      stderr=subprocess.DEVNULL,
                                      timeout=8).decode()
        m = re.search(r"Processes:\s*(\d+) total.*?(\d+) threads", out, re.S)
        if m:
            procesos, hilos = int(m.group(1)), int(m.group(2))
    except Exception:
        pass
    return {
        "procesos": procesos,
        "hilos": hilos,
        "arranque": _ARRANQUE,
        "uptime": int(time.time() - _ARRANQUE) if _ARRANQUE else None,
    }


# --------------------------------------------------------------------------
# Caudal de red y disco (contadores acumulados -> tasa)
# --------------------------------------------------------------------------

def _bytes_red():
    """Bytes acumulados de todas las interfaces fisicas activas."""
    try:
        out = subprocess.check_output(["netstat", "-ib"],
                                      stderr=subprocess.DEVNULL,
                                      timeout=5).decode()
    except Exception:
        return None
    entrada = salida = 0
    vistas = set()
    for linea in out.splitlines()[1:]:
        c = linea.split()
        # Solo las filas con <Link#N>: las demas repiten los mismos
        # contadores una vez por direccion IP configurada.
        if len(c) < 11 or not c[2].startswith("<Link"):
            continue
        nombre = c[0]
        if nombre in vistas or nombre.startswith("lo"):
            continue
        vistas.add(nombre)
        try:
            entrada += int(c[6])
            salida += int(c[9])
        except (ValueError, IndexError):
            continue
    return entrada, salida


def _bytes_disco():
    try:
        out = subprocess.check_output(
            ["ioreg", "-r", "-c", "IOBlockStorageDriver", "-w0"],
            stderr=subprocess.DEVNULL, timeout=5).decode()
    except Exception:
        return None
    leidos = escritos = 0
    for bloque in re.findall(r'"Statistics"\s*=\s*\{([^}]*)\}', out):
        r = re.search(r'"Bytes \(Read\)"\s*=\s*(\d+)', bloque)
        w = re.search(r'"Bytes \(Write\)"\s*=\s*(\d+)', bloque)
        if r:
            leidos += int(r.group(1))
        if w:
            escritos += int(w.group(1))
    return leidos, escritos


class Caudal(object):
    """Convierte contadores acumulados en bytes por segundo."""

    def __init__(self, fuente):
        self.fuente = fuente
        self.previo = fuente()
        self.ts = time.time()
        self.tasa = (0.0, 0.0)

    def leer(self):
        actual = self.fuente()
        ahora = time.time()
        dt = ahora - self.ts
        if actual and self.previo and dt > 0.2:
            self.tasa = tuple(max(0.0, (a - p) / dt)
                              for a, p in zip(actual, self.previo))
            self.previo, self.ts = actual, ahora
        return {"entrada": round(self.tasa[0]), "salida": round(self.tasa[1])}


# --------------------------------------------------------------------------
# Puertos en escucha
# --------------------------------------------------------------------------

def leer_puertos():
    """
    Sockets TCP en LISTEN, con quien los abrio.

    Se intenta primero con sudo: sin privilegios lsof solo muestra los
    procesos del propio usuario, y los demonios del sistema quedarian
    invisibles. Si no hay ticket de sudo se cae a la version sin el.
    """
    salida = None
    for cmd in (["sudo", "-n", "lsof", "-nP", "-iTCP", "-sTCP:LISTEN"],
                ["lsof", "-nP", "-iTCP", "-sTCP:LISTEN"]):
        try:
            salida = subprocess.check_output(
                cmd, stderr=subprocess.DEVNULL, timeout=6).decode()
            break
        except Exception:
            continue
    if not salida:
        return []

    # Un mismo servicio suele aparecer dos veces, en IPv4 y en IPv6.
    # Se agrupa por (pid, puerto) y se acumulan los protocolos.
    agrupado = {}
    for linea in salida.splitlines()[1:]:
        campos = linea.split()
        if len(campos) < 9:
            continue
        proceso, pid, usuario, tipo = campos[0], campos[1], campos[2], campos[4]
        direccion = campos[8]
        if ":" not in direccion:
            continue
        host, _, puerto = direccion.rpartition(":")
        if not puerto.isdigit():
            continue

        # '*' y '0.0.0.0' significan todas las interfaces: alcanzable
        # desde la red local, no solo desde este equipo.
        expuesto = host in ("*", "0.0.0.0", "[::]", "::")

        clave = (pid, puerto)
        if clave in agrupado:
            agrupado[clave]["protocolos"].add(tipo)
            agrupado[clave]["expuesto"] |= expuesto
            continue
        agrupado[clave] = {
            "puerto": int(puerto),
            "pid": int(pid),
            "proceso": proceso.replace("\\x20", " ")[:28],
            "usuario": usuario,
            "host": host,
            "expuesto": expuesto,
            "protocolos": {tipo},
        }

    puertos = []
    for v in agrupado.values():
        v["protocolos"] = "/".join(sorted(v["protocolos"]))
        puertos.append(v)
    puertos.sort(key=lambda x: (not x["expuesto"], x["puerto"]))
    return puertos


# --------------------------------------------------------------------------
# Estado del servidor  (el monitor del monitor)
# --------------------------------------------------------------------------

class EstadoServidor:
    def __init__(self):
        self.inicio = time.time()
        self.muestras = 0
        self.ultima_latencia_ms = 0.0
        self.errores = 0

    def instantanea(self, sensor_potencia):
        return {
            "pid": os.getpid(),
            "puerto": PUERTO,
            "uptime": int(time.time() - self.inicio),
            "muestras": self.muestras,
            "latencia_ms": round(self.ultima_latencia_ms, 1),
            "errores": self.errores,
            "powermetrics": sensor_potencia.datos.get("disponible", False),
            "powermetrics_motivo": sensor_potencia.datos.get("motivo", ""),
            "smc": sensor_smc.disponible,
            "smc_motivo": sensor_smc.motivo,
            "sensores": sum(len(v) for v in sensor_smc.claves_temp.values()),
            "python": "%d.%d.%d" % sys.version_info[:3],
        }


# --------------------------------------------------------------------------
# Servidor HTTP
# --------------------------------------------------------------------------

class CachePuertos(object):
    """
    lsof cuesta cientos de milisegundos y los puertos en escucha cambian
    poco, asi que se refresca cada pocos segundos en vez de cada muestra.
    """

    def __init__(self, intervalo=4.0):
        self.intervalo = intervalo
        self.valor = []
        self.ts = 0.0
        self._lock = threading.Lock()

    def obtener(self):
        ahora = time.time()
        if ahora - self.ts < self.intervalo:
            return self.valor
        with self._lock:
            if time.time() - self.ts < self.intervalo:
                return self.valor
            self.valor = leer_puertos()
            self.ts = time.time()
        return self.valor


class CacheSimple(object):
    """Cachea una funcion costosa durante unos segundos."""

    def __init__(self, fn, intervalo):
        self.fn, self.intervalo = fn, intervalo
        self.valor, self.ts = None, 0.0
        self._lock = threading.Lock()

    def obtener(self):
        if time.time() - self.ts < self.intervalo and self.valor is not None:
            return self.valor
        with self._lock:
            if time.time() - self.ts < self.intervalo and self.valor is not None:
                return self.valor
            self.valor = self.fn()
            self.ts = time.time()
        return self.valor


lector_cpu = LectorCPU()
sensor_potencia = SensorPotencia()
sensor_smc = modulo_smc.SMC()
cache_puertos = CachePuertos()
cache_gpu = CacheSimple(leer_gpu, 1.0)
cache_sistema = CacheSimple(leer_sistema, 3.0)
caudal_red = Caudal(_bytes_red)
caudal_disco = Caudal(_bytes_disco)
estado = EstadoServidor()
accion_salida = {"codigo": 0}


class Handler(BaseHTTPRequestHandler):

    def log_message(self, *args):
        pass  # sin ruido en consola

    def _responder(self, codigo, cuerpo, tipo="application/json"):
        datos = cuerpo if isinstance(cuerpo, bytes) else cuerpo.encode("utf-8")
        self.send_response(codigo)
        self.send_header("Content-Type", tipo)
        self.send_header("Content-Length", str(len(datos)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(datos)
        except BrokenPipeError:
            pass

    def do_GET(self):
        if self.path == "/" or self.path.startswith("/index"):
            try:
                with open(os.path.join(RAIZ, "dashboard.html"), "rb") as f:
                    self._responder(200, f.read(), "text/html; charset=utf-8")
            except FileNotFoundError:
                self._responder(500, b"falta dashboard.html", "text/plain")
            return

        if self.path == "/api/metrics":
            t0 = time.time()
            try:
                procs_cpu, procs_mem = leer_procesos()
                carga = {
                    "ts": time.time(),
                    "cpu": lector_cpu.leer(),
                    "memoria": leer_memoria(),
                    "bateria": leer_bateria(),
                    "potencia": sensor_potencia.datos,
                    "ventiladores": sensor_smc.ventiladores(),
                    "temperaturas": sensor_smc.temperaturas(),
                    "puertos": cache_puertos.obtener(),
                    "gpu": cache_gpu.obtener(),
                    "sistema": cache_sistema.obtener(),
                    "red": caudal_red.leer(),
                    "disco": caudal_disco.leer(),
                    "procesos": procs_cpu,
                    "procesos_mem": procs_mem,
                    "equipo": EQUIPO,
                }
                estado.muestras += 1
            except Exception as e:
                estado.errores += 1
                self._responder(500, json.dumps({"error": str(e)}))
                return
            estado.ultima_latencia_ms = (time.time() - t0) * 1000
            carga["servidor"] = estado.instantanea(sensor_potencia)
            self._responder(200, json.dumps(carga))
            return

        self._responder(404, json.dumps({"error": "no encontrado"}))

    def do_POST(self):
        if self.path != "/api/control":
            self._responder(404, json.dumps({"error": "no encontrado"}))
            return

        largo = int(self.headers.get("Content-Length", 0) or 0)
        try:
            cuerpo = json.loads(self.rfile.read(largo) or b"{}")
        except Exception:
            cuerpo = {}
        accion = cuerpo.get("accion")

        if accion == "detener":
            accion_salida["codigo"] = 0
            self._responder(200, json.dumps({"ok": True, "accion": "detener"}))
            threading.Thread(target=_apagar, daemon=True).start()
            return

        if accion == "reiniciar":
            accion_salida["codigo"] = CODIGO_REINICIO
            self._responder(200, json.dumps({"ok": True, "accion": "reiniciar"}))
            threading.Thread(target=_apagar, daemon=True).start()
            return

        self._responder(400, json.dumps({"error": "accion desconocida"}))


servidor = None


def _apagar():
    time.sleep(0.4)  # deja que la respuesta HTTP salga antes de cerrar
    sensor_potencia.detener()
    if servidor:
        servidor.shutdown()


ARCHIVO_PID = os.path.join(RAIZ, ".monitor.pid")


def _al_recibir_senal(numero, _frame):
    """
    Cierre ordenado ante SIGTERM y SIGHUP.

    Sin esto Python muere de inmediato sin ejecutar el finally: el socket
    queda colgando y, peor, powermetrics sobrevive como huerfano de root.
    SIGHUP es el que manda Terminal al cerrar su ventana.
    """
    accion_salida["codigo"] = 0
    sensor_potencia.detener()
    if servidor:
        threading.Thread(target=servidor.shutdown, daemon=True).start()


def main():
    global servidor
    for s in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        signal.signal(s, _al_recibir_senal)

    servidor = ThreadingHTTPServer(("127.0.0.1", PUERTO), Handler)
    servidor.daemon_threads = True

    try:
        with open(ARCHIVO_PID, "w") as f:
            f.write(str(os.getpid()))
    except Exception:
        pass

    # El lanzador imprime el aviso completo cuando el puerto ya responde;
    # aqui basta una linea discreta para quien ejecute el script a mano.
    # flush explicito: con la salida redirigida, Python usa buffer de bloque
    # y la linea no aparece hasta que el proceso termina.
    print("  servidor escuchando en 127.0.0.1:%d (pid %d)"
          % (PUERTO, os.getpid()), flush=True)
    try:
        servidor.serve_forever()
    except KeyboardInterrupt:
        print("\nInterrumpido.")
    finally:
        sensor_potencia.detener()
        servidor.server_close()
        try:
            if os.path.exists(ARCHIVO_PID):
                os.remove(ARCHIVO_PID)
        except Exception:
            pass
    sys.exit(accion_salida["codigo"])


if __name__ == "__main__":
    main()
