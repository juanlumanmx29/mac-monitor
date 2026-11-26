import Darwin
import Foundation

// El motor decide que se lee y cada cuanto. Hay dos regimenes:
//
//   visible    la ventana o el desplegable estan a la vista: todo, cada 1 s.
//   fondo      nadie mira: cada 5 s, solo la vigilancia y lo que muestre la
//              barra de menu. Nada de GPU, ventiladores, puertos ni energia.
//
// Lo caro depende ademas de la pagina que se esta viendo (Demanda): el ps de
// los procesos ajenos va cada 5 s solo si se ven procesos (si no, cada 30 s,
// lo que necesita la vigilancia); los puertos, cada 5 s solo si se ven; la
// energia (un top que gasta medio segundo de CPU), cada 30 s solo si se ve,
// y fuera del hilo del motor. launchd va cada 30 s y el reposo cada 15 s.

/// Lo que la pagina visible necesita ademas de lo basico.
struct Demanda: Equatable {
    var procesos = false
    var puertos = false
    var energia = false
    var hilos = false
    /// Registro de energia de macOS (¿qué gastó la batería?).
    var registro = false
    static let todo = Demanda(procesos: true, puertos: true, energia: true, hilos: true, registro: true)
}

struct CostoPropio {
    var cpu = 0.0
    var auxiliares = 0.0
    var memoria: UInt64 = 0
    var ciclo = 0.0
}

struct Fuentes {
    var smc = false
    var smcMotivo = ""
    var sensores = 0
    var ioreport = false
    var ioreportMotivo = ""
    var vigilancia = false
}

struct Foto {
    var ts = Date()
    /// false en segundo plano: solo trae lo que necesita la barra de menu.
    var completa = false
    var intervalo = 1.0
    var cpu = CPUInstantanea()
    var memoria: MemoriaInstantanea?
    var gpu: GPUInstantanea?
    var bateria: BateriaInstantanea?
    var potencia: Potencia?
    var ventiladores: [Ventilador] = []
    var temperaturas: [FamiliaTermica] = []
    var red = Caudal()
    var interfaces: [InterfazRed] = []
    var disco = Caudal()
    var tabla: [Int32: Proceso] = [:]
    /// Todos los procesos, de mayor a menor CPU.
    var procesos: [Proceso] = []
    var totalHilos: Int?
    var puertos: [Puerto] = []
    var energia: [FilaEnergia]?
    var edadEnergia: Double?
    var tramo: TramoBateria?
    var reposo: [Asercion] = []
    var enBateria: Bool?
    var vigilancia = EstadoVigilancia()
    var activas: [Alerta] = []
    var silenciadas: [Alerta] = []
    var propio = CostoPropio()
    var fuentes = Fuentes()

    var tempMax: Double? { temperaturas.compactMap(\.max).max() }
    var familiaMax: FamiliaTermica? {
        temperaturas.filter { $0.max != nil }.max { $0.max! < $1.max! }
    }
    var rpmMax: Double { ventiladores.compactMap(\.rpm).max() ?? 0 }
    /// Consumo de todo el equipo; si no se sabe, la suma de los bloques.
    var vatios: Double? {
        if let s = potencia?.sistema { return s }
        guard let p = potencia, let c = p.cpu else { return nil }
        return c + (p.gpu ?? 0) + (p.ane ?? 0) + (p.dram ?? 0)
    }
    var peorNivel: Nivel? { activas.map(\.nivel).min() }
}

// MARK: - Historial

enum Serie: Int, CaseIterable {
    case cpu, cpuE, cpuP, gpu, memoria, temperatura, ventilador, potencia, potenciaCPU, potenciaGPU,
         bateria, redEntrada, redSalida, discoLectura, discoEscritura, procesos, puertos, energia,
         reposo, alertas
}

struct Muestra {
    let t: Double
    let v: Double
}

/// Diez minutos a 1 s por serie. Con la ventana cerrada las series de la
/// barra siguen a 5 s, y los huecos se dibujan como cortes.
struct Historial {
    static let capacidad = 600
    private(set) var series = [[Muestra]](repeating: [], count: Serie.allCases.count)

    subscript(_ s: Serie) -> [Muestra] { series[s.rawValue] }

    mutating func agregar(_ s: Serie, _ v: Double?, _ t: Double) {
        guard let v, v.isFinite else { return }
        series[s.rawValue].append(Muestra(t: t, v: v))
        if series[s.rawValue].count > Self.capacidad {
            series[s.rawValue].removeFirst(series[s.rawValue].count - Self.capacidad)
        }
    }

    func maximo(_ s: Serie, ultimos segundos: Double, ahora: Double) -> Double {
        self[s].reversed().prefix { ahora - $0.t <= segundos }.map(\.v).max() ?? 0
    }
}

// MARK: - Preferencias

enum Preferencias {
    private static let d = UserDefaults.standard

    static var silenciadas: Set<String> {
        get { Set(d.stringArray(forKey: "silenciadas") ?? []) }
        set { d.set(Array(newValue).sorted(), forKey: "silenciadas") }
    }
    static var notificaciones: Bool {
        get { d.object(forKey: "notificaciones") as? Bool ?? true }
        set { d.set(newValue, forKey: "notificaciones") }
    }
    static func barra(_ m: MetricaBarra) -> Bool {
        d.object(forKey: "barra.\(m.rawValue)") as? Bool ?? m.porDefecto
    }
    static func ponerBarra(_ m: MetricaBarra, _ v: Bool) { d.set(v, forKey: "barra.\(m.rawValue)") }
    // Modo ahorro
    static var ahorroActivo: Bool {
        get { d.bool(forKey: "ahorro.activo") }
        set { d.set(newValue, forKey: "ahorro.activo") }
    }
    static var ahorroBajoConsumo: Bool {
        get { d.object(forKey: "ahorro.bajoConsumo") as? Bool ?? true }
        set { d.set(newValue, forKey: "ahorro.bajoConsumo") }
    }
    static var ahorroBrillo: Bool {
        get { d.object(forKey: "ahorro.brillo") as? Bool ?? true }
        set { d.set(newValue, forKey: "ahorro.brillo") }
    }
    /// Brillo durante el modo ahorro, de 0 a 1.
    static var ahorroNivelBrillo: Double {
        get { d.object(forKey: "ahorro.nivelBrillo") as? Double ?? 0.5 }
        set { d.set(newValue, forKey: "ahorro.nivelBrillo") }
    }
    /// Lo que habia antes de activar el modo, para dejarlo igual al salir.
    static var ahorroPrevio: [String: Any] {
        get { d.dictionary(forKey: "ahorro.previo") ?? [:] }
        set { d.set(newValue, forKey: "ahorro.previo") }
    }

    /// 0 sigue al sistema, 1 oscuro, 2 claro.
    static var apariencia: Int {
        get { d.integer(forKey: "apariencia") }
        set { d.set(newValue, forKey: "apariencia") }
    }
}

enum MetricaBarra: String, CaseIterable {
    case cpu, temperatura, memoria, potencia, red
    var porDefecto: Bool { self == .cpu || self == .temperatura }
    var nombre: String {
        switch self {
        case .cpu: return "CPU"
        case .temperatura: return "Temperatura"
        case .memoria: return "Memoria"
        case .potencia: return "Consumo"
        case .red: return "Red"
        }
    }
}

// MARK: - Motor

final class Motor {
    let equipo = Equipo.actual
    private let cola = DispatchQueue(label: "local.grigory.motor", qos: .utility)
    private var temporizador: DispatchSourceTimer?
    private var intervalo = 0.0
    private var visible = false
    private var pausado = false
    private var demanda = Demanda.todo

    /// Se invoca en el hilo principal tras cada ciclo.
    var alPublicar: ((Foto, Historial) -> Void)?
    /// Alerta critica nueva (una vez por proceso), en el hilo principal.
    var alAlertaCritica: ((Alerta) -> Void)?

    private let lectorCPU = LectorCPU()
    private let smc = SMC()
    private let ioreport = IOReport()
    private let lectorBateria = LectorBateria()
    private let lectorRed = LectorRed()
    private let tasaDisco = Tasa()
    private let tablaProcesos = TablaProcesos()
    private let vigilante = Vigilante()

    private var historial = Historial()
    private var vencimientos: [String: Double] = [:]
    private var gestionados: Set<Int32>?
    private var reposo: [Asercion] = []
    private var enBat: Bool?
    private var puertos: [Puerto] = []
    private var hilos: Int?
    private var energia: (ts: Double, filas: [FilaEnergia])?
    private var midiendoEnergia = false
    private var tramo: TramoBateria?
    private var leyendoRegistro = false
    /// Modo ahorro: muestreo lento y nada de lo caro.
    private var ahorro = false
    private var avisados = Set<String>()
    private var usoPrevio: (t: Double, propio: Double, hijos: Double)?
    private var bateria: BateriaInstantanea?
    private var ventiladores: [Ventilador] = []
    private var temperaturas: [FamiliaTermica] = []
    private var ultimaVigilancia: EstadoVigilancia?
    private var vistoDesde: [String: Double] = [:]
    private var ultimoUso: [String: Double] = [:]

    /// Milisegundos por tramo del ultimo ciclo (diagnostico de --volcar).
    private(set) var perfil: [(String, Double)] = []
    private var marcaPerfil = 0.0
    private func tramo(_ nombre: String) {
        let t = Sys.reloj()
        perfil.append((nombre, (t - marcaPerfil) * 1000))
        marcaPerfil = t
    }

    func iniciar() {
        cola.async { self.reprogramar(inmediato: true) }
    }

    func ponerVisible(_ v: Bool) {
        cola.async {
            guard v != self.visible else { return }
            self.visible = v
            self.reprogramar(inmediato: v)
        }
    }

    func ponerDemanda(_ d: Demanda) {
        cola.async { self.demanda = d }
    }

    func ponerAhorro(_ a: Bool) {
        cola.async {
            self.ahorro = a
            self.reprogramar(inmediato: false)
        }
    }

    func pausar(_ p: Bool) {
        cola.async {
            self.pausado = p
            self.reprogramar(inmediato: false)
        }
    }

    /// Un ciclo sincrono, para --volcar y --medir.
    func cicloSincrono(visible v: Bool) -> (Foto, Historial) {
        cola.sync {
            visible = v
            return ciclo()
        }
    }

    private var aLaVista: Bool { visible && !pausado }

    private func reprogramar(inmediato: Bool) {
        // En modo ahorro, la ventana abierta se refresca cada 3 s.
        let nuevo = aLaVista ? (ahorro ? 3.0 : 1.0) : Reglas.muestreo
        if temporizador == nil {
            let t = DispatchSource.makeTimerSource(queue: cola)
            t.setEventHandler { [weak self] in self?.disparar() }
            temporizador = t
            t.resume()
        }
        guard nuevo != intervalo || inmediato else { return }
        intervalo = nuevo
        // Holgura del 10 %: deja que el sistema agrupe los despertares.
        temporizador?.schedule(deadline: .now() + (inmediato ? 0.05 : nuevo), repeating: nuevo,
                               leeway: .milliseconds(Int(nuevo * 100)))
    }

    private func disparar() {
        let (foto, hist) = ciclo()
        let criticas = foto.activas.filter { $0.nivel == .critico && !avisados.contains($0.id) }
        for a in criticas { avisados.insert(a.id) }
        if avisados.count > 500 { avisados = Set(criticas.map(\.id)) }
        DispatchQueue.main.async {
            self.alPublicar?(foto, hist)
            for a in criticas { self.alAlertaCritica?(a) }
        }
    }

    private func vencido(_ clave: String, _ cada: Double, _ ahora: Double) -> Bool {
        if ahora - (vencimientos[clave] ?? -1e9) >= cada - 0.05 {
            vencimientos[clave] = ahora
            return true
        }
        return false
    }

    private func ciclo() -> (Foto, Historial) {
        let t0 = Sys.reloj()
        let ahora = t0
        perfil = []
        marcaPerfil = t0
        let t = Date().timeIntervalSince1970
        let completa = aLaVista
        var f = Foto()
        f.completa = completa
        f.intervalo = completa ? 1 : Reglas.muestreo

        f.cpu = lectorCPU.leer(equipo)
        f.memoria = leerMemoria(total: equipo.ram)
        tramo("cpu+memoria")

        // Procesos y vigilancia: siempre.
        let tabla = tablaProcesos.muestrear(
            conAjenos: vencido("ajenos", completa && demanda.procesos && !ahorro ? 5 : Reglas.intervaloFoto, ahora))
        tramo("procesos")
        if gestionados == nil || vencido("launchd", 30, ahora) {
            if let g = leerGestionados() { gestionados = g }
        }
        if vencido("reposo", 15, ahora) {
            reposo = leerReposo() ?? []
            enBat = enBateria()
        }
        tramo("launchd+reposo")
        // Las reglas miden ventanas de minutos: cada 5 s basta, tambien con la
        // ventana abierta.
        if ultimaVigilancia == nil || vencido("vigilancia", Reglas.muestreo, ahora) {
            var v = vigilante.analizar(tabla, gestionados: gestionados, reposo: reposo, enBateria: enBat)
            usoDeRed(&v, tabla)
            ultimaVigilancia = v
        }
        f.vigilancia = ultimaVigilancia!
        tramo("vigilancia")
        var marcada = tabla
        for pid in f.vigilancia.huerfanos { marcada[pid]?.huerfano = true }
        f.tabla = marcada
        let silenciadas = Preferencias.silenciadas
        f.activas = f.vigilancia.alertas.filter { !silenciadas.contains($0.firma) }
        f.silenciadas = f.vigilancia.alertas.filter { silenciadas.contains($0.firma) }
        f.reposo = reposo.map { r in
            var r = r
            r.paraNombre = r.paraPid.flatMap { marcada[$0]?.nombre }
            return r
        }
        f.enBateria = enBat

        let quiere = { (m: MetricaBarra) in completa || Preferencias.barra(m) }
        // Los termistores cambian despacio: cada 2 s basta.
        if quiere(.temperatura) && smc.listo && (temperaturas.isEmpty || vencido("temperaturas", 2, ahora)) {
            // En fondo la barra solo muestra la temperatura de la CPU: 20
            // termistores en vez de todos.
            temperaturas = smc.temperaturas(solo: completa ? nil : ["Tp", "Te"])
        }
        f.temperaturas = temperaturas
        tramo("temperaturas")
        if quiere(.red) {
            f.red = lectorRed.leer()
            f.interfaces = lectorRed.interfaces
        }
        tramo("red")
        if quiere(.potencia) {
            f.potencia = ioreport.leer(equipo)
            if bateria == nil || vencido("bateria", completa ? 2 : Reglas.muestreo, ahora) { bateria = lectorBateria.leer() }
            totalEquipo(&f)
        }
        tramo("potencia")

        if completa {
            f.procesos = marcada.values.sorted { $0.pcpu != $1.pcpu ? $0.pcpu > $1.pcpu : $0.pid < $1.pid }
        tramo("ordenar")
            f.gpu = leerGPU()
        tramo("gpu")
            if bateria == nil || vencido("bateria", 2, ahora) { bateria = lectorBateria.leer() }
        tramo("bateria")
            if smc.listo {
                ventiladores = smc.ventiladores()
            }
            f.ventiladores = ventiladores
        tramo("ventiladores")
            f.disco = tasaDisco.leer(contadoresDisco())
        tramo("disco")
            if demanda.puertos && vencido("puertos", 5, ahora) {
                puertos = leerPuertos(marcada.values.filter { $0.propio && $0.estado != "Z" }.map(\.pid))
            }
        tramo("puertos")
            f.puertos = puertos
            if demanda.hilos && !demanda.energia && vencido("hilos", 30, ahora) { hilos = leerTotalHilos() ?? hilos }
            f.totalHilos = hilos
        tramo("hilos")
            // Energia: cada 30 s con su detalle abierto; en el resumen, donde
            // solo asoma el mayor consumidor, cada 2 min.
            // Registro de energia: con la pagina de Bateria a la vista, cada 5 min.
            if demanda.registro && !leyendoRegistro && (tramo == nil || vencido("registro", 300, ahora)) {
                leyendoRegistro = true
                DispatchQueue.global(qos: .utility).async {
                    let t = RegistroEnergia.ultimoTramo()
                    self.cola.async {
                        self.tramo = t
                        self.leyendoRegistro = false
                    }
                }
            }
            f.tramo = tramo
            if demanda.energia && !ahorro && !midiendoEnergia && vencido("energia", demanda.hilos ? 120 : 30, ahora) {
                midiendoEnergia = true
                DispatchQueue.global(qos: .utility).async {
                    let r = leerEnergia()
                    self.cola.async {
                        if let r {
                            self.energia = (Sys.reloj(), r.filas)
                            if let h = r.hilos { self.hilos = h }
                        }
                        self.midiendoEnergia = false
                    }
                }
            }
            if let e = energia {
                f.edadEnergia = ahora - e.ts
                f.energia = e.filas.compactMap { fila in
                    var fila = fila
                    if let p = marcada[fila.pid] {
                        fila.nombre = p.nombre
                        fila.etiqueta = p.etiqueta
                        fila.usuario = p.usuario
                    } else if fila.nombre == "top" {
                        return nil   // el propio top que tomo la medida
                    }
                    return fila
                }
            }
        }
        f.bateria = bateria

        // Historial
        historial.agregar(.cpu, f.cpu.total, t)
        historial.agregar(.cpuE, equipo.hibrido ? f.cpu.promedioE : nil, t)
        historial.agregar(.cpuP, equipo.hibrido ? f.cpu.promedioP : nil, t)
        historial.agregar(.memoria, f.memoria?.pct, t)
        historial.agregar(.temperatura, f.tempMax, t)
        historial.agregar(.alertas, Double(f.activas.count), t)
        if quiere(.red) {
            historial.agregar(.redEntrada, f.red.entrada, t)
            historial.agregar(.redSalida, f.red.salida, t)
        }
        if quiere(.potencia) {
            historial.agregar(.potencia, f.vatios, t)
            historial.agregar(.potenciaCPU, f.potencia?.cpu, t)
            historial.agregar(.potenciaGPU, f.potencia?.gpu, t)
        }
        if completa {
            historial.agregar(.gpu, f.gpu?.uso, t)
            historial.agregar(.ventilador, f.ventiladores.isEmpty ? nil : f.rpmMax, t)
            historial.agregar(.bateria, f.bateria?.pct, t)
            historial.agregar(.discoLectura, f.disco.entrada, t)
            historial.agregar(.discoEscritura, f.disco.salida, t)
            historial.agregar(.procesos, Double(tabla.count), t)
            historial.agregar(.puertos, Double(f.puertos.count), t)
            historial.agregar(.energia, f.energia?.first?.impacto, t)
            historial.agregar(.reposo, Double(f.reposo.count), t)
        }

        f.fuentes = Fuentes(smc: smc.disponible, smcMotivo: smc.motivo, sensores: smc.sensores,
                            ioreport: ioreport.disponible, ioreportMotivo: ioreport.motivo,
                            vigilancia: gestionados != nil)
        f.propio = costo(desde: t0)
        return (f, historial)
    }

    /// «¿Se está usando?»: puertos en escucha y conexiones entrantes de cada
    /// alerta (su familia entera) y de sus copias. Solo se recorren los
    /// sockets de esos procesos, asi que cuesta poco y corre tambien en fondo.
    private func usoDeRed(_ v: inout EstadoVigilancia, _ tabla: [Int32: Proceso]) {
        let indices = v.alertas.indices.filter {
            (v.alertas[$0].regla == .olvidado || v.alertas[$0].regla == .desbocado) && v.alertas[$0].propio
        }
        guard !indices.isEmpty else { return }
        var pids = Set<Int32>()
        for i in indices {
            pids.formUnion(v.alertas[i].familia.isEmpty ? [v.alertas[i].pid] : v.alertas[i].familia)
            pids.formUnion(v.alertas[i].copias)
        }
        let uso = recorrerSockets(pids.filter { tabla[$0]?.propio == true }.sorted()).uso
        // Una conexion es entrante si su puerto local es uno de los de escucha
        // del grupo: las salientes (a una base de datos, a una API) no cuentan.
        func resumen(_ miembros: [Int32]) -> (escucha: [Int], conexiones: Int) {
            let escucha = Set(miembros.flatMap { uso[$0]?.escucha ?? [] })
            let entrantes = miembros.reduce(0) { n, pid in
                n + (uso[pid]?.establecidas.filter { escucha.contains($0) }.count ?? 0)
            }
            // PostgreSQL: cada cliente es un proceso hijo, tambien los que
            // llegan por socket Unix y no aparecen como conexion TCP.
            let clientesPG = miembros.filter { tabla[$0].map { Conocidos.esClientePostgres($0.args) } ?? false }.count
            return (escucha.sorted(), max(entrantes, clientesPG))
        }
        let epoca = Date().timeIntervalSince1970
        var vigentes = Set<String>()
        for i in indices {
            let a = v.alertas[i]
            let r = resumen(a.familia.isEmpty ? [a.pid] : a.familia)
            v.alertas[i].escucha = r.escucha
            v.alertas[i].conexiones = r.conexiones
            // Una base de datos puede estar sin conexiones ahora y usarse cada
            // rato: se recuerda la ultima vez que se vio uso.
            vigentes.insert(a.id)
            if vistoDesde[a.id] == nil { vistoDesde[a.id] = epoca }
            if r.conexiones > 0 || (a.cpuSostenida ?? 0) >= 2 { ultimoUso[a.id] = epoca }
            v.alertas[i].vigiladoDesde = vistoDesde[a.id]
            v.alertas[i].ultimoUso = ultimoUso[a.id]
            v.alertas[i].usoCopias = a.copias.compactMap { c in
                guard let p = tabla[c], p.propio else { return nil }
                let rc = resumen([c])
                return Copia(pid: c, escucha: rc.escucha, conexiones: rc.conexiones, tty: p.tty)
            }
        }
        vistoDesde = vistoDesde.filter { vigentes.contains($0.key) }
        ultimoUso = ultimoUso.filter { vigentes.contains($0.key) }
    }

    /// Consumo de todo el equipo. Con bateria, todo sale de ella; enchufado,
    /// el cargador informa la carga del sistema (sin lo que va a la bateria).
    /// PSTR del SMC se queda corto frente a ambos: solo se usa sin bateria.
    private func totalEquipo(_ f: inout Foto) {
        let pstr = smc.potenciaSistema()
        f.potencia?.smc = pstr
        if let b = bateria, b.estado == .descargando, let w = b.vatios, w > 0.1 {
            f.potencia?.sistema = w
            f.potencia?.fuente = "batería"
        } else if let c = bateria?.cargaSistema {
            f.potencia?.sistema = c
            f.potencia?.fuente = "cargador"
        } else if let pstr {
            f.potencia?.sistema = pstr
            f.potencia?.fuente = "SMC"
        }
    }

    /// Lo que gasta la propia app: CPU (propia y de los procesos auxiliares
    /// como ps o top), memoria y duracion del ciclo.
    private func costo(desde t0: Double) -> CostoPropio {
        var c = CostoPropio()
        let ahora = Sys.reloj()
        c.ciclo = (ahora - t0) * 1000
        func seg(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
        var yo = rusage(), hijos = rusage()
        getrusage(RUSAGE_SELF, &yo)
        getrusage(RUSAGE_CHILDREN, &hijos)
        let propio = seg(yo.ru_utime) + seg(yo.ru_stime)
        let aux = seg(hijos.ru_utime) + seg(hijos.ru_stime)
        if let u = usoPrevio, ahora - u.t > 0.5 {
            c.cpu = 100 * (propio - u.propio) / (ahora - u.t)
            c.auxiliares = 100 * (aux - u.hijos) / (ahora - u.t)
        }
        if usoPrevio == nil || ahora - usoPrevio!.t > 0.5 { usoPrevio = (ahora, propio, aux) }
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        if rc == KERN_SUCCESS { c.memoria = info.phys_footprint }
        return c
    }
}
