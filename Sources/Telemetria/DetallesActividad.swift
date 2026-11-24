import SwiftUI

// Detalle de los modulos de actividad: procesos, energia, puertos, reposo y
// vigilancia. Todo texto que viene de un proceso se muestra tal cual en Text:
// SwiftUI no interpreta marcado, asi que un nombre malicioso no inyecta nada.

extension Proceso {
    var rssOrden: UInt64 { rss ?? 0 }
    var hilosOrden: Int { hilos ?? -1 }
}

// MARK: - Procesos

struct DetalleProcesos: View {
    @ObservedObject var ui: Interfaz

    private var filas: [Proceso] {
        let q = ui.filtro.trimmingCharacters(in: .whitespaces).lowercased()
        let base = ui.procesosTabla.filter { p in
            (!ui.soloPropios || p.propio) && (!ui.soloHuerfanos || p.huerfano)
                && (q.isEmpty || p.nombre.lowercased().contains(q) || p.args.lowercased().contains(q)
                    || String(p.pid) == q || p.usuario.lowercased() == q)
        }
        return base.sorted(using: ui.ordenProcesos)
    }

    var body: some View {
        let f = ui.foto
        let filas = self.filas
        Pagina(modulo: .procesos, desplazable: false, extra: {
            Insignia("\(f.tabla.count) procesos", .info)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Tema.tenue)
                        TextField("Buscar por nombre, comando, pid o usuario", text: $ui.filtro)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                        if !ui.filtro.isEmpty {
                            Button { ui.filtro = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless).foregroundStyle(Tema.tenue)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Tema.panel, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tema.linea, lineWidth: 1))
                    .frame(maxWidth: 380)
                    Toggle("Solo míos", isOn: $ui.soloPropios).toggleStyle(.checkbox).font(.system(size: 11.5))
                    Toggle("Huérfanos", isOn: $ui.soloHuerfanos).toggleStyle(.checkbox).font(.system(size: 11.5))
                    Spacer()
                    Text("\(filas.count) de \(f.tabla.count)").font(Tema.numero(10.5)).foregroundStyle(Tema.tenue)
                }
                TablaDeProcesos(filas: filas, elegidos: ui.procesosElegidos, orden: ui.ordenProcesos, ui: ui)
                    .equatable()
                if ui.procesosElegidos.count == 1, let pid = ui.procesosElegidos.first, let p = f.tabla[pid] {
                    InspectorProceso(proceso: p, ui: ui)
                } else {
                    Text("Doble clic lleva a la ventana de la app de la que depende el proceso; clic derecho, terminarlo, verlo en Finder o copiar su comando. La CPU y la memoria de los procesos de otros usuarios se actualizan cada 5 s: el kernel solo deja leerlas con ps.")
                        .font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
                }
            }
        }
    }
}

/// La tabla, aislada: solo se reconstruye cuando cambian sus filas, la
/// seleccion o el orden, no en cada muestra. `ui` no se observa aqui.
struct TablaDeProcesos: View, Equatable {
    let filas: [Proceso]
    let elegidos: Set<Int32>
    let orden: [KeyPathComparator<Proceso>]
    let ui: Interfaz

    static func == (a: TablaDeProcesos, b: TablaDeProcesos) -> Bool {
        a.elegidos == b.elegidos && a.orden == b.orden && a.filas == b.filas
    }

    var body: some View {
        // Solo se publica si el valor cambia: al montarse, la tabla reasigna
        // orden y seleccion desde su delegado, y publicar ahi es una reentrada.
        Table(filas, selection: Binding(get: { ui.procesosElegidos },
                                        set: { if $0 != ui.procesosElegidos { ui.procesosElegidos = $0 } }),
              sortOrder: Binding(get: { ui.ordenProcesos },
                                 set: { if $0 != ui.ordenProcesos { ui.ordenProcesos = $0 } })) {
            TableColumn("Proceso", value: \.etiqueta) { p in
                HStack(spacing: 6) {
                    Text(p.etiqueta).lineLimit(1)
                    if p.huerfano { Insignia("huérfano", .critico) }
                    if p.estado == "Z" { Insignia("zombi", .aviso) }
                    if p.estado == "T" { Insignia("detenido", .info) }
                }
            }
            .width(min: 180, ideal: 300)
            TableColumn("PID", value: \.pid) { p in Text(String(p.pid)).font(Tema.numero(11)) }
                .width(min: 50, ideal: 60)
            TableColumn("Usuario", value: \.usuario) { p in
                Text(p.usuario).foregroundStyle(p.propio ? Tema.texto : Tema.tenue)
            }
            .width(min: 60, ideal: 90)
            TableColumn("% CPU", value: \.pcpu) { p in
                Text(Formato.decimal(p.pcpu, 1)).font(Tema.numero(11))
                    .foregroundStyle(p.pcpu >= 80 ? Tema.ambar : Tema.texto)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Memoria", value: \.rssOrden) { p in Text(Formato.mb(p.rss)).font(Tema.numero(11)) }
                .width(min: 60, ideal: 80)
            TableColumn("Hilos", value: \.hilosOrden) { p in
                Text(p.hilos.map(String.init) ?? "—").font(Tema.numero(11)).foregroundStyle(Tema.tenue)
            }
            .width(min: 40, ideal: 50)
            TableColumn("Vida", value: \.vida) { p in
                Text(Formato.lapso(p.vida)).font(Tema.numero(11)).foregroundStyle(Tema.tenue)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Terminal", value: \.tty) { p in
                Text(p.conTerminal ? p.tty : "—").font(Tema.numero(11)).foregroundStyle(Tema.tenue)
            }
            .width(min: 50, ideal: 64)
        }
        .contextMenu(forSelectionType: Int32.self) { pids in
            MenuProceso(pids: pids, ui: ui)
        } primaryAction: { pids in
            // Doble clic: a la ventana de la app de la que depende.
            if pids.count == 1, let pid = pids.first { ui.irAVentana(pid) }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .scrollContentBackground(.hidden)
        .background(Tema.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tema.linea, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

struct MenuProceso: View {
    let pids: Set<Int32>
    @ObservedObject var ui: Interfaz

    var body: some View {
        if pids.count == 1, let pid = pids.first {
            let p = ui.foto.tabla[pid]
            if let app = ui.app(de: pid) {
                Button("Ir a la ventana de \(app.localizedName ?? "la app")") { Ventanas.traer(app) }
                Divider()
            }
            Button("Terminar") { ui.terminar(pid) }
            Button("Forzar cierre") { ui.terminar(pid, forzar: true) }
            Divider()
            Button("Mostrar en Finder") { ui.mostrarEnFinder(p?.ruta ?? "") }.disabled(!(p?.ruta.hasPrefix("/") ?? false))
            Button("Copiar «kill \(pid)»") { ui.copiar("kill \(pid)") }
            Button("Copiar comando completo") { ui.copiar(p?.args ?? "") }
            Button("Copiar pid") { ui.copiar(String(pid)) }
        }
    }
}

/// Ficha del proceso elegido: comando completo, cadena de padres, puertos
/// en los que escucha y acciones.
struct InspectorProceso: View {
    let proceso: Proceso
    @ObservedObject var ui: Interfaz

    var body: some View {
        let p = proceso
        let f = ui.foto
        let cadena = padres(p, f.tabla)
        let puertos = f.puertos.filter { $0.pid == p.pid }
        let alertas = f.vigilancia.alertas.filter { $0.pid == p.pid }
        Panel(titulo: p.etiqueta, detalle: "pid \(p.pid) · \(p.usuario)") {
            VStack(alignment: .leading, spacing: 8) {
                Text(p.args.isEmpty ? p.ruta : p.args)
                    .font(Tema.numero(10.5))
                    .foregroundStyle(Tema.texto)
                    .textSelection(.enabled)
                    .lineLimit(3)
                    .padding(7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tema.panel2, in: RoundedRectangle(cornerRadius: 5))
                HStack(spacing: 14) {
                    dato("CPU", Formato.decimal(p.pcpu, 1) + " %")
                    dato("memoria", Formato.mb(p.rss))
                    dato("hilos", p.hilos.map(String.init) ?? "—")
                    dato("vida", Formato.lapso(p.vida))
                    dato("terminal", p.conTerminal ? p.tty : "ninguna")
                    if !puertos.isEmpty { dato("escucha en", puertos.map { ":\($0.puerto)" }.joined(separator: " ")) }
                }
                if !cadena.isEmpty {
                    HStack(spacing: 4) {
                        Text("padres").font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
                        ForEach(Array(cadena.enumerated()), id: \.offset) { i, c in
                            if i > 0 { Image(systemName: "chevron.right").font(.system(size: 7)).foregroundStyle(Tema.tenue2) }
                            Button("\(c.nombre) (\(c.pid))") { ui.procesosElegidos = [c.pid] }
                                .buttonStyle(.link).font(.system(size: 10.5))
                        }
                    }
                }
                ForEach(alertas) { a in
                    HStack(spacing: 6) {
                        Insignia(a.nivel.nombre, Tono(a.nivel))
                        Text(a.titulo).font(.system(size: 11))
                        Button("Ver en Vigilancia") { ui.verAlerta(a) }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                HStack(spacing: 8) {
                    if let app = ui.app(de: p.pid) {
                        Button {
                            Ventanas.traer(app)
                        } label: {
                            Label("Ir a la ventana de \(app.localizedName ?? "la app")", systemImage: "macwindow")
                        }
                        .help("Trae al frente la app de la que depende este proceso. También con doble clic en la tabla.")
                    }
                    Button("Terminar") { ui.terminar(p.pid) }
                    Button("Forzar cierre") { ui.terminar(p.pid, forzar: true) }
                    Button("Mostrar en Finder") { ui.mostrarEnFinder(p.ruta) }.disabled(!p.ruta.hasPrefix("/"))
                    Button("Copiar comando") { ui.copiar(p.args) }
                    Spacer()
                }
                .controlSize(.small)
            }
        }
    }

    private func dato(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(Tema.tenue)
            Text(v).foregroundStyle(Tema.texto).fontWeight(.medium)
        }
        .font(.system(size: 10.5))
    }

    private func padres(_ p: Proceso, _ tabla: [Int32: Proceso]) -> [Proceso] {
        var r: [Proceso] = []
        var actual = p.ppid
        while actual > 0, let q = tabla[actual], r.count < 12 {
            r.append(q)
            actual = q.ppid
        }
        return r.reversed()
    }
}

// MARK: - Energia

struct DetalleEnergia: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let filas = f.energia ?? []
        let tope = max(1, filas.map(\.impacto).max() ?? 1)
        Pagina(modulo: .energia, extra: {
            Insignia(f.edadEnergia.map { "hace \(Int($0)) s" } ?? "midiendo", .neutro)
        }) {
            VStack(spacing: 12) {
                Panel(titulo: "Mayores consumidores",
                      ayuda: "La misma cifra que la columna Energía del Monitor de Actividad: combina CPU, GPU, despertares y red en una escala relativa. Se mide cada 30 s y solo con esta página a la vista, porque medirlo también gasta.") {
                    if filas.isEmpty {
                        Vacio(texto: "Midiendo: la primera lectura tarda unos segundos.", icono: "hourglass")
                    }
                    VStack(spacing: 0) {
                        ForEach(filas) { e in
                            Button { ui.irAProceso(e.pid) } label: {
                                HStack(spacing: 8) {
                                    Text(e.etiqueta).font(.system(size: 11.5)).foregroundStyle(Tema.texto).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(e.usuario ?? "").font(.system(size: 10)).foregroundStyle(Tema.tenue2)
                                    Text(Formato.decimal(e.impacto, 1)).font(Tema.numero(11.5, .medium))
                                        .foregroundStyle(Tema.ambar).frame(width: 60, alignment: .trailing)
                                }
                                .padding(.vertical, 5)
                                .background(alignment: .bottomLeading) {
                                    GeometryReader { g in
                                        Rectangle().fill(Tema.ambar.opacity(0.5)).frame(width: g.size.width * e.impacto / tope, height: 1.5)
                                            .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("\(e.etiqueta) · pid \(e.pid)\nImpacto energético \(Formato.decimal(e.impacto, 1))")
                        }
                    }
                }
                PanelHistorial(titulo: "Mayor impacto",
                               trazos: [Trazo(muestras: ui.historial[.energia], color: Tema.ambar, relleno: true, nombre: "primero")],
                               escala: .auto(minimo: 10), ahora: ui.ahora, formato: { Formato.decimal($0, 1) })
            }
        }
    }
}

// MARK: - Puertos

/// Que es cada servicio conocido. Solo programas genericos de macOS y de uso
/// comun: nada propio de un equipo concreto.
private let queEsNombre: [(String, String)] = [
    ("^controlcent", "Receptor AirPlay: deja que otros dispositivos proyecten en este Mac. Se apaga en Ajustes › General › AirDrop y Handoff."),
    ("^rapportd$", "Continuidad de Apple: Handoff, portapapeles universal y descubrimiento de tus otros dispositivos."),
    ("^sharingd$", "AirDrop y funciones de Compartir."),
    ("^cloudflar", "Cloudflare WARP: resolvedor DNS local del túnel."),
    ("^redis-ser", "Redis: base de datos en memoria."),
    ("^postgres", "PostgreSQL: base de datos."),
    ("^mysqld", "MySQL: base de datos."),
    ("^mongod", "MongoDB: base de datos."),
    ("^onedrive", "OneDrive: servicio local de autenticación e integración con Office."),
    ("^dropbox", "Dropbox: sincronización y red local."),
    ("^code helper|^electron", "VS Code: servidor local que abrió alguna extensión o el propio editor."),
    ("^claude$", "Claude Code: enlace con el editor."),
    ("^ollama", "Ollama: servidor de modelos de IA locales."),
    ("^spotify", "Spotify: Connect y descubrimiento de dispositivos en la red."),
    ("^figma_agent", "Agente de Figma: fuentes locales para Figma en el navegador."),
    ("^python|^node|^ruby|^php|^deno|^bun|^java", "Programa de desarrollo: probablemente el servidor local de un proyecto."),
]
private let queEsPuerto: [Int: String] = [
    22: "Inicio de sesión remoto (SSH).", 88: "Kerberos, para compartir entre Macs.", 445: "Compartir archivos (SMB).",
    548: "Compartir archivos (AFP).", 631: "Impresión (CUPS).", 3283: "Escritorio remoto de Apple.", 5900: "Compartir pantalla (VNC).",
]

func queEs(_ nombre: String, _ puerto: Int) -> String {
    if nombre.lowercased() == "launchd", let q = queEsPuerto[puerto] { return q }
    for (re, texto) in queEsNombre where nombre.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil {
        return texto
    }
    return queEsPuerto[puerto] ?? ""
}

struct FilaPuerto: Identifiable {
    let puerto: Puerto
    let nombre: String
    let usuario: String
    let vida: Double
    let huerfano: Bool
    let que: String
    var id: String { puerto.id }
    var numero: Int { puerto.puerto }
    var expuestoOrden: Int { puerto.expuesto ? 0 : 1 }
}

struct DetallePuertos: View {
    @ObservedObject var ui: Interfaz
    private let orden = State(initialValue: [KeyPathComparator(\FilaPuerto.expuestoOrden), KeyPathComparator(\FilaPuerto.numero)])
    private let elegidos = State(initialValue: Set<String>())

    var body: some View {
        let f = ui.foto
        let filas = f.puertos.map { p -> FilaPuerto in
            let proc = f.tabla[p.pid]
            let nombre = proc?.etiqueta ?? p.proceso
            return FilaPuerto(puerto: p, nombre: nombre, usuario: proc?.usuario ?? "", vida: proc?.vida ?? 0,
                              huerfano: proc?.huerfano ?? false, que: queEs(proc?.nombre ?? p.proceso, p.puerto))
        }.sorted(using: orden.wrappedValue)
        let expuestos = f.puertos.filter(\.expuesto).count
        Pagina(modulo: .puertos, desplazable: false, extra: {
            Insignia("\(f.puertos.count) · \(expuestos) expuestos", expuestos > 0 ? .aviso : .ok)
        }) {
            VStack(alignment: .leading, spacing: 10) {
                Table(filas, selection: elegidos.projectedValue, sortOrder: orden.projectedValue) {
                    TableColumn("Puerto", value: \.numero) { r in
                        Text(String(r.numero)).font(Tema.numero(12, .semibold))
                            .foregroundStyle(r.puerto.expuesto ? Tema.ambar : Tema.cian)
                    }
                    .width(min: 50, ideal: 64)
                    TableColumn("Servicio", value: \.nombre) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(r.nombre).lineLimit(1)
                                if r.huerfano { Insignia("huérfano", .critico) }
                            }
                            if !r.que.isEmpty { Text(r.que).font(.system(size: 10)).foregroundStyle(Tema.tenue).lineLimit(1) }
                        }
                        .help(r.que)
                    }
                    .width(min: 200, ideal: 360)
                    TableColumn("Ligado a", value: \.puerto.host) { r in
                        Text("\(r.puerto.host) · \(r.puerto.protocolos)").font(Tema.numero(10.5)).foregroundStyle(Tema.tenue)
                    }
                    .width(min: 110, ideal: 150)
                    TableColumn("PID", value: \.puerto.pid) { r in Text(String(r.puerto.pid)).font(Tema.numero(11)) }
                        .width(min: 50, ideal: 60)
                    TableColumn("Abierto", value: \.vida) { r in
                        Text(Formato.lapso(r.vida)).font(Tema.numero(11)).foregroundStyle(Tema.tenue)
                    }
                    .width(min: 50, ideal: 64)
                    TableColumn("Alcance", value: \.expuestoOrden) { r in
                        if r.puerto.expuesto {
                            Insignia("expuesto", .aviso)
                        } else {
                            Insignia("local", .ok, icono: "lock.fill")
                        }
                    }
                    .width(min: 70, ideal: 84)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first, let r = filas.first(where: { $0.id == id }) {
                        Button("Abrir http://localhost:\(r.numero)") { ui.abrirEnNavegador(r.numero) }
                        if let app = ui.app(de: r.puerto.pid) {
                            Button("Ir a la ventana de \(app.localizedName ?? "la app")") { Ventanas.traer(app) }
                        }
                        Button("Ver el proceso") { ui.irAProceso(r.puerto.pid) }
                        Divider()
                        Button("Terminar el proceso") { ui.terminar(r.puerto.pid) }
                        Button("Copiar «localhost:\(r.numero)»") { ui.copiar("localhost:\(r.numero)") }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let r = filas.first(where: { $0.id == id }) { ui.irAProceso(r.puerto.pid) }
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .scrollContentBackground(.hidden)
                .background(Tema.panel, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tema.linea, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("Local: ligado a 127.0.0.1 o ::1, solo accesible desde este Mac. Expuesto: alcanzable desde otros equipos de tu red. Solo se ven tus procesos: macOS no deja leer los sockets de otros usuarios sin privilegios. Doble clic abre el proceso; clic derecho, más acciones.")
                    .font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
            }
        }
    }
}

// MARK: - Reposo

private let tipoReposo: [String: String] = [
    "PreventUserIdleSystemSleep": "impide dormir por inactividad", "PreventSystemSleep": "impide dormir",
    "PreventUserIdleDisplaySleep": "mantiene la pantalla encendida", "NoIdleSleepAssertion": "impide dormir por inactividad",
    "NoDisplaySleepAssertion": "mantiene la pantalla encendida", "BackgroundTask": "tarea en segundo plano",
    "ApplePushServiceTask": "notificaciones push", "ExternalMedia": "disco externo conectado",
    "NetworkClientActive": "red activa", "InternalPreventSleep": "impide dormir",
    "InternalPreventDisplaySleep": "mantiene la pantalla encendida",
]

struct DetalleReposo: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let alerta = f.enBateria == true && (f.reposo.first?.duracion ?? 0) >= Reglas.minReposo
        Pagina(modulo: .reposo, extra: {
            Insignia(f.enBateria == true ? "con batería" : "enchufado", alerta ? .aviso : .ok)
        }) {
            VStack(spacing: 12) {
                Panel(titulo: "Impiden dormir",
                      ayuda: "Programas que le piden a macOS que no duerma o que no apague la pantalla. Se omite la petición fija que existe mientras la pantalla está encendida. Con batería, más de 30 min genera una alerta.") {
                    if f.reposo.isEmpty { Vacio(texto: "Nada impide que el equipo duerma.") }
                    VStack(spacing: 0) {
                        ForEach(f.reposo) { r in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.paraNombre ?? r.proceso).font(.system(size: 12)).foregroundStyle(Tema.texto)
                                    Text(tipoReposo[r.tipo] ?? r.tipo).font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
                                }
                                Spacer()
                                Text(r.proceso).font(.system(size: 10.5)).foregroundStyle(Tema.tenue2)
                                Text(Formato.lapso(r.duracion)).font(Tema.numero(11.5, .medium))
                                    .foregroundStyle(r.duracion >= Reglas.minReposo ? Tema.ambar : Tema.texto)
                                    .frame(width: 70, alignment: .trailing)
                            }
                            .padding(.vertical, 6)
                            .overlay(alignment: .bottom) { Rectangle().fill(Tema.linea.opacity(0.6)).frame(height: 1) }
                            .help("\(r.paraNombre ?? r.proceso)\n\(tipoReposo[r.tipo] ?? r.tipo) desde hace \(Formato.lapso(r.duracion))\nLo registra \(r.proceso) (pid \(r.pid))\(r.paraPid.map { " en nombre del pid \($0)" } ?? "")\n\n\(r.motivo)\(r.detalle.isEmpty ? "" : "\n" + r.detalle)")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Vigilancia

struct DetalleVigilancia: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let c = f.vigilancia.cuentas
        Pagina(modulo: .vigilancia, extra: {
            Insignia(f.activas.isEmpty ? "en orden" : "\(f.activas.count) activas", Tono(f.peorNivel))
        }) {
            VStack(spacing: 12) {
                Rejilla(minimo: 150) {
                    contador("procesos", c.procesos, Tema.texto)
                    contador("sin terminal", c.sinTerminal, Tema.texto)
                    contador("huérfanos", c.huerfanos, c.huerfanos > 0 ? Tema.ambar : Tema.verde)
                    contador("zombis", c.zombis, c.zombis > 0 ? Tema.ambar : Tema.verde)
                    contador("detenidos", c.detenidos, c.detenidos > 0 ? Tema.cian : Tema.verde)
                }
                if f.activas.isEmpty {
                    Panel {
                        Vacio(texto: "Sin alertas. Se revisan \(c.procesos) procesos cada 5 s, también con la ventana cerrada.",
                              icono: "checkmark.shield")
                    }
                }
                ForEach(f.activas) { a in TarjetaAlertaCompleta(alerta: a, ui: ui) }
                if !f.silenciadas.isEmpty {
                    Panel(titulo: "Silenciadas", detalle: "\(f.silenciadas.count)") {
                        VStack(spacing: 0) {
                            ForEach(f.silenciadas) { a in
                                HStack {
                                    Text("\(a.titulo) · \(a.etiqueta) · pid \(a.pid)").font(.system(size: 11.5)).foregroundStyle(Tema.tenue)
                                    Spacer()
                                    Button("Reactivar") { ui.reactivar(a) }.controlSize(.small)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                Panel(titulo: "Reglas") {
                    VStack(alignment: .leading, spacing: 6) {
                        regla("Olvidado", "proceso tuyo sin ventana de terminal (ni él ni sus padres) que no depende de ninguna app ni de launchd. Es crítico si mantiene \(Int(Reglas.umbralOlvidado)) % de CPU durante \(Formato.lapso(Reglas.ventanaOlvidado)).")
                        regla("Desbocado", "\(Int(Reglas.umbralDesbocado)) % de un núcleo durante \(Formato.lapso(Reglas.ventanaDesbocado)).")
                        regla("Zombi", "terminó, pero su padre no lo recogió.")
                        regla("Suspendido", "detenido (Ctrl+Z) más de \(Formato.lapso(Reglas.minDetenido)).")
                        regla("Reposo", "impide dormir más de \(Formato.lapso(Reglas.minReposo)) con batería.")
                        Text("Se revisa cada 5 s, también con la ventana cerrada. Lo crítico llega además como notificación del sistema\(Preferencias.notificaciones ? "" : " (ahora desactivadas)"). tmux, screen, ssh-agent y similares nunca cuentan como olvidados.")
                            .font(.system(size: 10.5)).foregroundStyle(Tema.tenue).padding(.top, 4)
                    }
                }
            }
        }
    }

    private func contador(_ k: String, _ v: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Rotulo(k)
            Text("\(v)").font(Tema.numero(22, .light)).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.panel, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tema.linea, lineWidth: 1))
    }

    private func regla(_ n: String, _ t: String) -> some View {
        (Text(n + ": ").fontWeight(.semibold).foregroundStyle(Tema.texto) + Text(t).foregroundStyle(Tema.tenue))
            .font(.system(size: 11.5))
    }
}

struct TarjetaAlertaCompleta: View {
    let alerta: Alerta
    @ObservedObject var ui: Interfaz

    var body: some View {
        let a = alerta
        let (v, u) = valorAlerta(a)
        let puertos = ui.foto.puertos.filter { $0.pid == a.pid }
        let resaltada = ui.alertaResaltada == a.id
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Insignia(a.nivel.nombre, Tono(a.nivel))
                Text(a.titulo).font(.system(size: 13, weight: .semibold)).foregroundStyle(Tema.texto)
                Spacer()
                Text(v + u).font(Tema.numero(18, .medium)).foregroundStyle(Tema.color(a.nivel))
            }
            Text(a.etiqueta).font(.system(size: 12, weight: .medium)).foregroundStyle(Tema.cian)
            Text(a.motivo).font(.system(size: 11.5)).foregroundStyle(Tema.tenue).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                dato("pid", "\(a.pid)")
                dato("vida", Formato.lapso(a.vida))
                if let c = a.cpuSostenida, let w = a.ventana { dato("CPU en \(Formato.lapso(w))", Formato.pct(c)) }
                dato("CPU ahora", Formato.decimal(a.pcpu, 1) + " %")
                dato("memoria", Formato.mb(a.rss))
                dato("terminal", a.tty == "??" ? "ninguna" : a.tty)
                if let padre = a.padre { dato("padre", "\(padre) (\(a.ppid))") }
                if !puertos.isEmpty { dato("escucha en", puertos.map { ":\($0.puerto)" }.joined(separator: " ")) }
            }
            if !a.zombis.isEmpty {
                dato("zombis", a.zombis.map(String.init).joined(separator: " "))
            }
            if !a.args.isEmpty {
                Text(a.args).font(Tema.numero(10.5)).foregroundStyle(Tema.texto).textSelection(.enabled).lineLimit(3)
                    .padding(7).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Tema.panel2, in: RoundedRectangle(cornerRadius: 5))
            }
            HStack(spacing: 8) {
                if a.regla != .zombi {
                    Button("Terminar") { ui.terminar(a.pid) }
                }
                Button("Copiar «\(a.comando)»") { ui.copiar(a.comando) }
                Button("Ver proceso") { ui.irAProceso(a.pid) }
                if let app = ui.app(de: a.pid) {
                    Button("Ir a \(app.localizedName ?? "la app")") { Ventanas.traer(app) }
                }
                Button("Silenciar") { ui.silenciar(a) }
                    .help("Deja de mostrar este programa, aunque se relance con otro pid. Tampoco volverá a notificar.")
                Spacer()
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(resaltada ? Tema.panel2 : Tema.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(resaltada ? Tema.color(a.nivel) : Tema.linea, lineWidth: 1))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Tema.color(a.nivel)).frame(width: 3).padding(.vertical, 12)
        }
    }

    private func dato(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(Tema.tenue)
            Text(v).foregroundStyle(Tema.texto).fontWeight(.medium)
        }
        .font(.system(size: 10.5))
    }
}
