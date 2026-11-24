import Darwin
import Foundation
import IOKit

/// Topologia del equipo, detectada una sola vez al arrancar. Nada del
/// hardware va fijo en el codigo: el mismo binario sirve en cualquier Mac.
struct Equipo {
    let chip: String
    let modelo: String
    let nucleos: Int
    let nucleosE: Int
    let nucleosP: Int
    let ram: UInt64
    let gpuNucleos: Int?
    let macos: String
    let arquitectura: String
    let arranque: Date?

    var hibrido: Bool { nucleosE > 0 }
    var chipCorto: String {
        chip.hasPrefix("Apple ") ? String(chip.dropFirst(6)) : chip
    }

    /// Los nucleos de eficiencia se enumeran primero. Sin cluster de
    /// eficiencia (Intel) todos cuentan como de rendimiento.
    func esEficiencia(_ i: Int) -> Bool { i < nucleosE }

    static let actual: Equipo = detectar()

    private static func detectar() -> Equipo {
        let total = Sys.entero("hw.ncpu") ?? 1
        // En Apple Silicon perflevel0 es el cluster de rendimiento y perflevel1
        // el de eficiencia. Los Mac Intel no publican estas claves.
        var p = Sys.entero("hw.perflevel0.logicalcpu") ?? 0
        var e = Sys.entero("hw.perflevel1.logicalcpu") ?? 0
        if p == 0 { p = total; e = 0 }

        var gpu: Int?
        IOK.cadaServicio("IOAccelerator") { s in
            if let n = numero(IOK.propiedad(s, "gpu-core-count")) { gpu = Int(n); return false }
            return true
        }

        var tv = timeval()
        var tam = MemoryLayout<timeval>.size
        var arranque: Date?
        if sysctlbyname("kern.boottime", &tv, &tam, nil, 0) == 0, tv.tv_sec > 0 {
            arranque = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6)
        }

        var u = utsname()
        uname(&u)
        let maquina = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }

        return Equipo(
            chip: Sys.cadena("machdep.cpu.brand_string") ?? "CPU",
            modelo: Sys.cadena("hw.model") ?? "",
            nucleos: total, nucleosE: e, nucleosP: p,
            ram: UInt64(Sys.entero("hw.memsize") ?? 0),
            gpuNucleos: gpu,
            macos: Sys.cadena("kern.osproductversion") ?? "",
            arquitectura: maquina,
            arranque: arranque)
    }
}

// MARK: - CPU

struct CPUInstantanea {
    var nucleos: [Double] = []
    var total = 0.0
    var promedioE = 0.0
    var promedioP = 0.0
    var carga: [Double] = [0, 0, 0]
}

/// Uso por nucleo entre dos lecturas consecutivas de host_processor_info.
final class LectorCPU {
    private var previo: [[UInt32]]
    private var tsPrevio = Sys.reloj()
    private var ultima = CPUInstantanea()

    init() { previo = Self.ticks() ?? [] }

    private static func ticks() -> [[UInt32]]? {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var cuenta: mach_msg_type_number_t = 0
        guard host_processor_info(Sys.host, PROCESSOR_CPU_LOAD_INFO, &n, &info, &cuenta) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(cuenta) * MemoryLayout<integer_t>.stride))
        }
        let estados = Int(CPU_STATE_MAX)
        return (0..<Int(n)).map { i in
            (0..<estados).map { s in UInt32(bitPattern: info[i * estados + s]) }
        }
    }

    func leer(_ equipo: Equipo) -> CPUInstantanea {
        // Con menos de 0,3 s entre lecturas los ticks son tan pocos que el
        // porcentaje sale a saltos: se repite la ultima.
        let ahora = Sys.reloj()
        if !ultima.nucleos.isEmpty && ahora - tsPrevio < 0.3 { return ultima }
        var r = CPUInstantanea()
        guard let actual = Self.ticks() else { return r }
        defer { previo = actual; tsPrevio = ahora; ultima = r }
        guard previo.count == actual.count else { return r }
        let idle = Int(CPU_STATE_IDLE)
        r.nucleos = zip(previo, actual).map { ant, act in
            let delta = zip(ant, act).map { Double($1 &- $0) }
            let total = delta.reduce(0, +)
            guard total > 0 else { return 0 }
            return max(0, min(100, 100 * (total - delta[idle]) / total))
        }
        func promedio(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
        r.total = promedio(r.nucleos)
        r.promedioE = promedio(r.nucleos.indices.filter { equipo.esEficiencia($0) }.map { r.nucleos[$0] })
        r.promedioP = promedio(r.nucleos.indices.filter { !equipo.esEficiencia($0) }.map { r.nucleos[$0] })
        var carga = [Double](repeating: 0, count: 3)
        if getloadavg(&carga, 3) == 3 { r.carga = carga }
        return r
    }
}

// MARK: - Memoria

struct MemoriaInstantanea {
    var total: UInt64 = 0
    var usada: UInt64 = 0
    var apps: UInt64 = 0
    var ancladas: UInt64 = 0
    var comprimidas: UInt64 = 0
    var cache: UInt64 = 0
    var libre: UInt64 = 0
    var swapTotal: UInt64 = 0
    var swapUsado: UInt64 = 0
    /// Nivel de presion del kernel: 1 normal, 2 aviso, 4 critica.
    var presion = 1
    var pct: Double { total > 0 ? 100 * Double(usada) / Double(total) : 0 }
}

/// Replica el calculo de "Memoria usada" del Monitor de Actividad, leyendo
/// las mismas cifras que imprime vm_stat sin lanzar ningun proceso.
func leerMemoria(total: UInt64) -> MemoriaInstantanea? {
    var vm = vm_statistics64()
    var cuenta = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let rc = withUnsafeMutablePointer(to: &vm) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(cuenta)) {
            host_statistics64(Sys.host, HOST_VM_INFO64, $0, &cuenta)
        }
    }
    guard rc == KERN_SUCCESS else { return nil }
    let pagina = UInt64(Sys.entero("vm.pagesize") ?? 16384)
    func b(_ paginas: UInt32) -> UInt64 { UInt64(paginas) * pagina }

    var m = MemoriaInstantanea()
    m.total = total
    // Mismo criterio que el Monitor de Actividad: la memoria "usada" no
    // incluye los archivos en cache, que el sistema libera a demanda.
    let anonimas = b(vm.internal_page_count)
    let purgables = b(vm.purgeable_count)
    m.apps = anonimas > purgables ? anonimas - purgables : 0
    m.ancladas = b(vm.wire_count)
    m.comprimidas = b(vm.compressor_page_count)
    m.cache = b(vm.external_page_count)
    m.libre = vm.free_count > vm.speculative_count ? b(vm.free_count - vm.speculative_count) : 0
    m.usada = m.apps + m.ancladas + m.comprimidas

    var swap = xsw_usage()
    var tam = MemoryLayout<xsw_usage>.size
    if sysctlbyname("vm.swapusage", &swap, &tam, nil, 0) == 0 {
        m.swapTotal = swap.xsu_total
        m.swapUsado = swap.xsu_used
    }
    m.presion = Sys.entero("kern.memorystatus_vm_pressure_level") ?? 1
    return m
}
