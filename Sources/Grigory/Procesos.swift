import Darwin
import Foundation

// Tabla de procesos del sistema.
//
// La base (pid, padre, usuario, estado, terminal, inicio) sale de
// sysctl(KERN_PROC_ALL), que cualquier usuario puede leer para todos los
// procesos. El tiempo de CPU, la memoria y los hilos salen de libproc, pero
// solo para los procesos propios: el kernel niega PROC_PIDTASKINFO sobre los
// de otros usuarios. Para esos (root, _windowserver...) se usa ps, que es
// setuid root, con una cadencia mas lenta y solo sobre sus pids.

struct Proceso: Identifiable, Equatable {
    let pid: Int32
    let ppid: Int32
    let uid: uid_t
    let usuario: String
    /// Primera letra del estado de ps: R, S, T (detenido), Z (zombi), U, I.
    let estado: Character
    let tty: String
    let inicio: Double
    var vida: Double
    var cpuTotal: Double?
    /// Momento (reloj monotono) en que se midio cpuTotal.
    var tsCPU: Double
    var pcpu: Double
    var rss: UInt64?
    var hilos: Int?
    let ruta: String
    let nombre: String
    let args: String
    let propio: Bool
    var huerfano = false

    var id: Int32 { pid }
    var conTerminal: Bool { tty != "??" }

    /// "bash · guion.command" para interpretes; el nombre a secas para el resto.
    var etiqueta: String { Proceso.etiqueta(nombre: nombre, args: args) }

    static let interpretes: Set<String> = ["bash", "zsh", "sh", "dash", "fish", "ksh", "tcsh", "python",
                                           "ruby", "perl", "php", "node", "deno", "bun", "osascript", "java"]

    static func etiqueta(nombre: String, args: String) -> String {
        var base = nombre.lowercased()
        while base.first == "-" { base.removeFirst() }
        while let u = base.last, u.isNumber || u == "." { base.removeLast() }
        guard interpretes.contains(base) else { return nombre }
        guard let espacio = args.firstIndex(of: " ") else { return nombre }
        let resto = args[args.index(after: espacio)...].trimmingCharacters(in: .whitespaces)
        guard !resto.isEmpty else { return nombre }
        let guion: String
        if resto.hasPrefix("/") {
            guion = (resto as NSString).lastPathComponent
        } else {
            let archivos = resto.split(separator: " ").filter { !$0.hasPrefix("-") && ($0.contains("/") || $0.contains(".")) }
            guion = archivos.last.map { ($0 as NSString).lastPathComponent } ?? String(resto.prefix(40))
        }
        return "\(nombre) · \(guion)"
    }
}

final class TablaProcesos {
    private var rutas: [Int32: (Double, String)] = [:]
    private var argumentos: [Int32: (Double, String)] = [:]
    private var previo: [Int32: (inicio: Double, cpu: Double, ts: Double, pcpu: Double)] = [:]
    private var ajenos: [Int32: (cpu: Double, rss: UInt64)] = [:]
    private var tsAjenos = 0.0
    private var terminales: [dev_t: String] = [:]
    private let uid = getuid()
    private var bufArgs = [UInt8](repeating: 0, count: max(Sys.entero("kern.argmax") ?? 262_144, 65_536))

    /// Lee la tabla completa. `conAjenos` refresca con ps la CPU de los
    /// procesos de otros usuarios; si no, se conserva la ultima lectura.
    func muestrear(conAjenos: Bool) -> [Int32: Proceso] {
        let ahora = Date().timeIntervalSince1970
        let reloj = Sys.reloj()
        let base = Self.kinfo()
        var tabla: [Int32: Proceso] = [:]
        tabla.reserveCapacity(base.count)
        var sinAcceso: [Int32] = []

        for k in base {
            let pid = k.kp_proc.p_pid
            let inicioTv = k.kp_proc.p_un.__p_starttime
            let inicio = Double(inicioTv.tv_sec) + Double(inicioTv.tv_usec) / 1e6
            let uidProc = k.kp_eproc.e_ucred.cr_uid
            let estado: Character
            switch Int32(k.kp_proc.p_stat) {
            case SZOMB: estado = "Z"
            case SSTOP: estado = "T"
            case SRUN: estado = "R"
            case SIDL: estado = "I"
            default: estado = "S"
            }
            var tty = "??"
            if k.kp_proc.p_flag & P_CONTROLT != 0, k.kp_eproc.e_tdev != -1 {
                tty = terminal(k.kp_eproc.e_tdev)
            }
            let comm = withUnsafeBytes(of: k.kp_proc.p_comm) {
                String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
            let ruta = ruta(pid, inicio) ?? comm
            let propio = uidProc == uid
            var nombre = (ruta as NSString).lastPathComponent
            if nombre.isEmpty { nombre = comm }

            var p = Proceso(pid: pid, ppid: k.kp_eproc.e_ppid, uid: uidProc, usuario: Sys.usuario(uidProc),
                            estado: estado, tty: tty, inicio: inicio, vida: max(0, ahora - inicio),
                            cpuTotal: nil, tsCPU: reloj, pcpu: 0, rss: nil, hilos: nil,
                            ruta: ruta, nombre: nombre,
                            args: propio && estado != "Z" ? (args(pid, inicio) ?? ruta) : ruta,
                            propio: propio)

            var ti = proc_taskinfo()
            let tam = Int32(MemoryLayout<proc_taskinfo>.size)
            if estado != "Z", proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tam) == tam {
                p.cpuTotal = Sys.segundos(mach: ti.pti_total_user + ti.pti_total_system)
                p.rss = ti.pti_resident_size
                p.hilos = Int(ti.pti_threadnum)
            } else if estado != "Z" {
                sinAcceso.append(pid)
                if let a = ajenos[pid] {
                    p.cpuTotal = a.cpu
                    p.rss = a.rss
                    p.tsCPU = tsAjenos
                }
            }
            tabla[pid] = p
        }

        if conAjenos, !sinAcceso.isEmpty {
            leerAjenos(sinAcceso)
            for pid in sinAcceso {
                if let a = ajenos[pid], var p = tabla[pid] {
                    p.cpuTotal = a.cpu
                    p.rss = a.rss
                    p.tsCPU = tsAjenos
                    tabla[pid] = p
                }
            }
        }

        // %CPU reciente: diferencia de CPU acumulada entre dos mediciones del
        // mismo proceso (mismo pid y mismo inicio).
        var nuevo: [Int32: (inicio: Double, cpu: Double, ts: Double, pcpu: Double)] = [:]
        nuevo.reserveCapacity(tabla.count)
        for (pid, var p) in tabla {
            guard let cpu = p.cpuTotal else { continue }
            if let ant = previo[pid], abs(ant.inicio - p.inicio) < 1 {
                if p.tsCPU - ant.ts > 0.2 {
                    p.pcpu = max(0, (cpu - ant.cpu) / (p.tsCPU - ant.ts) * 100)
                    nuevo[pid] = (p.inicio, cpu, p.tsCPU, p.pcpu)
                } else {
                    p.pcpu = ant.pcpu
                    nuevo[pid] = ant
                }
            } else {
                nuevo[pid] = (p.inicio, cpu, p.tsCPU, 0)
            }
            tabla[pid] = p
        }
        previo = nuevo
        rutas = rutas.filter { tabla[$0.key] != nil }
        argumentos = argumentos.filter { tabla[$0.key] != nil }
        ajenos = ajenos.filter { tabla[$0.key] != nil }
        return tabla
    }

    // MARK: - Fuentes

    private static func kinfo() -> [kinfo_proc] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var tam = 0
        guard sysctl(&mib, 4, nil, &tam, nil, 0) == 0 else { return [] }
        // Margen para los procesos que nazcan entre las dos llamadas.
        tam += tam / 8
        let paso = MemoryLayout<kinfo_proc>.stride
        var lista = [kinfo_proc](repeating: kinfo_proc(), count: tam / paso)
        guard sysctl(&mib, 4, &lista, &tam, nil, 0) == 0 else { return [] }
        return Array(lista.prefix(tam / paso))
    }

    /// Nombre corto de la terminal (s001). devname cuesta cerca de un
    /// milisegundo por llamada: se guarda por dispositivo.
    private func terminal(_ dev: dev_t) -> String {
        if let t = terminales[dev] { return t }
        var t = "??"
        if let d = devname(dev, S_IFCHR) {
            let n = String(cString: d)
            t = n.hasPrefix("tty") ? String(n.dropFirst(3)) : n
        }
        terminales[dev] = t
        return t
    }

    /// Ruta del ejecutable. proc_pidpath funciona para cualquier proceso.
    private func ruta(_ pid: Int32, _ inicio: Double) -> String? {
        if let r = rutas[pid], r.0 == inicio { return r.1 }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, 4096) > 0 else { return nil }
        let s = String(cString: buf)
        rutas[pid] = (inicio, s)
        return s
    }

    /// Linea de comandos completa (KERN_PROCARGS2). Solo para procesos propios.
    private func args(_ pid: Int32, _ inicio: Double) -> String? {
        if let a = argumentos[pid], a.0 == inicio { return a.1 }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var tam = bufArgs.count
        guard sysctl(&mib, 3, &bufArgs, &tam, nil, 0) == 0, tam > 4 else { return nil }
        let argc = bufArgs.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = 4
        while i < tam && bufArgs[i] != 0 { i += 1 }      // ruta del ejecutable
        while i < tam && bufArgs[i] == 0 { i += 1 }      // relleno
        var partes: [String] = []
        var desde = i
        while i < tam && partes.count < argc {
            if bufArgs[i] == 0 {
                partes.append(String(decoding: bufArgs[desde..<i], as: UTF8.self))
                desde = i + 1
            }
            i += 1
        }
        let s = partes.joined(separator: " ")
        argumentos[pid] = (inicio, s)
        return s.isEmpty ? nil : s
    }

    /// CPU acumulada y memoria de los procesos de otros usuarios, con ps.
    private func leerAjenos(_ pids: [Int32]) {
        let lista = pids.map(String.init).joined(separator: ",")
        guard let salida = Sys.ejecutar("/bin/ps", ["-o", "pid=,time=,rss=", "-p", lista]) else { return }
        tsAjenos = Sys.reloj()
        var r: [Int32: (cpu: Double, rss: UInt64)] = [:]
        for linea in salida.split(separator: "\n") {
            let c = linea.split(separator: " ", omittingEmptySubsequences: true)
            guard c.count >= 3, let pid = Int32(c[0]), let cpu = segundosDeTexto(c[1]),
                  let rss = UInt64(c[2]) else { continue }
            r[pid] = (cpu, rss * 1024)
        }
        ajenos = r
    }
}

/// PIDs de los trabajos que launchd mantiene vivos en la sesion.
func leerGestionados() -> Set<Int32>? {
    guard let s = Sys.ejecutar("/bin/launchctl", ["list"]) else { return nil }
    var r = Set<Int32>()
    for linea in s.split(separator: "\n").dropFirst() {
        if let t = linea.split(separator: "\t", maxSplits: 1).first, let pid = Int32(t) { r.insert(pid) }
    }
    return r
}
