import Darwin
import Foundation
import IOKit
import IOKit.ps

// GPU, bateria, red y disco. Todo se lee en proceso: registro de IOKit y
// sysctl, sin lanzar ioreg, netstat ni system_profiler en cada muestra.

// MARK: - GPU

struct GPUInstantanea {
    var uso: Double?
    var render: Double?
    var tiler: Double?
    var memoriaEnUso: Double?
    var memoriaReservada: Double?
}

/// Uso de GPU sin privilegios: el driver publica las mismas cifras que
/// powermetrics en el registro de IOKit.
func leerGPU() -> GPUInstantanea? {
    var r: GPUInstantanea?
    IOK.cadaServicio("IOAccelerator") { s in
        guard let stats = IOK.propiedad(s, "PerformanceStatistics") as? [String: Any] else { return true }
        r = GPUInstantanea(
            uso: numero(stats["Device Utilization %"]),
            render: numero(stats["Renderer Utilization %"]),
            tiler: numero(stats["Tiler Utilization %"]),
            memoriaEnUso: numero(stats["In use system memory"]),
            memoriaReservada: numero(stats["Alloc system memory"]))
        return false
    }
    return r
}

// MARK: - Bateria

struct BateriaInstantanea {
    enum Estado: String { case cargando, enchufado, descargando }
    var pct: Double = 0
    var estado: Estado = .descargando
    var vatios: Double?
    var minutosRestantes: Int?
    var ciclos: Int?
    var ciclosDiseno: Int?
    var salud: Double?
    var temperatura: Double?
    var adaptador: Double?
    /// Lo que consume todo el equipo segun la telemetria del cargador.
    var cargaSistema: Double?
}

final class LectorBateria {
    private var salud: Double?
    private var tsSalud = -1e9
    private var consultando = false
    private let cerrojo = NSLock()

    func leer() -> BateriaInstantanea? {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard let p = IOK.propiedades(svc), p["CurrentCapacity"] != nil else { return nil }
        let datos = p["BatteryData"] as? [String: Any] ?? [:]
        func campo(_ k: String) -> Double? { numero(p[k]) ?? numero(datos[k]) }

        var b = BateriaInstantanea()
        let actual = campo("CurrentCapacity") ?? 0
        let maxima = campo("MaxCapacity") ?? 100
        b.pct = maxima > 0 ? 100 * actual / maxima : actual
        let enchufado = (p["ExternalConnected"] as? Bool) ?? false
        let cargando = (p["IsCharging"] as? Bool) ?? false
        b.estado = enchufado ? (cargando ? .cargando : .enchufado) : .descargando

        // NSNumber ya interpreta el entero como con signo: no hace falta revertir
        // el complemento a dos que ioreg imprime como sin signo.
        if let a = (p["InstantAmperage"] as? NSNumber)?.int64Value ?? (p["Amperage"] as? NSNumber)?.int64Value,
           let v = campo("Voltage"), v > 0 {
            b.vatios = abs(Double(a)) * v / 1e6
        }
        if let t = campo("TimeRemaining") ?? campo("AvgTimeToEmpty"), t > 0, t < 1440 {
            b.minutosRestantes = Int(t)
        }
        b.ciclos = campo("CycleCount").map { Int($0) }
        if let t = campo("Temperature"), t > 0 { b.temperatura = t / 100 }
        if let ad = p["AdapterDetails"] as? [String: Any], let w = numero(ad["Watts"]), w > 0 {
            b.adaptador = w
        }
        if let tel = p["PowerTelemetryData"] as? [String: Any], let carga = numero(tel["SystemLoad"]), carga > 0 {
            b.cargaSistema = carga / 1000
        }
        b.salud = saludMaxima(respaldo: campo("AppleRawMaxCapacity").flatMap { raw in
            campo("DesignCapacity").map { 100 * raw / $0 }
        })
        return b
    }

    /// Capacidad maxima tal como la muestra Ajustes (system_profiler). Es una
    /// consulta lenta: corre aparte y se refresca cada seis horas. Mientras
    /// no hay respuesta se usa la proporcion del registro de IOKit.
    private func saludMaxima(respaldo: Double?) -> Double? {
        cerrojo.lock()
        defer { cerrojo.unlock() }
        if !consultando && Sys.reloj() - tsSalud > 6 * 3600 {
            consultando = true
            DispatchQueue.global(qos: .utility).async {
                var valor: Double?
                if let s = Sys.ejecutar("/usr/sbin/system_profiler", ["SPPowerDataType"], limite: 20),
                   let r = s.range(of: #"Maximum Capacity:\s*(\d+)"#, options: .regularExpression) {
                    valor = Double(s[r].split(separator: ":").last!.trimmingCharacters(in: .whitespaces))
                }
                self.cerrojo.lock()
                self.salud = valor
                self.tsSalud = Sys.reloj()
                self.consultando = false
                self.cerrojo.unlock()
            }
        }
        return salud ?? respaldo.map { $0.rounded() }
    }
}

/// Si el equipo funciona con bateria en este momento.
func enBateria() -> Bool? {
    guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let tipo = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return nil }
    return tipo == kIOPMBatteryPowerKey
}

// MARK: - Red y disco

struct Caudal {
    var entrada: Double = 0
    var salida: Double = 0
}

struct InterfazRed {
    let nombre: String
    var entrada: Double
    var salida: Double
    var totalEntrada: UInt64
    var totalSalida: UInt64
}

/// Contadores de 64 bits de cada interfaz (NET_RT_IFLIST2). Los de 32 bits
/// de getifaddrs dan la vuelta cada 4 GB.
func contadoresRed() -> [String: (UInt64, UInt64)] {
    var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
    var tam = 0
    guard sysctl(&mib, 6, nil, &tam, nil, 0) == 0, tam > 0 else { return [:] }
    var buf = [UInt8](repeating: 0, count: tam)
    guard sysctl(&mib, 6, &buf, &tam, nil, 0) == 0 else { return [:] }
    var r: [String: (UInt64, UInt64)] = [:]
    buf.withUnsafeBytes { raw in
        var off = 0
        while off + MemoryLayout<if_msghdr>.size <= tam {
            let h = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
            guard h.ifm_msglen > 0 else { break }
            if Int32(h.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= tam {
                let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                var nombre = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                if if_indextoname(UInt32(h2.ifm_index), &nombre) != nil {
                    let n = String(cString: nombre)
                    // Solo las interfaces fisicas (en*: Ethernet, Wi-Fi, USB).
                    // Los tuneles (utun) repetirian el trafico de una VPN y
                    // loopback no sale del equipo.
                    if n.hasPrefix("en") {
                        r[n] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                    }
                }
            }
            off += Int(h.ifm_msglen)
        }
    }
    return r
}

func contadoresDisco() -> (UInt64, UInt64)? {
    var leidos: UInt64 = 0, escritos: UInt64 = 0, alguno = false
    IOK.cadaServicio("IOBlockStorageDriver") { s in
        if let st = IOK.propiedad(s, "Statistics") as? [String: Any] {
            leidos += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            escritos += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            alguno = true
        }
        return true
    }
    return alguno ? (leidos, escritos) : nil
}

/// Convierte contadores acumulados en bytes por segundo.
final class Tasa {
    private var previo: (UInt64, UInt64)?
    private var ts = 0.0
    private(set) var actual = Caudal()

    func leer(_ contadores: (UInt64, UInt64)?) -> Caudal {
        let ahora = Sys.reloj()
        guard let c = contadores else { return actual }
        if let p = previo, ahora - ts > 0.2 {
            let dt = ahora - ts
            actual = Caudal(entrada: c.0 >= p.0 ? Double(c.0 - p.0) / dt : 0,
                            salida: c.1 >= p.1 ? Double(c.1 - p.1) / dt : 0)
        }
        if previo == nil || ahora - ts > 0.2 { previo = c; ts = ahora }
        return actual
    }
}

final class LectorRed {
    private var previo: [String: (UInt64, UInt64)] = [:]
    private var ts = 0.0
    private(set) var interfaces: [InterfazRed] = []

    func leer() -> Caudal {
        let ahora = Sys.reloj()
        let actual = contadoresRed()
        let dt = ahora - ts
        if dt > 0.2 {
            interfaces = actual.map { n, c in
                let p = previo[n]
                let e = p.map { c.0 >= $0.0 ? Double(c.0 - $0.0) / dt : 0 } ?? 0
                let s = p.map { c.1 >= $0.1 ? Double(c.1 - $0.1) / dt : 0 } ?? 0
                return InterfazRed(nombre: n, entrada: e, salida: s, totalEntrada: c.0, totalSalida: c.1)
            }.sorted { $0.totalEntrada + $0.totalSalida > $1.totalEntrada + $1.totalSalida }
            previo = actual
            ts = ahora
        }
        return Caudal(entrada: interfaces.reduce(0) { $0 + $1.entrada },
                      salida: interfaces.reduce(0) { $0 + $1.salida })
    }
}
