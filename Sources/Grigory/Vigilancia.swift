import Darwin
import Foundation

// Vigilancia de procesos: los olvidados, los fantasmas y los que no dejan
// dormir al equipo. Corre siempre, tambien con la ventana cerrada: el caso
// que la motivo fue un proceso que paso dos dias consumiendo CPU sin que
// nadie lo viera.
//
//   olvidado   proceso propio cuya terminal ya no existe: ni el ni ninguno de
//              sus ancestros tiene terminal, ni depende de una app ni de
//              launchd. Pasa a critico si consume CPU de forma sostenida.
//   desbocado  cualquier proceso que mantiene casi un nucleo ocupado durante
//              varios minutos.
//   zombi      proceso terminado que su padre no ha recogido.
//   detenido   proceso propio suspendido (Ctrl+Z) desde hace rato.
//   reposo     algo impide el reposo mientras el equipo va con bateria.

enum Reglas {
    static let muestreo = 5.0
    static let intervaloFoto = 30.0
    static let ventanaOlvidado = 120.0
    static let umbralOlvidado = 20.0
    static let ventanaDesbocado = 600.0
    static let umbralDesbocado = 90.0
    /// Un zombi recien nacido es normal: su padre lo recoge enseguida.
    static let minZombi = 10.0
    static let minDetenido = 600.0
    static let minReposo = 1800.0

    /// Programas que se separan de su terminal a proposito y viven asi.
    static let desacoplados: Set<String> = ["gpg-agent", "ssh-agent", "dirmngr", "keyboxd", "scdaemon",
                                            "tmux", "screen", "mosh-server"]
    static let rutasSistema = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/",
                               "/Library/Apple/", "/Library/PrivilegedHelperTools/"]
}

enum Nivel: Int, Comparable {
    case critico = 0, aviso = 1, info = 2
    static func < (a: Nivel, b: Nivel) -> Bool { a.rawValue < b.rawValue }
    var nombre: String {
        switch self {
        case .critico: return "crítico"
        case .aviso: return "aviso"
        case .info: return "info"
        }
    }
}

enum Regla: String {
    case olvidado, desbocado, zombi, detenido, reposo
    var nombre: String { self == .detenido ? "suspendido" : rawValue }
}

struct Alerta: Identifiable {
    /// El id distingue procesos; la firma, programas: silenciar por firma
    /// sobrevive a que el proceso se relance con otro pid.
    var id: String
    let firma: String
    let regla: Regla
    let nivel: Nivel
    let titulo: String
    let motivo: String
    let pid: Int32
    let nombre: String
    let etiqueta: String
    let args: String
    let usuario: String
    let vida: Double
    let tty: String
    let ppid: Int32
    let padre: String?
    let pcpu: Double
    var rss: UInt64?
    let cpuSostenida: Double?
    let ventana: Double?
    let propio: Bool
    var zombis: [Int32] = []
    var valor: Double?
    /// Olvidados: el proceso raiz primero y despues sus descendientes.
    var familia: [Int32] = []
    /// Carpeta de trabajo: dice de que proyecto es.
    var cwd: String?
    /// Otros procesos con exactamente el mismo comando.
    var copias: [Int32] = []
    /// Uso de red de la familia (solo procesos propios; nil si no se pudo leer).
    var escucha: [Int] = []
    var conexiones: Int?
    var usoCopias: [Copia] = []
    /// Ultima vez (epoca) que se vio uso: conexiones entrantes o CPU.
    var ultimoUso: Double?
    /// Desde cuando (epoca) la app vigila esta alerta.
    var vigiladoDesde: Double?

    var comando: String { "kill \(pid)" }
}

/// Otra copia del mismo comando y su uso de red.
struct Copia {
    let pid: Int32
    let escucha: [Int]
    let conexiones: Int
    let tty: String
}

struct Cuentas {
    var procesos = 0
    var sinTerminal = 0
    var huerfanos = 0
    var zombis = 0
    var detenidos = 0
}

struct EstadoVigilancia {
    var alertas: [Alerta] = []
    var cuentas = Cuentas()
    var historial = 0.0
    var huerfanos = Set<Int32>()
    var gestionadosOk = false
}

final class Vigilante {
    private var fotos: [(ts: Double, mapa: [Int32: (inicio: Double, cpu: Double, ts: Double)])] = []
    private var vistos: [String: (inicio: Double, desde: Double)] = [:]
    private let inicio = Sys.reloj()
    private let uid = getuid()

    func analizar(_ tabla: [Int32: Proceso], gestionados: Set<Int32>?, reposo: [Asercion],
                  enBateria: Bool?) -> EstadoVigilancia {
        let ahora = Sys.reloj()
        let epoca = Date().timeIntervalSince1970

        // La CPU sostenida sale de fotos de CPU acumulada cada 30 s, no del %
        // instantaneo. Cada foto guarda cuando se midio cada valor: los
        // procesos ajenos se miden con ps a otra cadencia.
        if fotos.last.map({ ahora - $0.ts >= Reglas.intervaloFoto }) ?? true {
            var mapa: [Int32: (inicio: Double, cpu: Double, ts: Double)] = [:]
            for (pid, p) in tabla { if let c = p.cpuTotal { mapa[pid] = (p.inicio, c, p.tsCPU) } }
            fotos.append((ahora, mapa))
        }
        while let f = fotos.first, ahora - f.ts > Reglas.ventanaDesbocado + 2 * Reglas.intervaloFoto {
            fotos.removeFirst()
        }

        var e = EstadoVigilancia()
        e.gestionadosOk = gestionados != nil
        e.historial = min(ahora - inicio, Reglas.ventanaDesbocado)
        e.cuentas.procesos = tabla.count
        var memo: [Int32: String?] = [:]
        var vigentes: [String: (inicio: Double, desde: Double)] = [:]
        var zombis: [Int32: [Int32]] = [:]
        var alertas: [Alerta] = []
        var cpuOlvidados: [Int32: Double?] = [:]
        let fotoOlv = foto(Reglas.ventanaOlvidado, ahora)
        let fotoDes = foto(Reglas.ventanaDesbocado, ahora)

        func desde(_ clave: String, _ p: Proceso) -> Double {
            if let v = vistos[clave], abs(v.inicio - p.inicio) <= 3 {
                vigentes[clave] = v
                return v.desde
            }
            vigentes[clave] = (p.inicio, ahora)
            return ahora
        }

        for (pid, p) in tabla where pid > 1 {
            if p.estado == "Z" {
                e.cuentas.zombis += 1
                if ahora - desde("zombi:\(pid)", p) >= Reglas.minZombi { zombis[p.ppid, default: []].append(pid) }
                continue
            }
            if p.propio && !p.conTerminal { e.cuentas.sinTerminal += 1 }
            if p.propio && p.estado == "T" {
                e.cuentas.detenidos += 1
                let d = desde("detenido:\(pid)", p)
                if ahora - d >= Reglas.minDetenido {
                    alertas.append(alerta(.detenido, .info, "Proceso suspendido", p, tabla,
                        "Está detenido (Ctrl+Z o SIGSTOP) desde hace \(Formato.lapso(ahora - d)). No usa CPU, "
                        + "pero retiene su memoria hasta que lo reanudes con fg o lo termines."))
                }
            }

            var olvidado = false
            if p.propio, let gestionados, !Reglas.desacoplados.contains(String(p.nombre.drop(while: { $0 == "-" }))),
               dueno(pid, tabla, gestionados, &memo) == nil {
                olvidado = true
                e.huerfanos.insert(pid)
                cpuOlvidados[pid] = sostenida(p, Reglas.ventanaOlvidado, fotoOlv, ahora)
            }

            if !olvidado, p.nombre != "kernel_task",
               let cpu = sostenida(p, Reglas.ventanaDesbocado, fotoDes, ahora), cpu >= Reglas.umbralDesbocado {
                alertas.append(alerta(.desbocado, .aviso, "Proceso desbocado", p, tabla,
                    "Lleva al menos \(Formato.lapso(Reglas.ventanaDesbocado)) con \(Int(cpu.rounded()))% de un núcleo "
                    + "ocupado. Puede ser trabajo legítimo (una compilación, un modelo local) o un bucle sin salida.",
                    cpu: cpu, ventana: Reglas.ventanaDesbocado))
            }
        }
        e.cuentas.huerfanos = e.huerfanos.count

        // Una alerta por familia: un servidor como PostgreSQL son media docena
        // de procesos olvidados a la vez. La raiz es el olvidado mas alto de la
        // cadena; la CPU y la memoria son las de toda la familia.
        var familias: [Int32: [Int32]] = [:]
        for pid in e.huerfanos {
            var raiz = pid
            var pasos = 0
            while let padre = tabla[raiz]?.ppid, e.huerfanos.contains(padre), pasos < 64 {
                raiz = padre
                pasos += 1
            }
            familias[raiz, default: []].append(pid)
        }
        for (raiz, miembros) in familias {
            guard let p = tabla[raiz] else { continue }
            let orden = [raiz] + miembros.filter { $0 != raiz }.sorted()
            let cpus = orden.compactMap { cpuOlvidados[$0] ?? nil }
            let cpu: Double? = cpus.isEmpty ? nil : cpus.reduce(0, +)
            var motivo = "Ni él ni sus procesos padre tienen ventana de terminal, y no depende de ninguna "
                + "app ni de launchd: lo más probable es que se cerró la ventana o la sesión que lo lanzó y siguió corriendo."
            if orden.count > 1 { motivo += " Lo acompañan \(orden.count - 1) procesos hijos." }
            var a: Alerta
            if let cpu, cpu >= Reglas.umbralOlvidado {
                a = alerta(.olvidado, .critico, "Olvidado y consumiendo CPU", p, tabla,
                           motivo + " Entre todos mantienen \(Int(cpu.rounded()))% de un núcleo.",
                           cpu: cpu, ventana: Reglas.ventanaOlvidado)
            } else {
                a = alerta(.olvidado, .aviso, "Proceso olvidado", p, tabla, motivo,
                           cpu: cpu, ventana: Reglas.ventanaOlvidado)
            }
            a.familia = orden
            a.rss = orden.compactMap { tabla[$0]?.rss }.reduce(0, +)
            alertas.append(a)
        }

        // Carpeta de trabajo y copias del mismo comando: responden «¿de qué
        // proyecto es?» y «¿hay otro igual?».
        for i in alertas.indices where alertas[i].regla == .olvidado || alertas[i].regla == .desbocado {
            let a = alertas[i]
            if a.propio { alertas[i].cwd = carpeta(a.pid) }
            guard a.args.contains(" ") else { continue }
            let propios = Set(a.familia + [a.pid])
            alertas[i].copias = Array(tabla.values
                .filter { $0.args == a.args && !propios.contains($0.pid) && $0.estado != "Z" }
                .map(\.pid).sorted().prefix(8))
        }

        for (ppid, hijos) in zombis {
            guard let padre = tabla[ppid] else { continue }
            let n = hijos.count
            var a = alerta(.zombi, .aviso, "Procesos zombi", padre, tabla,
                "\(n) proceso\(n > 1 ? "s" : "") terminado\(n > 1 ? "s" : "") que \(padre.nombre) no ha recogido. "
                + "No consumen CPU ni memoria, pero delatan un padre colgado o mal escrito. Desaparecen al cerrar el padre.")
            a.zombis = Array(hijos.sorted().prefix(50))
            a.valor = Double(n)
            alertas.append(a)
        }

        if enBateria == true {
            for r in reposo where r.duracion >= Reglas.minReposo {
                guard let p = r.paraPid.flatMap({ tabla[$0] }) ?? tabla[r.pid] else { continue }
                var a = alerta(.reposo, .aviso, "Impide el reposo con batería", p, tabla,
                    "Lleva \(Formato.lapso(r.duracion)) impidiendo que el equipo duerma (\(r.tipo)) mientras funciona con batería.")
                a.valor = r.duracion
                a.id = "reposo:\(p.pid):\(r.tipo)"
                alertas.append(a)
            }
        }
        _ = epoca

        vistos = vigentes
        e.alertas = alertas.sorted { ($0.nivel, -($0.cpuSostenida ?? 0)) < ($1.nivel, -($1.cpuSostenida ?? 0)) }
        return e
    }

    /// Carpeta de trabajo de un proceso propio.
    private func carpeta(_ pid: Int32) -> String? {
        var vpi = proc_vnodepathinfo()
        let tam = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, tam) == tam else { return nil }
        let s = withUnsafeBytes(of: vpi.pvi_cdir.vip_path) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        return s.isEmpty || s == "/" ? nil : s
    }

    // MARK: - CPU sostenida

    /// La foto mas reciente que tenga al menos `ventana` segundos.
    private func foto(_ ventana: Double, _ ahora: Double) -> (ts: Double, mapa: [Int32: (inicio: Double, cpu: Double, ts: Double)])? {
        fotos.last { ahora - $0.ts >= ventana }
    }

    /// % de un nucleo en la ventana, o nil si no hay base para medirlo.
    private func sostenida(_ p: Proceso, _ ventana: Double,
                           _ foto: (ts: Double, mapa: [Int32: (inicio: Double, cpu: Double, ts: Double)])?,
                           _ ahora: Double) -> Double? {
        guard let cpu = p.cpuTotal else { return nil }
        if let foto {
            // Mismo pid pero otro inicio: el sistema reutilizo el numero.
            guard let previo = foto.mapa[p.pid], abs(previo.inicio - p.inicio) <= 3 else { return nil }
            let dt = p.tsCPU - previo.ts
            return dt > ventana / 2 ? max(0, (cpu - previo.cpu) / dt * 100) : nil
        }
        // Sin historial suficiente (la app acaba de arrancar), el promedio de
        // toda su vida solo es fiable si esa vida es larga.
        return p.vida >= ventana * 10 ? cpu / p.vida * 100 : nil
    }

    // MARK: - Reglas

    private func esApp(_ ruta: String) -> Bool {
        // El python de las Command Line Tools vive dentro de un Python.app, pero
        // es un interprete de terminal como cualquier otro.
        ruta.contains(".app/Contents/") && !ruta.contains("/Python.framework/") && !ruta.contains("/Python3.framework/")
    }

    /// Que mantiene vivo al proceso: "terminal", "app", "launchd", "sistema" o
    /// nil si al subir por sus padres se llega a launchd sin encontrar nada.
    /// El resultado vale para toda la cadena recorrida, asi que se memoriza.
    private func dueno(_ pid: Int32, _ tabla: [Int32: Proceso], _ gestionados: Set<Int32>,
                       _ memo: inout [Int32: String?]) -> String? {
        var cadena: [Int32] = []
        var actual = pid
        var resultado: String?
        while actual > 1 {
            if let m = memo[actual] { resultado = m; break }
            guard let p = tabla[actual], cadena.count <= 64 else { resultado = "desconocido"; break }
            cadena.append(actual)
            if p.conTerminal { resultado = "terminal"; break }
            if gestionados.contains(actual) { resultado = "launchd"; break }
            if esApp(p.ruta) { resultado = "app"; break }
            // Los servicios XPC los arranca y para launchd por cuenta de quien
            // los usa, aunque no aparezcan en `launchctl list`.
            if p.ruta.contains("/XPCServices/") || p.ruta.contains(".xpc/") { resultado = "xpc"; break }
            if Reglas.rutasSistema.contains(where: { p.ruta.hasPrefix($0) }) { resultado = "sistema"; break }
            actual = p.ppid
        }
        for c in cadena { memo[c] = .some(resultado) }
        return resultado
    }

    private func alerta(_ regla: Regla, _ nivel: Nivel, _ titulo: String, _ p: Proceso,
                        _ tabla: [Int32: Proceso], _ motivo: String,
                        cpu: Double? = nil, ventana: Double? = nil) -> Alerta {
        Alerta(id: "\(regla.rawValue):\(p.pid):\(Int(p.inicio))",
               firma: "\(regla.rawValue):\(String(p.args.prefix(200)))",
               regla: regla, nivel: nivel, titulo: titulo, motivo: motivo,
               pid: p.pid, nombre: p.nombre, etiqueta: p.etiqueta, args: String(p.args.prefix(400)),
               usuario: p.usuario, vida: p.vida, tty: p.tty, ppid: p.ppid, padre: tabla[p.ppid]?.nombre,
               pcpu: p.pcpu, rss: p.rss, cpuSostenida: cpu, ventana: ventana, propio: p.propio)
    }
}
