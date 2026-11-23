#!/usr/bin/env python3
"""
Vigilancia de procesos: los olvidados, los fantasmas y los que no dejan
dormir al equipo.

Un hilo aparte lee la tabla de procesos cada pocos segundos aunque nadie
tenga el panel abierto: el caso que motivo este modulo fue un proceso que
paso dos dias consumiendo CPU sin que nadie lo viera. Si algo grave
aparece, se avisa con una notificacion del sistema.

Reglas:
    olvidado   proceso propio cuya terminal ya no existe: ni el ni ninguno
               de sus ancestros tiene terminal, ni depende de una app ni de
               launchd. Pasa a critico si consume CPU de forma sostenida.
    desbocado  cualquier proceso que mantiene casi un nucleo entero ocupado
               durante varios minutos.
    zombi      proceso terminado que su padre no ha recogido (estado Z).
    detenido   proceso propio suspendido (estado T, Ctrl+Z) desde hace rato.
    reposo     algo impide el reposo mientras el equipo va con bateria.

Uso aislado, sin levantar el servidor:
    python3 vigilancia.py           resumen legible
    python3 vigilancia.py --json    el mismo bloque que recibe el panel
"""

import collections
import json
import os
import re
import subprocess
import sys
import threading
import time

# --------------------------------------------------------------------------
# Umbrales
# --------------------------------------------------------------------------

MUESTREO = 5.0              # segundos entre lecturas de la tabla de procesos
INTERVALO_FOTO = 30.0       # cada cuanto se guarda la CPU acumulada de todos
VENTANA_OLVIDADO = 120.0    # CPU sostenida que convierte un olvidado en critico
UMBRAL_OLVIDADO = 20.0      # % de un nucleo
VENTANA_DESBOCADO = 600.0
UMBRAL_DESBOCADO = 90.0
MIN_ZOMBI = 10.0            # un zombi recien nacido es normal: su padre lo recoge enseguida
MIN_DETENIDO = 600.0
MIN_REPOSO = 1800.0         # bloqueo de reposo con bateria que merece aviso
INTERVALO_LAUNCHD = 30.0
INTERVALO_REPOSO = 15.0
INTERVALO_ENERGIA = 30.0
PANEL_ACTIVO = 60.0         # el panel cuenta como abierto si pidio datos hace menos de esto

# Programas que se separan de su terminal a proposito y viven asi.
DESACOPLADOS = {"gpg-agent", "ssh-agent", "dirmngr", "keyboxd", "scdaemon",
                "tmux", "screen", "mosh-server"}

# Para estos la etiqueta util es el guion que ejecutan, no el interprete.
INTERPRETES = {"bash", "zsh", "sh", "dash", "fish", "ksh", "tcsh", "python",
               "ruby", "perl", "php", "node", "deno", "bun", "osascript", "java"}

RUTAS_SISTEMA = ("/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/",
                 "/Library/Apple/", "/Library/PrivilegedHelperTools/")

ORDEN_NIVEL = {"crit": 0, "warn": 1, "info": 2}


# --------------------------------------------------------------------------
# Lectura de fuentes
# --------------------------------------------------------------------------

def _ejecutar(cmd, limite=5):
    try:
        return subprocess.check_output(
            cmd, stderr=subprocess.DEVNULL, timeout=limite
        ).decode("utf-8", "replace")
    except Exception:
        return None


def _segundos(texto):
    """'1-02:03:04', '02:03:04', '03:04' o '3:27.74' -> segundos."""
    dias = 0
    if "-" in texto:
        d, _, texto = texto.partition("-")
        dias = int(d)
    total = 0.0
    for parte in texto.split(":"):
        total = total * 60 + float(parte)
    return dias * 86400 + total


def leer_tabla():
    """
    pid -> ficha de cada proceso del sistema.

    Son dos llamadas a ps porque comm y args pueden llevar espacios y cada
    una tiene que ir en la ultima columna para poder separar el resto.
    """
    base = _ejecutar(["ps", "-axo", "pid=,ppid=,uid=,user=,stat=,tty=,"
                      "etime=,time=,pcpu=,rss=,comm="])
    argumentos = _ejecutar(["ps", "-axo", "pid=,args="])
    if not base:
        return None

    args = {}
    for linea in (argumentos or "").splitlines():
        pid, _, resto = linea.strip().partition(" ")
        if pid.isdigit():
            args[int(pid)] = resto.strip()

    tabla = {}
    for linea in base.splitlines():
        c = linea.split(None, 10)
        if len(c) < 11:
            continue
        try:
            pid = int(c[0])
            ruta = c[10].strip()
            tabla[pid] = {
                "pid": pid,
                "ppid": int(c[1]),
                "uid": int(c[2]),
                "usuario": c[3],
                "estado": c[4],
                "tty": c[5],
                "vida": _segundos(c[6]),
                "cpu_total": _segundos(c[7]),
                "pcpu": float(c[8]),
                "rss": int(c[9]) * 1024,
                "ruta": ruta,
                "nombre": os.path.basename(ruta) or ruta,
                "args": args.get(pid, ""),
            }
        except ValueError:
            continue
    return tabla


def leer_gestionados():
    """PIDs de los trabajos que launchd mantiene vivos en la sesion."""
    out = _ejecutar(["launchctl", "list"])
    if out is None:
        return None
    pids = set()
    for linea in out.splitlines()[1:]:
        pid = linea.split("\t", 1)[0].strip()
        if pid.isdigit():
            pids.add(int(pid))
    return pids


_RE_ASERCION = re.compile(
    r'^\s*pid (\d+)\((.*?)\): \[0x[0-9a-fA-F]+\] ([\d:]+) (\w+) named: "(.*)"')
_RE_PARA = re.compile(r"Created for PID: (\d+)")
_RE_DETALLE = re.compile(r"^\s*Details: (.*)")


def leer_reposo():
    """
    Quien impide que el equipo duerma, segun pmset.

    Se omite la asercion fija de powerd mientras la pantalla esta encendida
    y la de actividad del usuario: existen siempre y no dicen nada.
    """
    out = _ejecutar(["pmset", "-g", "assertions"])
    if out is None:
        return None
    lista, actual, en_lista = [], None, False
    for linea in out.splitlines():
        if linea.startswith("Listed by owning process"):
            en_lista = True
            continue
        if not linea.startswith((" ", "\t")):
            en_lista = False
        if not en_lista:
            continue
        m = _RE_ASERCION.match(linea)
        if m:
            actual = {
                "pid": int(m.group(1)),
                "proceso": m.group(2),
                "duracion": int(_segundos(m.group(3))),
                "tipo": m.group(4),
                "motivo": m.group(5)[:160],
                "detalle": "",
                "para_pid": None,
            }
            fija = (actual["proceso"] == "powerd"
                    and "display is on" in actual["motivo"])
            if actual["tipo"] == "UserIsActive" or fija:
                actual = None
            else:
                lista.append(actual)
            continue
        if actual is None:
            continue
        m = _RE_PARA.search(linea)
        if m:
            actual["para_pid"] = int(m.group(1))
            continue
        m = _RE_DETALLE.match(linea)
        if m:
            actual["detalle"] = m.group(1).strip()[:200]
    return lista


def leer_en_bateria():
    out = _ejecutar(["pmset", "-g", "batt"])
    if not out:
        return None
    return "Battery Power" in out.splitlines()[0]


def leer_energia(limite=10):
    """
    Impacto energetico por proceso: la columna Energia del Monitor de
    Actividad. top necesita dos muestras para calcularlo, asi que la
    llamada bloquea algo mas de un segundo.
    """
    out = _ejecutar(["top", "-l", "2", "-s", "1", "-n", str(limite),
                     "-o", "power", "-stats", "pid,command,power"], limite=12)
    if not out:
        return None
    # La primera muestra no tiene base de comparacion: vale la segunda tabla.
    tabla = out.split("\nPID")[-1].splitlines()[1:]
    filas = []
    for linea in tabla:
        c = linea.split()
        if len(c) < 3 or not c[0].isdigit():
            continue
        try:
            filas.append({"pid": int(c[0]), "nombre": " ".join(c[1:-1]),
                          "impacto": float(c[-1])})
        except ValueError:
            continue
    return filas


# --------------------------------------------------------------------------
# Analisis
# --------------------------------------------------------------------------

def _es_app(ruta):
    # El python de las Command Line Tools vive dentro de un Python.app, pero
    # es un interprete de terminal como cualquier otro.
    return (".app/Contents/" in ruta and "/Python.framework/" not in ruta
            and "/Python3.framework/" not in ruta)


def _es_sistema(ruta):
    return ruta.startswith(RUTAS_SISTEMA)


def _dueno(pid, tabla, gestionados, memo):
    """
    Que mantiene vivo al proceso: 'terminal', 'app', 'launchd', 'sistema'
    o None si al subir por sus padres se llega a launchd sin encontrar nada.
    El resultado vale para toda la cadena recorrida, asi que se memoriza.
    """
    cadena, actual, resultado = [], pid, None
    while actual > 1:
        if actual in memo:
            resultado = memo[actual]
            break
        f = tabla.get(actual)
        if f is None or len(cadena) > 64:
            resultado = "desconocido"
            break
        cadena.append(actual)
        if f["tty"] not in ("??", "-", ""):
            resultado = "terminal"
            break
        if actual in gestionados:
            resultado = "launchd"
            break
        if _es_app(f["ruta"]):
            resultado = "app"
            break
        if _es_sistema(f["ruta"]):
            resultado = "sistema"
            break
        actual = f["ppid"]
    for p in cadena:
        memo[p] = resultado
    return resultado


def _etiqueta(f):
    """'bash · guion.command' para interpretes; el nombre a secas para el resto."""
    nombre = f["nombre"]
    base = nombre.lstrip("-").lower().rstrip("0123456789.")
    if base not in INTERPRETES:
        return nombre
    _, _, resto = f["args"].partition(" ")
    resto = resto.strip()
    if not resto:
        return nombre
    if resto.startswith("/"):
        guion = os.path.basename(resto)
    else:
        archivos = [t for t in resto.split() if not t.startswith("-")
                    and ("/" in t or "." in t)]
        guion = os.path.basename(archivos[-1]) if archivos else resto[:40]
    return "%s · %s" % (nombre, guion)


def _duracion(seg):
    seg = int(seg or 0)
    d, h, m = seg // 86400, seg % 86400 // 3600, seg % 3600 // 60
    if d:
        return "%dd %dh" % (d, h)
    if h:
        return "%dh %dm" % (h, m)
    return "%dm" % m if m else "%ds" % seg


class Vigilante(object):

    def __init__(self, notificar=None):
        if notificar is None:
            notificar = os.environ.get("MONITOR_NOTIFICAR", "1") != "0"
        self.notificar = notificar
        self.tabla = {}
        self.huerfanos = set()
        self.datos = {"disponible": False, "motivo": "iniciando"}
        self.fotos = collections.deque()
        self.vistos = {}
        self.avisados = set()
        self.gestionados = None
        self.reposo = []
        self.en_bateria = None
        self.energia = None
        self._ts = {"launchd": 0.0, "reposo": 0.0, "energia": 0.0}
        self.ultima_consulta = 0.0
        self.inicio = time.time()
        self._parar = threading.Event()
        self._hilo = threading.Thread(target=self._bucle, daemon=True)
        self._hilo.start()

    # -- interfaz para el servidor ----------------------------------------

    def instantanea(self):
        """Lo ultimo calculado. Marca el panel como abierto."""
        self.ultima_consulta = time.time()
        return self.datos

    def ficha(self, pid):
        """Datos de un proceso para enriquecer otras tablas del panel."""
        f = self.tabla.get(pid)
        if not f:
            return None
        padre = self.tabla.get(f["ppid"])
        return {
            "nombre": f["nombre"],
            "etiqueta": _etiqueta(f),
            "args": f["args"][:400],
            "usuario": f["usuario"],
            "vida": int(f["vida"]),
            "tty": f["tty"],
            "ppid": f["ppid"],
            "padre": padre["nombre"] if padre else None,
            "huerfano": pid in self.huerfanos,
        }

    def detener(self):
        self._parar.set()

    # -- bucle ------------------------------------------------------------

    def _bucle(self):
        while not self._parar.is_set():
            t0 = time.time()
            try:
                self._muestrear()
            except Exception as e:
                self.datos = {"disponible": False, "motivo": "error: %s" % e}
            self._parar.wait(max(0.5, MUESTREO - (time.time() - t0)))

    def _vencido(self, clave, intervalo, ahora):
        if ahora - self._ts[clave] >= intervalo:
            self._ts[clave] = ahora
            return True
        return False

    def _muestrear(self):
        ahora = time.time()
        tabla = leer_tabla()
        if tabla is None:
            self.datos = {"disponible": False, "motivo": "ps no respondió"}
            return
        for f in tabla.values():
            f["inicio"] = ahora - f["vida"]

        if self.gestionados is None or self._vencido("launchd", INTERVALO_LAUNCHD, ahora):
            g = leer_gestionados()
            if g is not None:
                self.gestionados = g
        if self._vencido("reposo", INTERVALO_REPOSO, ahora):
            r = leer_reposo()
            self.reposo = r if r is not None else []
            self.en_bateria = leer_en_bateria()
        # top cuesta algo de CPU: solo se mide mientras alguien mira el panel.
        if (ahora - self.ultima_consulta < PANEL_ACTIVO
                and self._vencido("energia", INTERVALO_ENERGIA, ahora)):
            e = leer_energia()
            if e is not None:
                self.energia = {"ts": time.time(), "filas": e}

        if not self.fotos or ahora - self.fotos[-1][0] >= INTERVALO_FOTO:
            self.fotos.append((ahora, {p: (f["inicio"], f["cpu_total"])
                                       for p, f in tabla.items()}))
        while self.fotos and ahora - self.fotos[0][0] > VENTANA_DESBOCADO + 2 * INTERVALO_FOTO:
            self.fotos.popleft()

        self.tabla = tabla
        alertas, cuentas = self._analizar(tabla, ahora)
        self.datos = self._publicar(tabla, alertas, cuentas, ahora)

        for a in alertas:
            if a["nivel"] == "crit":
                self._avisar(a)

    # -- CPU sostenida ----------------------------------------------------

    def _foto(self, ventana, ahora):
        """La foto mas reciente que tenga al menos `ventana` segundos."""
        for ts, mapa in reversed(self.fotos):
            if ahora - ts >= ventana:
                return ts, mapa
        return None

    @staticmethod
    def _sostenida(f, ventana, foto, ahora):
        """% de un nucleo en la ventana, o None si no hay base para medirlo."""
        if foto:
            previo = foto[1].get(f["pid"])
            # Mismo pid pero otro inicio: el sistema reutilizo el numero.
            if previo and abs(previo[0] - f["inicio"]) <= 3:
                dt = ahora - foto[0]
                return max(0.0, (f["cpu_total"] - previo[1]) / dt * 100) if dt > 0 else None
            return None
        # Sin historial suficiente (el monitor acaba de arrancar), el promedio
        # de toda su vida solo es fiable si esa vida es larga.
        if f["vida"] >= ventana * 10:
            return f["cpu_total"] / f["vida"] * 100
        return None

    def _desde(self, clave, f, ahora, vigentes):
        """Desde cuando se ve un estado, contando solo este mismo proceso."""
        previo = self.vistos.get(clave)
        if previo and abs(previo[0] - f["inicio"]) <= 3:
            vigentes[clave] = previo
            return previo[1]
        vigentes[clave] = (f["inicio"], ahora)
        return ahora

    # -- reglas -----------------------------------------------------------

    def _analizar(self, tabla, ahora):
        uid = os.getuid()
        memo = {}
        vigentes = {}
        huerfanos = set()
        zombis = collections.defaultdict(list)
        alertas = []
        cuentas = {"procesos": len(tabla), "sin_terminal": 0,
                   "huerfanos": 0, "zombis": 0, "detenidos": 0}
        foto_olv = self._foto(VENTANA_OLVIDADO, ahora)
        foto_des = self._foto(VENTANA_DESBOCADO, ahora)

        for pid, f in tabla.items():
            if pid <= 1:
                continue
            estado = f["estado"]

            if estado.startswith("Z"):
                cuentas["zombis"] += 1
                if ahora - self._desde(("zombi", pid), f, ahora, vigentes) >= MIN_ZOMBI:
                    zombis[f["ppid"]].append(pid)
                continue

            propio = f["uid"] == uid
            if propio and f["tty"] == "??":
                cuentas["sin_terminal"] += 1

            if propio and estado.startswith("T"):
                cuentas["detenidos"] += 1
                desde = self._desde(("detenido", pid), f, ahora, vigentes)
                if ahora - desde >= MIN_DETENIDO:
                    alertas.append(self._alerta(
                        "detenido", "info", "Proceso suspendido", f, ahora,
                        "Está detenido (Ctrl+Z o SIGSTOP) desde hace %s. No usa CPU, "
                        "pero retiene su memoria hasta que lo reanudes con fg o lo "
                        "termines." % _duracion(ahora - desde)))

            olvidado = False
            if (propio and self.gestionados is not None
                    and f["nombre"].lstrip("-") not in DESACOPLADOS
                    and _dueno(pid, tabla, self.gestionados, memo) is None):
                olvidado = True
                huerfanos.add(pid)
                cpu = self._sostenida(f, VENTANA_OLVIDADO, foto_olv, ahora)
                motivo = ("Ni él ni sus procesos padre tienen ventana de terminal, y "
                          "no depende de ninguna app ni de launchd: lo más probable es "
                          "que se cerró la ventana que lo lanzó y siguió corriendo.")
                if cpu is not None and cpu >= UMBRAL_OLVIDADO:
                    alertas.append(self._alerta(
                        "olvidado", "crit", "Olvidado y consumiendo CPU", f, ahora,
                        motivo + " Mantiene %.0f%% de un núcleo." % cpu, cpu,
                        VENTANA_OLVIDADO))
                else:
                    alertas.append(self._alerta(
                        "olvidado", "warn", "Proceso olvidado", f, ahora, motivo,
                        cpu, VENTANA_OLVIDADO))

            if not olvidado and f["nombre"] != "kernel_task":
                cpu = self._sostenida(f, VENTANA_DESBOCADO, foto_des, ahora)
                if cpu is not None and cpu >= UMBRAL_DESBOCADO:
                    alertas.append(self._alerta(
                        "desbocado", "warn", "Proceso desbocado", f, ahora,
                        "Lleva al menos %s con %.0f%% de un núcleo ocupado. Puede "
                        "ser trabajo legítimo (una compilación, un modelo local) o "
                        "un bucle sin salida." % (_duracion(VENTANA_DESBOCADO), cpu),
                        cpu, VENTANA_DESBOCADO))

        cuentas["huerfanos"] = len(huerfanos)

        for ppid, hijos in zombis.items():
            padre = tabla.get(ppid)
            if not padre:
                continue
            a = self._alerta(
                "zombi", "warn", "Procesos zombi", padre, ahora,
                "%d proceso%s terminado%s que %s no ha recogido. No consumen CPU ni "
                "memoria, pero delatan un padre colgado o mal escrito. Desaparecen "
                "al cerrar el padre." % (len(hijos), "s" if len(hijos) > 1 else "",
                                         "s" if len(hijos) > 1 else "", padre["nombre"]))
            a["zombis"] = sorted(hijos)[:50]
            a["valor"] = len(hijos)
            alertas.append(a)

        if self.en_bateria:
            for r in self.reposo:
                if r["duracion"] < MIN_REPOSO:
                    continue
                f = tabla.get(r["para_pid"] or r["pid"]) or tabla.get(r["pid"])
                if not f:
                    continue
                a = self._alerta(
                    "reposo", "warn", "Impide el reposo con batería", f, ahora,
                    "Lleva %s impidiendo que el equipo duerma (%s) mientras funciona "
                    "con batería." % (_duracion(r["duracion"]), r["tipo"]))
                a["valor"] = r["duracion"]
                a["id"] = "reposo:%d:%s" % (f["pid"], r["tipo"])
                alertas.append(a)

        self.vistos = vigentes
        self.huerfanos = huerfanos
        alertas.sort(key=lambda a: (ORDEN_NIVEL[a["nivel"]],
                                    -(a.get("cpu_sostenida") or 0)))
        return alertas, cuentas

    def _alerta(self, regla, nivel, titulo, f, ahora, motivo, cpu=None, ventana=None):
        padre = self.tabla.get(f["ppid"]) if self.tabla else None
        return {
            # El id distingue procesos; la firma, programas: silenciar por
            # firma sobrevive a que el proceso se relance con otro pid.
            "id": "%s:%d:%d" % (regla, f["pid"], int(f["inicio"])),
            "firma": "%s:%s" % (regla, (f["args"] or f["ruta"])[:200]),
            "regla": regla,
            "nivel": nivel,
            "titulo": titulo,
            "motivo": motivo,
            "pid": f["pid"],
            "nombre": f["nombre"],
            "etiqueta": _etiqueta(f),
            "args": f["args"][:400],
            "usuario": f["usuario"],
            "vida": int(f["vida"]),
            "tty": f["tty"],
            "ppid": f["ppid"],
            "padre": padre["nombre"] if padre else None,
            "pcpu": f["pcpu"],
            "rss": f["rss"],
            "cpu_sostenida": round(cpu, 1) if cpu is not None else None,
            "ventana": int(ventana) if ventana else None,
            "comando": "kill %d" % f["pid"],
        }

    def _publicar(self, tabla, alertas, cuentas, ahora):
        reposo = []
        for r in self.reposo:
            para = tabla.get(r["para_pid"]) if r["para_pid"] else None
            reposo.append(dict(r, para_nombre=para["nombre"] if para else None))
        energia = None
        if self.energia:
            filas = []
            for e in self.energia["filas"]:
                f = tabla.get(e["pid"])
                if f is None and e["nombre"] == "top":
                    continue        # el propio top que tomo la medida
                filas.append(dict(e, nombre=f["nombre"] if f else e["nombre"],
                                  etiqueta=_etiqueta(f) if f else e["nombre"],
                                  usuario=f["usuario"] if f else None))
            energia = {"edad": int(ahora - self.energia["ts"]), "filas": filas}
        return {
            "disponible": True,
            "historial": int(min(ahora - self.inicio, VENTANA_DESBOCADO)),
            "notificaciones": self.notificar,
            "alertas": alertas,
            "cuentas": cuentas,
            "reposo": reposo,
            "en_bateria": self.en_bateria,
            "energia": energia,
            "reglas": {
                "olvidado_umbral": UMBRAL_OLVIDADO,
                "olvidado_ventana": int(VENTANA_OLVIDADO),
                "desbocado_umbral": UMBRAL_DESBOCADO,
                "desbocado_ventana": int(VENTANA_DESBOCADO),
                "detenido_min": int(MIN_DETENIDO),
                "reposo_min": int(MIN_REPOSO),
            },
        }

    # -- notificaciones ---------------------------------------------------

    def _avisar(self, alerta):
        """Una notificacion del sistema por proceso, solo para lo critico."""
        if not self.notificar or alerta["id"] in self.avisados:
            return
        self.avisados.add(alerta["id"])
        if len(self.avisados) > 500:
            self.avisados = {alerta["id"]}
        texto = "%s (pid %d) · %s sostenido · vivo hace %s" % (
            alerta["etiqueta"], alerta["pid"],
            "%.0f%% CPU" % (alerta["cpu_sostenida"] or 0),
            _duracion(alerta["vida"]))
        # Los textos viajan como argumentos, nunca dentro del codigo
        # AppleScript: un nombre de proceso no puede inyectar instrucciones.
        cmd = ["osascript", "-e", "on run argv",
               "-e", "display notification (item 1 of argv) with title "
                     "(item 2 of argv) subtitle (item 3 of argv)",
               "-e", "end run", texto, "Telemetría del Mac", alerta["titulo"]]
        # En un hilo con run(): un Popen sin esperar dejaria un zombi propio.
        threading.Thread(target=subprocess.run, args=(cmd,),
                         kwargs={"stdout": subprocess.DEVNULL,
                                 "stderr": subprocess.DEVNULL, "timeout": 15},
                         daemon=True).start()


# --------------------------------------------------------------------------
# Uso aislado
# --------------------------------------------------------------------------

if __name__ == "__main__":
    v = Vigilante(notificar=False)
    v.ultima_consulta = time.time()
    limite = time.time() + 20
    while not v.datos.get("disponible") and time.time() < limite:
        time.sleep(0.3)
    d = v.datos
    if "--json" in sys.argv:
        print(json.dumps(d, indent=2, ensure_ascii=False))
        sys.exit(0)
    if not d.get("disponible"):
        print("sin datos: %s" % d.get("motivo"))
        sys.exit(1)
    c = d["cuentas"]
    print("procesos %d · sin terminal %d · huérfanos %d · zombis %d · detenidos %d"
          % (c["procesos"], c["sin_terminal"], c["huerfanos"], c["zombis"],
             c["detenidos"]))
    print("con batería: %s" % d["en_bateria"])
    print("\nalertas (%d):" % len(d["alertas"]))
    for a in d["alertas"]:
        cpu = a["cpu_sostenida"]
        print("  [%s] %-28s pid %-6d %-34s %s" % (
            a["nivel"], a["titulo"], a["pid"], a["etiqueta"][:34],
            "%.0f%%" % cpu if cpu is not None else "—"))
        print("        padre %s · vida %s · %s" % (
            a["padre"], _duracion(a["vida"]), a["args"][:90]))
    print("\nimpiden el reposo (%d):" % len(d["reposo"]))
    for r in d["reposo"]:
        print("  %-22s %-30s %s%s" % (
            r["proceso"], r["tipo"], _duracion(r["duracion"]),
            " · para " + r["para_nombre"] if r["para_nombre"] else ""))
    e = d.get("energia")
    print("\nimpacto energético:")
    for fila in (e or {}).get("filas", [])[:8]:
        print("  %-36s %6.1f" % (fila["etiqueta"][:36], fila["impacto"]))
