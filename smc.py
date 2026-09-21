#!/usr/bin/env python3
"""
Lectura directa del SMC (System Management Controller) via IOKit.

Es la unica via a los ventiladores y termistores en Apple Silicon:
powermetrics dejo de exponer el sampler 'smc' a partir de los M1.
No requiere privilegios de root, solo abrir el servicio AppleSMC.
"""

import ctypes
import ctypes.util
import struct
import threading

_iokit = ctypes.CDLL("/System/Library/Frameworks/IOKit.framework/IOKit")
_libc = ctypes.CDLL(ctypes.util.find_library("c"))

_KERNEL_INDEX = 2
_READ_KEY = 5
_GET_KEY_FROM_INDEX = 8
_GET_KEY_INFO = 9


class _Vers(ctypes.Structure):
    _fields_ = [("major", ctypes.c_ubyte), ("minor", ctypes.c_ubyte),
                ("build", ctypes.c_ubyte), ("reserved", ctypes.c_ubyte),
                ("release", ctypes.c_ushort)]


class _PLimit(ctypes.Structure):
    _fields_ = [("version", ctypes.c_ushort), ("length", ctypes.c_ushort),
                ("cpuPLimit", ctypes.c_uint), ("gpuPLimit", ctypes.c_uint),
                ("memPLimit", ctypes.c_uint)]


class _KeyInfo(ctypes.Structure):
    _fields_ = [("dataSize", ctypes.c_uint), ("dataType", ctypes.c_uint),
                ("dataAttributes", ctypes.c_ubyte)]


class _KeyData(ctypes.Structure):
    _fields_ = [("key", ctypes.c_uint), ("vers", _Vers),
                ("pLimitData", _PLimit), ("keyInfo", _KeyInfo),
                ("result", ctypes.c_ubyte), ("status", ctypes.c_ubyte),
                ("data8", ctypes.c_ubyte), ("data32", ctypes.c_uint),
                ("bytes", ctypes.c_ubyte * 32)]


_iokit.IOServiceMatching.restype = ctypes.c_void_p
_iokit.IOServiceMatching.argtypes = [ctypes.c_char_p]
_iokit.IOServiceGetMatchingService.restype = ctypes.c_uint
_iokit.IOServiceGetMatchingService.argtypes = [ctypes.c_uint, ctypes.c_void_p]
_iokit.IOServiceOpen.restype = ctypes.c_int
_iokit.IOServiceOpen.argtypes = [ctypes.c_uint, ctypes.c_uint, ctypes.c_uint,
                                 ctypes.POINTER(ctypes.c_uint)]
_iokit.IOConnectCallStructMethod.restype = ctypes.c_int
_iokit.IOConnectCallStructMethod.argtypes = [
    ctypes.c_uint, ctypes.c_uint, ctypes.c_void_p, ctypes.c_size_t,
    ctypes.c_void_p, ctypes.POINTER(ctypes.c_size_t)]
_libc.mach_task_self.restype = ctypes.c_uint


# Familias de termistores y su significado en Apple Silicon.
# El orden importa: define el orden de presentacion en el panel.
FAMILIAS = [
    ("Tp", "CPU rendimiento"),
    ("Te", "CPU eficiencia"),
    ("Tg", "GPU"),
    ("TV", "Reguladores"),
    ("Ts", "Chasis"),
    ("TB", "Batería"),
    ("TH", "SSD"),
    ("Ta", "Entrada de aire"),
]

# Cuantos sensores leer por familia. Hay 322 termistores validos; leerlos
# todos cada segundo es gasto puro cuando basta una muestra representativa.
MAX_POR_FAMILIA = 10


class SMC(object):
    def __init__(self):
        self.conexion = None
        self.disponible = False
        self.listo = False
        self.motivo = ""
        self.num_ventiladores = 0
        self.rango_ventiladores = {}
        self.claves_temp = {}
        self._lock = threading.Lock()
        self._abrir()

    # -- conexion ---------------------------------------------------------

    def _abrir(self):
        try:
            svc = _iokit.IOServiceGetMatchingService(
                0, _iokit.IOServiceMatching(b"AppleSMC"))
            if not svc:
                self.motivo = "servicio AppleSMC no encontrado"
                return
            conn = ctypes.c_uint(0)
            rc = _iokit.IOServiceOpen(svc, _libc.mach_task_self(), 0,
                                      ctypes.byref(conn))
            if rc != 0:
                self.motivo = "IOServiceOpen devolvio %d" % rc
                return
            self.conexion = conn
            self.disponible = True
            # El descubrimiento recorre las 3338 claves del SMC y tarda
            # cerca de un segundo. Hacerlo aqui retrasaria la apertura del
            # socket del servidor, asi que corre en segundo plano: hasta
            # que termina, los muestreos devuelven listas vacias.
            self.listo = False
            threading.Thread(target=self._descubrir_seguro, daemon=True).start()
        except Exception as e:
            self.motivo = str(e)

    def _descubrir_seguro(self):
        try:
            self._descubrir()
        except Exception as e:
            self.motivo = str(e)
        finally:
            self.listo = True

    def _llamar(self, entrada):
        salida = _KeyData()
        n = ctypes.c_size_t(ctypes.sizeof(_KeyData))
        rc = _iokit.IOConnectCallStructMethod(
            self.conexion, _KERNEL_INDEX,
            ctypes.byref(entrada), ctypes.sizeof(_KeyData),
            ctypes.byref(salida), ctypes.byref(n))
        return rc, salida

    # -- lectura de claves ------------------------------------------------

    def leer(self, clave):
        """Devuelve el valor decodificado de una clave SMC, o None."""
        if not self.disponible:
            return None
        try:
            with self._lock:
                k = struct.unpack(">I", clave.encode())[0]

                e = _KeyData()
                e.key = k
                e.data8 = _GET_KEY_INFO
                rc, s = self._llamar(e)
                if rc != 0:
                    return None
                tam, tipo_num = s.keyInfo.dataSize, s.keyInfo.dataType

                e = _KeyData()
                e.key = k
                e.data8 = _READ_KEY
                e.keyInfo = s.keyInfo
                rc, s = self._llamar(e)
                if rc != 0:
                    return None

            crudo = bytes(s.bytes[:tam])
            tipo = struct.pack(">I", tipo_num).decode("ascii", "replace")

            if tipo == "flt " and tam == 4:
                return struct.unpack("<f", crudo)[0]
            if tipo == "fpe2" and tam == 2:            # Macs Intel
                return float((crudo[0] << 6) | (crudo[1] >> 2))
            if tipo.startswith("ui"):
                return float(int.from_bytes(crudo, "big"))
            if tipo == "sp78" and tam == 2:
                return float(ctypes.c_byte(crudo[0]).value) + crudo[1] / 256.0
            return None
        except Exception:
            return None

    def _clave_en_indice(self, idx):
        e = _KeyData()
        e.data8 = _GET_KEY_FROM_INDEX
        e.data32 = idx
        with self._lock:
            rc, s = self._llamar(e)
        if rc != 0:
            return None
        return struct.pack(">I", s.key).decode("ascii", "replace")

    # -- descubrimiento (una vez al arrancar) -----------------------------

    def _descubrir(self):
        n = self.leer("FNum")
        self.num_ventiladores = int(n) if n else 0
        for f in range(self.num_ventiladores):
            self.rango_ventiladores[f] = {
                "min": self.leer("F%dMn" % f),
                "max": self.leer("F%dMx" % f),
            }

        total = self.leer("#KEY")
        if not total:
            return

        candidatas = {p: [] for p, _ in FAMILIAS}
        for i in range(int(total)):
            k = self._clave_en_indice(i)
            if not k or k[:2] not in candidatas:
                continue
            if len(candidatas[k[:2]]) >= MAX_POR_FAMILIA * 3:
                continue
            candidatas[k[:2]].append(k)

        # El SMC expone muchos termistores reservados o inactivos, asi que se
        # prefieren las claves que ya devuelven una lectura plausible. Si una
        # familia no tiene ninguna viva en este instante se conservan igual sus
        # primeras claves: los sensores de los nucleos P leen 0 mientras el
        # cluster esta apagado, y volveran a dar valores al despertar. Sin esto
        # la familia desapareceria del panel de forma intermitente.
        for prefijo, claves in candidatas.items():
            vivas = []
            for k in claves:
                v = self.leer(k)
                if v is not None and 5.0 < v < 120.0:
                    vivas.append(k)
                if len(vivas) >= MAX_POR_FAMILIA:
                    break
            self.claves_temp[prefijo] = vivas or claves[:MAX_POR_FAMILIA]

    # -- muestreo ---------------------------------------------------------

    def ventiladores(self):
        salida = []
        for f in range(self.num_ventiladores):
            actual = self.leer("F%dAc" % f)
            objetivo = self.leer("F%dTg" % f)
            r = self.rango_ventiladores.get(f, {})
            mn, mx = r.get("min") or 0, r.get("max") or 0
            pct = 0.0
            if actual and mx > mn:
                pct = max(0.0, min(100.0, 100.0 * (actual - mn) / (mx - mn)))
            salida.append({
                "id": f,
                "rpm": round(actual) if actual is not None else None,
                "objetivo": round(objetivo) if objetivo else 0,
                "min": round(mn), "max": round(mx),
                "pct": round(pct, 1),
            })
        return salida

    def temperaturas(self):
        salida = []
        etiquetas = dict(FAMILIAS)
        for prefijo, _ in FAMILIAS:
            claves = self.claves_temp.get(prefijo)
            if not claves:
                continue
            vals = [v for v in (self.leer(k) for k in claves)
                    if v is not None and 5.0 < v < 120.0]
            # Se emite la familia aunque no haya lecturas: max None significa
            # "cluster en reposo", no "sensor ausente", y el panel lo distingue.
            salida.append({
                "id": prefijo,
                "nombre": etiquetas[prefijo],
                "max": round(max(vals), 1) if vals else None,
                "promedio": round(sum(vals) / len(vals), 1) if vals else None,
                "n": len(vals),
            })
        return salida


if __name__ == "__main__":
    s = SMC()
    print("disponible:", s.disponible, s.motivo)
    print("ventiladores:", s.num_ventiladores)
    for v in s.ventiladores():
        print("  ", v)
    for t in s.temperaturas():
        print("  %-18s max %5.1f C  prom %5.1f C  (%d sensores)"
              % (t["nombre"], t["max"], t["promedio"], t["n"]))
