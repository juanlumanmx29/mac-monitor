import Foundation
import IOKit
import notify

// Potencia, frecuencias y residencia de la GPU sin sudo.
//
// powermetrics saca estas cifras de IOReport, la biblioteca de contadores del
// kernel, y exige root. La biblioteca en si no: cualquier usuario puede
// suscribirse a los grupos "Energy Model", "CPU Stats" y "GPU Stats". Es una
// API privada, asi que se enlaza en ejecucion con dlsym: si algun dia falta o
// cambia, el panel degrada a "sin datos" en vez de no arrancar.
//
// Las frecuencias no vienen en IOReport: los canales solo dicen cuanto tiempo
// paso cada cluster en cada estado (V0P6, V1P5...). La tabla que traduce el
// estado a MHz esta en el registro de IOKit, en el nodo pmgr.

struct ClusterFrecuencia {
    let nombre: String
    let mhz: Double?
    let activa: Double
}

struct Potencia {
    var cpu: Double?
    var gpu: Double?
    var ane: Double?
    var dram: Double?
    /// Todo el equipo: lo que entrega la bateria (descargando), la carga del
    /// sistema segun el cargador (enchufado) o, sin bateria, PSTR del SMC.
    var sistema: Double?
    /// De donde sale `sistema`: "batería", "cargador" o "SMC".
    var fuente = ""
    /// PSTR del SMC. Queda por debajo de lo que entregan la bateria o el
    /// cargador: no cuenta todos los componentes.
    var smc: Double?
    var clusters: [ClusterFrecuencia] = []
    var frecE: Double?
    var frecP: Double?
    /// Frecuencia media activa de cada nucleo, en el orden del sistema.
    var nucleosMHz: [Double?] = []
    var gpuMHz: Double?
    var gpuActiva: Double?
    var gpuEstados: [(mhz: Double, pct: Double)] = []
    var termico: Int?
    /// Con bateria, el firmware deja de actualizar los contadores de energia
    /// de CPU, DRAM y Neural Engine (solo avanza el de la GPU): esos bloques
    /// quedan sin dato en vez de mostrar un 0 falso.
    var bloquesCongelados = false
}

enum PresionTermica {
    static func nombre(_ nivel: Int?) -> String {
        switch nivel {
        case 0: return "nominal"
        case 1: return "moderada"
        case 2: return "alta"
        case 3: return "crítica"
        case 4: return "reposo forzado"
        default: return "—"
        }
    }
}

final class IOReport {
    private typealias CopiarCanales = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias Fusionar = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias CrearSuscripcion = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias CrearMuestras = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Cadena = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Entero = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias Cuenta = @convention(c) (CFDictionary) -> Int32
    private typealias NombreEstado = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias Residencia = @convention(c) (CFDictionary, Int32) -> Int64

    private var crearMuestras: CrearMuestras?
    private var delta: Delta?
    private var grupo: Cadena?
    private var subgrupo: Cadena?
    private var nombreCanal: Cadena?
    private var unidad: Cadena?
    private var simple: Entero?
    private var cuentaEstados: Cuenta?
    private var nombreEstado: NombreEstado?
    private var residencia: Residencia?

    private var suscripcion: OpaquePointer?
    private var canales: CFMutableDictionary?
    private var previa: CFDictionary?
    private var tsPrevia = 0.0
    private var ultima: Potencia?

    private var tablaE: [Double] = []
    private var tablaP: [Double] = []
    private var tablaGPU: [Double] = []
    private var tokenTermico: Int32 = 0
    private var hayTermico = false

    private(set) var disponible = false
    private(set) var motivo = ""

    init() {
        if notify_register_check("com.apple.system.thermalpressurelevel", &tokenTermico) == NOTIFY_STATUS_OK {
            hayTermico = true
        }
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else {
            motivo = "libIOReport no disponible"
            return
        }
        func f<T>(_ n: String, _ t: T.Type) -> T? {
            dlsym(h, n).map { unsafeBitCast($0, to: t) }
        }
        guard let copiar = f("IOReportCopyChannelsInGroup", CopiarCanales.self),
              let fusionar = f("IOReportMergeChannels", Fusionar.self),
              let crearSub = f("IOReportCreateSubscription", CrearSuscripcion.self) else {
            motivo = "IOReport sin las funciones esperadas"
            return
        }
        crearMuestras = f("IOReportCreateSamples", CrearMuestras.self)
        delta = f("IOReportCreateSamplesDelta", Delta.self)
        grupo = f("IOReportChannelGetGroup", Cadena.self)
        subgrupo = f("IOReportChannelGetSubGroup", Cadena.self)
        nombreCanal = f("IOReportChannelGetChannelName", Cadena.self)
        unidad = f("IOReportChannelGetUnitLabel", Cadena.self)
        simple = f("IOReportSimpleGetIntegerValue", Entero.self)
        cuentaEstados = f("IOReportStateGetCount", Cuenta.self)
        nombreEstado = f("IOReportStateGetNameForIndex", NombreEstado.self)
        residencia = f("IOReportStateGetResidency", Residencia.self)
        guard crearMuestras != nil, delta != nil, nombreCanal != nil, simple != nil, residencia != nil else {
            motivo = "IOReport sin las funciones esperadas"
            return
        }

        guard let base = copiar("Energy Model" as CFString, nil, 0, 0, 0)?.takeRetainedValue() else {
            motivo = "sin canales de energía"
            return
        }
        for (g, s) in [("CPU Stats", "CPU Complex Performance States"),
                       ("CPU Stats", "CPU Core Performance States"),
                       ("GPU Stats", "GPU Performance States")] {
            if let c = copiar(g as CFString, s as CFString, 0, 0, 0)?.takeRetainedValue() {
                fusionar(base, c, nil)
            }
        }
        // Solo los canales que se usan: el grupo de energia trae cientos (uno por
        // bloque del chip) y muestrearlos todos cada segundo es gasto puro.
        var pedido = base
        if let todos = (base as NSDictionary)["IOReportChannels"] as? [CFDictionary] {
            let utiles = todos.filter { Self.util(grupo: texto(grupo, $0), subgrupo: texto(subgrupo, $0), nombre: texto(nombreCanal, $0)) }
            if !utiles.isEmpty {
                let d = NSMutableDictionary(dictionary: base as NSDictionary)
                d["IOReportChannels"] = utiles
                pedido = d as CFMutableDictionary
            }
        }
        var suscritos: Unmanaged<CFMutableDictionary>?
        guard let sub = crearSub(nil, pedido, &suscritos, 0, nil) ?? crearSub(nil, base, &suscritos, 0, nil),
              let s = suscritos?.takeRetainedValue() else {
            motivo = "no se pudo suscribir a IOReport"
            return
        }
        suscripcion = sub
        canales = s
        cargarTablas()
        disponible = true
    }

    // MARK: - Tablas de frecuencia

    /// Tablas voltage-statesN del nodo pmgr: pares (frecuencia, voltaje) de 32
    /// bits. Hasta M3 la frecuencia viene en Hz; desde M4, en kHz.
    private func cargarTablas() {
        var tablas: [String: [Double]] = [:]
        IOK.cadaServicio("AppleARMIODevice") { s in
            var nombre = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(s, &nombre)
            guard String(cString: nombre) == "pmgr", let props = IOK.propiedades(s) else { return true }
            for (k, v) in props where k.hasPrefix("voltage-states") {
                guard let datos = v as? Data, datos.count >= 8 else { continue }
                let valores = datos.withUnsafeBytes { raw in
                    stride(from: 0, to: datos.count - 7, by: 8).map { Double(raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)) }
                }
                let escala = (valores.max() ?? 0) > 1e8 ? 1e6 : 1e3
                tablas[k] = valores.map { $0 / escala }
            }
            return false
        }
        tablaE = tablas["voltage-states1-sram"] ?? []
        tablaP = tablas["voltage-states5-sram"] ?? []
        tablaGPU = tablas["voltage-states9"] ?? []
        todasLasTablas = tablas
    }

    private var todasLasTablas: [String: [Double]] = [:]

    /// La tabla conocida si cuadra con el numero de estados activos; si no, la
    /// primera tabla plausible que si cuadre. Degradar antes que inventar MHz.
    private func tabla(_ preferida: [Double], estados n: Int) -> [Double]? {
        func ajustar(_ t: [Double]) -> [Double]? {
            if t.count == n { return t }
            if t.count == n + 1, t.first == 0 { return Array(t.dropFirst()) }
            return nil
        }
        if let t = ajustar(preferida) { return t }
        for (k, t) in todasLasTablas.sorted(by: { $0.key < $1.key }) where k.hasSuffix("-sram") {
            if let a = ajustar(t), let mx = a.max(), mx > 300, mx < 8000 { return a }
        }
        return nil
    }

    // MARK: - Muestra

    func leer(_ equipo: Equipo) -> Potencia? {
        var p = Potencia()
        if hayTermico {
            var estado: UInt64 = 0
            if notify_get_state(tokenTermico, &estado) == NOTIFY_STATUS_OK { p.termico = Int(estado) }
        }
        guard disponible, let sub = suscripcion, let canales, let crearMuestras, let delta else { return p }
        let ahora = Sys.reloj()
        // Dos lecturas demasiado juntas (un ciclo inmediato tras cambiar la
        // visibilidad) darian un delta de ruido: se repite la ultima.
        if previa != nil, ahora - tsPrevia < 0.3 {
            guard var u = ultima else { return p }
            u.termico = p.termico
            return u
        }
        guard let actual = crearMuestras(sub, canales, nil)?.takeRetainedValue() else { return p }
        defer { previa = actual; tsPrevia = ahora }
        guard let previa,
              let d = delta(previa, actual, nil)?.takeRetainedValue() as NSDictionary?,
              let lista = d["IOReportChannels"] as? [CFDictionary] else { return nil }
        let dt = ahora - tsPrevia

        var energia: [String: Double] = [:]
        var complejos: [(String, CFDictionary)] = []
        var nucleos: [(String, CFDictionary)] = []
        var gpu: CFDictionary?
        for ch in lista {
            let g = texto(grupo, ch)
            let n = texto(nombreCanal, ch)
            switch g {
            case "Energy Model":
                let factor: Double
                switch texto(unidad, ch) {
                case "mJ": factor = 1e-3
                case "uJ", "µJ": factor = 1e-6
                case "nJ": factor = 1e-9
                default: continue
                }
                energia[n, default: 0] += Double(simple!(ch, 0)) * factor
            case "CPU Stats":
                let sg = texto(subgrupo, ch)
                // El subgrupo trae tambien canales de gestion (ECPM, PCPM_IDLE...):
                // solo cuentan los clusters, ECPU, PCPU, PCPU1...
                if sg == "CPU Complex Performance States", Self.esCluster(n) { complejos.append((n, ch)) }
                else if sg == "CPU Core Performance States" { nucleos.append((n, ch)) }
            case "GPU Stats":
                if n == "GPUPH" { gpu = ch }
            default:
                break
            }
        }

        func vatios(_ julios: Double?) -> Double? { julios.map { $0 / dt } }
        p.cpu = vatios(energia["CPU Energy"])
        p.gpu = vatios(energia["GPU Energy"] ?? energia["GPU"])
        p.ane = vatios(energia.filter { $0.key.hasPrefix("ANE") }.values.reduce(nil) { ($0 ?? 0) + $1 })
        p.dram = vatios(energia["DRAM"])

        // Clusters: ECPU, PCPU, PCPU1... (los de eficiencia empiezan por E).
        var sumaP = 0.0, pesoP = 0.0
        for (n, ch) in complejos.sorted(by: { $0.0 < $1.0 }) {
            let esE = n.hasPrefix("E")
            let r = estados(ch, tabla: esE ? tablaE : tablaP)
            p.clusters.append(ClusterFrecuencia(nombre: n, mhz: r.mhz, activa: r.activa))
            if esE { p.frecE = r.mhz }
            else if let mhz = r.mhz, r.activa > 0 { sumaP += mhz * r.activa; pesoP += r.activa }
        }
        if pesoP > 0 { p.frecP = sumaP / pesoP }

        // CPU activa y contador de energia quieto: contador congelado.
        if (energia["CPU Energy"] ?? 0) == 0, (p.clusters.map(\.activa).max() ?? 0) > 1 {
            p.cpu = nil
            p.ane = nil
            p.dram = nil
            p.bloquesCongelados = true
        }

        // Nucleos: ECPU000.. y PCPU000.., PCPU100.. en orden lexicografico
        // coinciden con la numeracion del sistema (E primero).
        let e = nucleos.filter { $0.0.hasPrefix("E") }.sorted { $0.0 < $1.0 }
        let pp = nucleos.filter { $0.0.hasPrefix("P") }.sorted { $0.0 < $1.0 }
        if e.count == equipo.nucleosE, pp.count == equipo.nucleosP {
            p.nucleosMHz = e.map { estados($0.1, tabla: tablaE).mhz } + pp.map { estados($0.1, tabla: tablaP).mhz }
        }

        if let gpu {
            let r = estados(gpu, tabla: tablaGPU)
            p.gpuMHz = r.mhz
            p.gpuActiva = r.activa
            p.gpuEstados = r.reparto
        }
        ultima = p
        return p
    }

    /// Frecuencia media mientras estuvo activo, porcentaje de tiempo activo y
    /// reparto del tiempo por estado.
    private func estados(_ ch: CFDictionary, tabla preferida: [Double])
        -> (mhz: Double?, activa: Double, reparto: [(mhz: Double, pct: Double)]) {
        guard let cuentaEstados, let nombreEstado, let residencia else { return (nil, 0, []) }
        let k = cuentaEstados(ch)
        var activos: [Double] = []
        var total = 0.0
        for i in 0..<k {
            let r = Double(residencia(ch, i))
            total += r
            let n = nombreEstado(ch, i)?.takeUnretainedValue() as String? ?? ""
            if n != "IDLE" && n != "DOWN" && n != "OFF" { activos.append(r) }
        }
        let suma = activos.reduce(0, +)
        let activa = total > 0 ? 100 * suma / total : 0
        guard let t = tabla(preferida, estados: activos.count) else { return (nil, activa, []) }
        let mhz = suma > 0 ? zip(activos, t).reduce(0) { $0 + $1.0 * $1.1 } / suma : nil
        let reparto = zip(t, activos).map { (mhz: $0, pct: total > 0 ? 100 * $1 / total : 0) }
        return (mhz, activa, reparto)
    }

    private static func util(grupo: String, subgrupo: String, nombre: String) -> Bool {
        switch grupo {
        case "Energy Model":
            return nombre == "CPU Energy" || nombre == "GPU Energy" || nombre == "GPU" || nombre.hasPrefix("ANE") || nombre == "DRAM"
        case "CPU Stats":
            return subgrupo == "CPU Core Performance States" || esCluster(nombre)
        case "GPU Stats":
            return nombre == "GPUPH"
        default:
            return false
        }
    }

    private static func esCluster(_ n: String) -> Bool {
        guard n.hasPrefix("ECPU") || n.hasPrefix("PCPU") else { return false }
        return n.dropFirst(4).allSatisfy(\.isNumber)
    }

    private func texto(_ f: Cadena?, _ ch: CFDictionary) -> String {
        f?(ch)?.takeUnretainedValue() as String? ?? ""
    }
}
