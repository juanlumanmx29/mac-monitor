import AppKit
import SwiftUI

enum Modulo: String, CaseIterable, Identifiable, Hashable {
    case resumen, cpu, gpu, memoria, termico, ventiladores, consumo, bateria
    case red, disco, procesos, energia, puertos, reposo, vigilancia

    var id: String { rawValue }

    static let equipo: [Modulo] = [.cpu, .gpu, .memoria, .termico, .ventiladores, .consumo, .bateria]
    static let actividad: [Modulo] = [.red, .disco, .procesos, .energia, .puertos, .reposo]
    /// Orden de las teclas ⌘1-⌘9, el mismo del panel web.
    static let numerados: [Modulo] = [.cpu, .gpu, .memoria, .termico, .ventiladores, .consumo, .bateria, .red, .disco]

    var titulo: String {
        switch self {
        case .resumen: return "Resumen"
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memoria: return "Memoria"
        case .termico: return "Térmico"
        case .ventiladores: return "Ventiladores"
        case .consumo: return "Consumo"
        case .bateria: return "Batería"
        case .red: return "Red"
        case .disco: return "Disco"
        case .procesos: return "Procesos"
        case .energia: return "Energía"
        case .puertos: return "Puertos"
        case .reposo: return "Reposo"
        case .vigilancia: return "Vigilancia"
        }
    }

    var subtitulo: String {
        switch self {
        case .resumen: return "todo el equipo de un vistazo"
        case .cpu: return "carga y frecuencia por núcleo"
        case .gpu: return "uso, memoria y estados de frecuencia"
        case .memoria: return "reparto, compresión y presión"
        case .termico: return "termistores del SMC por familia"
        case .ventiladores: return "velocidad real y rango"
        case .consumo: return "vatios por bloque del chip"
        case .bateria: return "carga, flujo y salud"
        case .red: return "caudal por interfaz física"
        case .disco: return "lectura y escritura"
        case .procesos: return "todos los procesos del sistema"
        case .energia: return "impacto energético por proceso"
        case .puertos: return "servicios en escucha"
        case .reposo: return "quién impide que el equipo duerma"
        case .vigilancia: return "olvidados, fantasmas y desbocados"
        }
    }

    var icono: String {
        switch self {
        case .resumen: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .gpu: return "cube.transparent"
        case .memoria: return "memorychip"
        case .termico: return "thermometer.medium"
        case .ventiladores: return "fan"
        case .consumo: return "bolt"
        case .bateria: return "battery.75percent"
        case .red: return "arrow.up.arrow.down"
        case .disco: return "internaldrive"
        case .procesos: return "list.bullet.rectangle"
        case .energia: return "leaf"
        case .puertos: return "network"
        case .reposo: return "moon.zzz"
        case .vigilancia: return "eye"
        }
    }

    /// Lo caro que pide esta pagina al motor.
    var demanda: Demanda {
        switch self {
        case .resumen: return Demanda(procesos: true, puertos: true, energia: true, hilos: true)
        case .cpu: return Demanda(procesos: true, hilos: true)
        case .memoria, .procesos: return Demanda(procesos: true, puertos: true)
        case .energia: return Demanda(procesos: true, energia: true)
        case .puertos, .vigilancia: return Demanda(procesos: true, puertos: true)
        case .bateria: return Demanda(registro: true)
        default: return Demanda()
        }
    }
}

/// Estado de la interfaz, compartido por la ventana y el desplegable.
final class Interfaz: ObservableObject {
    @Published var seleccion: Modulo? = .resumen {
        didSet { if seleccion != oldValue { alCambiarDemanda?(seleccion?.demanda ?? Demanda()) } }
    }
    @Published private(set) var foto = Foto()
    @Published private(set) var historial = Historial()
    @Published var pausado = false {
        didSet { if pausado != oldValue { alPausar?(pausado) } }
    }
    @Published var filtro = ""
    @Published var soloPropios = false
    @Published var soloHuerfanos = false
    @Published var procesosElegidos = Set<Int32>()
    @Published var ordenProcesos = [KeyPathComparator(\Proceso.pcpu, order: .reverse)]
    @Published var ordenPuertos = [KeyPathComparator(\Puerto.puerto)]
    @Published var alertaResaltada: String?
    /// Filas de la tabla de procesos: se renuevan cada 3 s, no en cada
    /// muestra. Redibujar 1000 filas cada segundo costaba mas que todo el
    /// resto de la ventana, y una lista que salta cada segundo no se lee.
    @Published private(set) var procesosTabla: [Proceso] = []
    private var tsTabla = -1e9

    let equipo = Equipo.actual
    let ahorro = Ahorro()
    let ajustes = Ajustes()
    var alAbrirConfiguracion: ((Int) -> Void)?
    var alCambiarDemanda: ((Demanda) -> Void)?
    var alPausar: ((Bool) -> Void)?
    var alAbrirVentana: ((Modulo?) -> Void)?
    var alMedirEnergia: (() -> Void)?

    var ahora: Double { foto.ts.timeIntervalSince1970 }

    var actividad: Double? {
        equipo.arranque.map { foto.ts.timeIntervalSince($0) }
    }

    func recibir(_ f: Foto, _ h: Historial) {
        // En segundo plano la foto es parcial: solo la usa la barra de menu.
        guard f.completa else { return }
        foto = f
        historial = h
        if Sys.reloj() - tsTabla >= 3 || procesosTabla.isEmpty { refrescarTabla() }
    }

    func refrescarTabla() {
        procesosTabla = foto.procesos
        tsTabla = Sys.reloj()
    }

    // MARK: - Navegacion

    func ir(_ m: Modulo) { seleccion = m }

    func irAProceso(_ pid: Int32) {
        refrescarTabla()
        filtro = ""
        soloPropios = false
        soloHuerfanos = false
        procesosElegidos = [pid]
        seleccion = .procesos
    }

    func verAlerta(_ a: Alerta) {
        alertaResaltada = a.id
        seleccion = .vigilancia
    }

    // MARK: - Acciones

    func silenciar(_ a: Alerta) {
        var s = Preferencias.silenciadas
        s.insert(a.firma)
        Preferencias.silenciadas = s
        refiltrar()
    }

    func reactivar(_ a: Alerta) {
        var s = Preferencias.silenciadas
        s.remove(a.firma)
        Preferencias.silenciadas = s
        refiltrar()
    }

    private func refiltrar() {
        let s = Preferencias.silenciadas
        var f = foto
        f.activas = f.vigilancia.alertas.filter { !s.contains($0.firma) }
        f.silenciadas = f.vigilancia.alertas.filter { s.contains($0.firma) }
        foto = f
    }

    func copiar(_ texto: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(texto, forType: .string)
    }

    func mostrarEnFinder(_ ruta: String) {
        guard ruta.hasPrefix("/") else { return }
        NSWorkspace.shared.selectFile(ruta, inFileViewerRootedAtPath: "")
    }

    /// La app cuyas ventanas pertenecen al proceso, si tiene alguna.
    func app(de pid: Int32) -> NSRunningApplication? {
        Ventanas.app(de: pid, tabla: foto.tabla)
    }

    /// Que es el proceso y que pasa si se termina. Para la propia app no hay
    /// "auxiliar de": solo se usa la app responsable si es otro proceso.
    func descripcion(pid: Int32, nombre: String, ruta: String, args: String) -> Descripcion? {
        let a = app(de: pid)
        return Conocidos.describir(nombre: nombre, ruta: ruta, args: args, app: a?.processIdentifier == pid ? nil : a)
    }

    func descripcion(_ p: Proceso) -> Descripcion? {
        descripcion(pid: p.pid, nombre: p.nombre, ruta: p.ruta, args: p.args)
    }

    func descripcion(_ a: Alerta) -> Descripcion? {
        if let p = foto.tabla[a.pid] { return descripcion(p) }
        let ruta = a.args.split(separator: " ").first.map(String.init) ?? ""
        return descripcion(pid: a.pid, nombre: a.nombre, ruta: ruta, args: a.args)
    }

    func irAVentana(_ pid: Int32) {
        guard let a = app(de: pid) else {
            NSSound.beep()
            return
        }
        Ventanas.traer(a)
    }

    func abrirEnNavegador(_ puerto: Int) {
        if let u = URL(string: "http://localhost:\(puerto)") { NSWorkspace.shared.open(u) }
    }

    /// Termina un proceso tras confirmarlo. Los de otros usuarios no se pueden
    /// terminar sin privilegios: se ofrece copiar el comando con sudo.
    func terminar(_ pid: Int32, forzar: Bool = false) {
        let p = foto.tabla[pid]
        let nombre = p?.etiqueta ?? "pid \(pid)"
        let d = p.flatMap { descripcion($0) }
        let alerta = NSAlert()
        if let d, d.riesgo == .peligroso {
            alerta.messageText = "No conviene terminar «\(nombre)»"
            alerta.informativeText = d.texto
            alerta.alertStyle = .critical
            alerta.addButton(withTitle: "Entendido")
            alerta.runModal()
            return
        }
        if let p, !p.propio {
            alerta.messageText = "«\(nombre)» pertenece a \(p.usuario)"
            alerta.informativeText = "Terminarlo requiere privilegios de administrador. Puedes copiar el comando y ejecutarlo en una terminal."
            alerta.addButton(withTitle: "Copiar «sudo kill \(pid)»")
            alerta.addButton(withTitle: "Cancelar")
            if alerta.runModal() == .alertFirstButtonReturn { copiar("sudo kill \(forzar ? "-9 " : "")\(pid)") }
            return
        }
        alerta.messageText = forzar ? "¿Forzar el cierre de «\(nombre)»?" : "¿Terminar «\(nombre)»?"
        alerta.informativeText = (forzar
            ? "Se envía SIGKILL al pid \(pid): se cierra de inmediato, sin guardar nada."
            : "Se envía SIGTERM al pid \(pid): el proceso puede cerrar ordenadamente.")
            + (d?.riesgo == .relanza ? "\n\nEs un proceso de macOS: el sistema lo volverá a lanzar enseguida, así que terminarlo no suele servir de nada." : "")
        alerta.alertStyle = forzar ? .critical : .warning
        alerta.addButton(withTitle: forzar ? "Forzar cierre" : "Terminar")
        alerta.addButton(withTitle: "Cancelar")
        guard alerta.runModal() == .alertFirstButtonReturn else { return }
        if kill(pid, forzar ? SIGKILL : SIGTERM) != 0 {
            let fallo = NSAlert()
            fallo.messageText = "No se pudo terminar «\(nombre)»"
            fallo.informativeText = String(cString: strerror(errno))
            fallo.runModal()
        }
    }
}

// MARK: - Resumenes

/// Lo que se ve de un modulo en una tarjeta, en la barra lateral y en el
/// desplegable: el mismo calculo para los tres.
struct Resumen {
    var valor = "—"
    var unidad = ""
    var sub = ""
    var color: Color = Tema.tenue2
    var extras: [(String, String)] = []
    var trazos: [Trazo] = []
    var escala: Escala = .fija(100)

    /// Valor compacto para la barra lateral.
    var corto: String { valor == "—" ? valor : valor + unidad }
}

extension Interfaz {
    func resumen(_ m: Modulo) -> Resumen {
        resumen(m, foto: foto, historial: historial)
    }

    func resumen(_ m: Modulo, foto f: Foto, historial h: Historial) -> Resumen {
        var r = Resumen()
        switch m {
        case .resumen:
            break
        case .cpu:
            r.valor = "\(Int(f.cpu.total.rounded()))"
            r.unidad = "%"
            r.color = Tema.nivel(f.cpu.total)
            r.sub = "\(equipo.nucleos) núcleos · carga \(Formato.decimal(f.cpu.carga[0], 2))"
            r.extras = equipo.hibrido
                ? [("E", Formato.pct(f.cpu.promedioE)), ("P", Formato.pct(f.cpu.promedioP))]
                : [("5m", Formato.decimal(f.cpu.carga[1], 2)), ("15m", Formato.decimal(f.cpu.carga[2], 2))]
            r.trazos = [Trazo(muestras: h[.cpu], color: Tema.cian, relleno: true)]
        case .gpu:
            if let g = f.gpu, let uso = g.uso {
                r.valor = "\(Int(uso.rounded()))"
                r.unidad = "%"
                r.color = Tema.nivel(uso)
                r.sub = g.memoriaEnUso.map { Formato.gb(UInt64($0)) + " GB de memoria" } ?? "sin datos"
                r.extras = [("render", Formato.pct(g.render)), ("frec.", Formato.mhz(f.potencia?.gpuMHz))]
            } else {
                r.sub = "sin datos"
            }
            r.trazos = [Trazo(muestras: h[.gpu], color: Tema.violeta, relleno: true)]
        case .memoria:
            if let mem = f.memoria {
                r.valor = "\(Int(mem.pct.rounded()))"
                r.unidad = "%"
                r.color = mem.presion >= 4 ? Tema.rojo : mem.presion >= 2 ? Tema.ambar : Tema.nivel(mem.pct)
                r.sub = "\(Formato.gb(mem.usada)) / \(Formato.gb(mem.total)) GB"
                r.extras = [("compr.", Formato.gb(mem.comprimidas) + " GB"),
                            ("swap", mem.swapUsado > 0 ? Formato.gb(mem.swapUsado) + " GB" : "0")]
            }
            r.trazos = [Trazo(muestras: h[.memoria], color: Tema.violeta, relleno: true)]
        case .termico:
            if let t = f.tempMax {
                r.valor = "\(Int(t.rounded()))"
                r.unidad = "°"
                r.color = Tema.temperatura(t)
                r.sub = f.familiaMax?.nombre ?? ""
            } else {
                r.sub = f.temperaturas.isEmpty ? "sin sensores" : "en reposo"
            }
            r.extras = [("familias", "\(f.temperaturas.count)"),
                        ("presión", PresionTermica.nombre(f.potencia?.termico))]
            r.trazos = [Trazo(muestras: h[.temperatura], color: Tema.ambar, relleno: true)]
            r.escala = .auto(minimo: 60)
        case .ventiladores:
            let rpm = f.ventiladores.compactMap(\.rpm)
            r.valor = rpm.isEmpty ? "—" : "\(Int(f.rpmMax.rounded()))"
            r.unidad = rpm.isEmpty ? "" : " rpm"
            r.color = f.rpmMax > 0 ? Tema.cian : Tema.tenue2
            r.sub = rpm.isEmpty ? (f.ventiladores.isEmpty ? "sin ventiladores" : "sin datos")
                : f.rpmMax > 0 ? "\(rpm.filter { $0 > 0 }.count) en marcha" : "detenidos"
            r.extras = [("ventiladores", "\(f.ventiladores.count)")]
            if !rpm.isEmpty { r.extras.append(("rpm", rpm.map { "\(Int($0))" }.joined(separator: " / "))) }
            r.trazos = [Trazo(muestras: h[.ventilador], color: Tema.cian, relleno: true)]
            r.escala = .auto(minimo: 1000)
        case .consumo:
            if let w = f.vatios {
                r.valor = Formato.decimal(w, 1)
                r.unidad = "W"
                r.color = Tema.ambar
                r.sub = f.potencia?.bloquesCongelados == true
                    ? "total del equipo · sin desglose"
                    : "cpu \(Formato.decimal(f.potencia?.cpu ?? 0, 1)) · gpu \(Formato.decimal(f.potencia?.gpu ?? 0, 1)) W"
                r.extras = [("ane", Formato.vatios(f.potencia?.ane)), ("dram", Formato.vatios(f.potencia?.dram))]
            } else {
                r.sub = "sin datos de IOReport"
            }
            r.trazos = [Trazo(muestras: h[.potencia], color: Tema.ambar, relleno: true)]
            r.escala = .auto(minimo: 10)
        case .bateria:
            if let b = f.bateria {
                r.valor = "\(Int(b.pct.rounded()))"
                r.unidad = "%"
                r.color = b.estado == .descargando && b.pct < 20 ? Tema.rojo : Tema.verde
                r.sub = b.estado.rawValue + (b.vatios.map { $0 > 0.05 ? " · \(Formato.decimal($0, 1)) W" : "" } ?? "")
                r.extras = [("ciclos", b.ciclos.map(String.init) ?? "—"), ("salud", Formato.pct(b.salud))]
                if let m = b.minutosRestantes { r.extras.append(("quedan", Formato.lapso(Double(m) * 60))) }
            } else {
                r.sub = "sin batería"
            }
            r.trazos = [Trazo(muestras: h[.bateria], color: Tema.verde, relleno: true)]
        case .red:
            let (v, u) = Formato.tasaPartes(f.red.entrada)
            r.valor = v
            r.unidad = " " + u
            r.color = Tema.verde
            r.sub = "↓ \(Formato.tasa(f.red.entrada))  ↑ \(Formato.tasa(f.red.salida))"
            r.extras = [("máx 60 s", Formato.tasa(max(h.maximo(.redEntrada, ultimos: 60, ahora: f.ts.timeIntervalSince1970),
                                                       h.maximo(.redSalida, ultimos: 60, ahora: f.ts.timeIntervalSince1970))))]
            r.trazos = [Trazo(muestras: h[.redEntrada], color: Tema.verde, relleno: true),
                        Trazo(muestras: h[.redSalida], color: Tema.cian)]
            r.escala = .auto(minimo: 10_240)
        case .disco:
            let (v, u) = Formato.tasaPartes(max(f.disco.entrada, f.disco.salida))
            r.valor = v
            r.unidad = " " + u
            r.color = Tema.ambar
            r.sub = "L \(Formato.tasa(f.disco.entrada))  E \(Formato.tasa(f.disco.salida))"
            r.extras = [("máx 60 s", Formato.tasa(max(h.maximo(.discoLectura, ultimos: 60, ahora: f.ts.timeIntervalSince1970),
                                                       h.maximo(.discoEscritura, ultimos: 60, ahora: f.ts.timeIntervalSince1970))))]
            r.trazos = [Trazo(muestras: h[.discoLectura], color: Tema.ambar, relleno: true),
                        Trazo(muestras: h[.discoEscritura], color: Tema.violeta)]
            r.escala = .auto(minimo: 102_400)
        case .procesos:
            r.valor = "\(f.tabla.count)"
            r.color = Tema.cian
            if let p = f.procesos.first { r.sub = "\(p.nombre) \(Int(p.pcpu.rounded()))%" }
            r.extras = [("hilos", f.totalHilos.map(String.init) ?? "—"),
                        ("sin terminal", "\(f.vigilancia.cuentas.sinTerminal)")]
            r.trazos = [Trazo(muestras: h[.procesos], color: Tema.cian, relleno: true)]
            r.escala = .auto(minimo: 10)
        case .energia:
            if let top = f.energia?.first {
                r.valor = Formato.decimal(top.impacto, 1)
                r.color = Tema.ambar
                r.sub = top.etiqueta
                r.extras = (f.energia ?? []).dropFirst().prefix(2).map { (String($0.nombre.prefix(13)), Formato.decimal($0.impacto, 1)) }
            } else {
                r.sub = "midiendo…"
            }
            r.trazos = [Trazo(muestras: h[.energia], color: Tema.ambar, relleno: true)]
            r.escala = .auto(minimo: 10)
        case .puertos:
            let exp = f.puertos.filter(\.expuesto).count
            r.valor = "\(f.puertos.count)"
            r.color = exp > 0 ? Tema.ambar : Tema.verde
            r.sub = exp > 0 ? "\(exp) expuesto\(exp > 1 ? "s" : "")" : "todos locales"
            r.extras = [("expuestos", "\(exp)"),
                        ("huérfanos", "\(f.puertos.filter { f.tabla[$0.pid]?.huerfano == true }.count)")]
            r.trazos = [Trazo(muestras: h[.puertos], color: Tema.verde, relleno: true)]
            r.escala = .auto(minimo: 5)
        case .reposo:
            let largo = f.reposo.first
            let alerta = f.enBateria == true && (largo?.duracion ?? 0) >= Reglas.minReposo
            r.valor = "\(f.reposo.count)"
            r.color = alerta ? Tema.ambar : f.reposo.isEmpty ? Tema.verde : Tema.violeta
            r.sub = largo.map { "\($0.paraNombre ?? $0.proceso) · \(Formato.lapso($0.duracion))" } ?? "nada lo impide"
            r.extras = [("batería", f.enBateria.map { $0 ? "sí" : "no" } ?? "—"),
                        ("más de 30m", "\(f.reposo.filter { $0.duracion >= Reglas.minReposo }.count)")]
            r.trazos = [Trazo(muestras: h[.reposo], color: Tema.violeta, relleno: true)]
            r.escala = .auto(minimo: 4)
        case .vigilancia:
            let act = f.activas
            r.valor = "\(act.count)"
            r.color = act.isEmpty ? Tema.verde : Tema.color(f.peorNivel)
            r.sub = act.first.map { "\($0.titulo.lowercased()) · \($0.etiqueta)" } ?? "nada olvidado ni fantasma"
            r.extras = [("huérfanos", "\(f.vigilancia.cuentas.huerfanos)"), ("zombis", "\(f.vigilancia.cuentas.zombis)")]
            if !f.silenciadas.isEmpty { r.extras.append(("silenciadas", "\(f.silenciadas.count)")) }
            r.trazos = [Trazo(muestras: h[.alertas], color: Tema.rojo, relleno: true)]
            r.escala = .auto(minimo: 4)
        }
        return r
    }
}

// MARK: - ¿Se esta usando?

struct Veredicto {
    let corto: String
    let texto: String
    let tono: Tono
}

extension Alerta {
    /// «¿Se está usando?» para olvidados y desbocados: conexiones entrantes,
    /// CPU sostenida y la ultima vez que se vio uso.
    var veredicto: Veredicto? {
        guard regla == .olvidado || regla == .desbocado else { return nil }
        let puertos = escucha.map { ":\($0)" }.joined(separator: " ")
        if let c = conexiones, c > 0 {
            return Veredicto(corto: "en uso",
                             texto: "En uso: \(c) conexión\(c == 1 ? "" : "es") entrante\(c == 1 ? "" : "s") en \(puertos). Antes de terminarlo, conviene saber quién lo usa.",
                             tono: .ok)
        }
        if let cpu = cpuSostenida, cpu >= 5 {
            return Veredicto(corto: "\(Int(cpu.rounded()))% CPU",
                             texto: "Trabajando: mantiene \(Int(cpu.rounded())) % de un núcleo\(escucha.isEmpty ? "" : ", aunque nadie está conectado a \(puertos)").",
                             tono: nivel == .critico ? .critico : .aviso)
        }
        guard conexiones != nil || cpuSostenida != nil else { return nil }
        let ahora = Date().timeIntervalSince1970
        var cuando = ""
        if let u = ultimoUso, ahora - u > 10 {
            cuando = "; el último uso fue hace \(Formato.lapso(ahora - u))"
        } else if ultimoUso == nil, let d = vigiladoDesde, ahora - d > 60 {
            cuando = "; sin uso desde que la app lo vigila (\(Formato.lapso(ahora - d)))"
        }
        let que = escucha.isEmpty ? "no escucha en ningún puerto y casi no usa CPU"
                                  : "escucha en \(puertos) pero nadie está conectado, y casi no usa CPU"
        return Veredicto(corto: "inactivo", texto: "Inactivo ahora: \(que)\(cuando).", tono: .aviso)
    }

    /// Otras copias del mismo comando, con cual se esta usando.
    var sobreCopias: String? {
        if usoCopias.isEmpty {
            return copias.isEmpty ? nil : "Hay \(copias.count) proceso\(copias.count == 1 ? "" : "s") más con el mismo comando."
        }
        let lista = usoCopias.map { c in
            "pid \(c.pid)" + (c.escucha.isEmpty ? "" : " en " + c.escucha.map { ":\($0)" }.joined(separator: " "))
                + (c.tty != "??" ? " (terminal \(c.tty))" : "") + (c.conexiones > 0 ? ", en uso" : "")
        }
        let n = usoCopias.count
        var t = "Hay \(n) copia\(n == 1 ? "" : "s") más del mismo comando: \(lista.joined(separator: "; "))."
        if veredicto?.corto == "inactivo" {
            t += usoCopias.contains { $0.conexiones > 0 }
                ? " Esta probablemente sobra: la que se usa es la otra."
                : " Ninguna tiene conexiones ahora: quizá sobran varias."
        }
        return t
    }

    /// Carpeta de trabajo con ~ en lugar de la carpeta personal.
    var carpetaCorta: String? {
        cwd.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
    }

    /// Nombre para listas: el comando y, si es una familia, cuantos procesos.
    var nombreFamilia: String {
        familia.count > 1 ? "\(etiqueta) · \(familia.count) procesos" : etiqueta
    }
}
