import SwiftUI

// Detalle de los modulos de hardware.

private let ventanaHistorial = 300.0

private let tipE = """
Núcleo de eficiencia (E-core)
Diseñado para gastar poca energía, no para ir rápido. macOS le asigna el trabajo de baja prioridad: \
sincronizaciones, indexado de Spotlight, copias, procesos en segundo plano.

Consume una fracción de lo que gasta un núcleo P haciendo lo mismo. Por eso puedes verlos saturados \
mientras el equipo sigue fluido.
"""
private let tipP = """
Núcleo de rendimiento (P-core)
El músculo del chip. macOS lo reserva para lo que estás haciendo ahora: compilar, renderizar, la app en \
primer plano.

Se mantienen apagados hasta que hace falta potencia real, y ahí es donde sube el consumo y aparecen los \
ventiladores.
"""

/// Historial grande con lectura al pasar el cursor.
struct PanelHistorial: View {
    let titulo: String
    let trazos: [Trazo]
    var escala: Escala = .fija(100)
    let ahora: Double
    var formato: (Double) -> String = { "\(Int($0.rounded()))%" }
    var alto: CGFloat = 130

    var body: some View {
        Panel(titulo: titulo, detalle: "5 min · pasa el cursor para leer") {
            VStack(alignment: .leading, spacing: 6) {
                Grafico(trazos: trazos, ventana: ventanaHistorial, escala: escala, ahora: ahora,
                        formato: formato, interactivo: true, reticula: true)
                    .frame(height: alto)
                if trazos.count > 1 || !(trazos.first?.nombre.isEmpty ?? true) {
                    HStack(spacing: 12) {
                        ForEach(Array(trazos.enumerated()), id: \.offset) { _, t in
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 1).fill(t.color).frame(width: 10, height: 2)
                                Text(t.nombre).font(.system(size: 10)).foregroundStyle(Tema.tenue)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Los procesos que mas gastan de algo, con acceso directo a su ficha.
struct ListaProcesos: View {
    let procesos: [Proceso]
    let porMemoria: Bool
    @ObservedObject var ui: Interfaz

    var body: some View {
        let tope = max(1, procesos.map { porMemoria ? Double($0.rss ?? 0) : $0.pcpu }.max() ?? 1)
        VStack(spacing: 0) {
            ForEach(procesos) { p in
                let v = porMemoria ? Double(p.rss ?? 0) : p.pcpu
                Button { ui.irAProceso(p.pid) } label: {
                    HStack(spacing: 8) {
                        Text(p.etiqueta).font(.system(size: 11.5)).foregroundStyle(Tema.texto).lineLimit(1)
                        if p.huerfano { Insignia("huérfano", .critico) }
                        Spacer(minLength: 6)
                        Text(p.usuario).font(.system(size: 10)).foregroundStyle(Tema.tenue2).lineLimit(1)
                        Text(Formato.lapso(p.vida)).font(Tema.numero(10)).foregroundStyle(Tema.tenue2)
                            .frame(width: 52, alignment: .trailing)
                        Text(porMemoria ? Formato.mb(p.rss) : Formato.decimal(p.pcpu, 1) + "%")
                            .font(Tema.numero(11, .medium)).foregroundStyle(Tema.texto)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .padding(.vertical, 5)
                    .background(alignment: .bottomLeading) {
                        GeometryReader { g in
                            Rectangle().fill((porMemoria ? Tema.violeta : Tema.cian).opacity(0.5))
                                .frame(width: g.size.width * v / tope, height: 1.5)
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(p.etiqueta) · pid \(p.pid) · \(p.usuario)\n\(p.args)\n\nClic para ver su ficha en Procesos.")
            }
        }
    }
}

// MARK: - CPU

struct DetalleCPU: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let eq = ui.equipo
        let c = f.cpu
        Pagina(modulo: .cpu, extra: {
            Insignia("\(eq.nucleos) núcleos", .info)
        }) {
            VStack(spacing: 12) {
                Panel(titulo: "Núcleos", detalle: "carga % · frecuencia media activa") {
                    VStack(alignment: .leading, spacing: 12) {
                        if eq.hibrido {
                            cluster("Eficiencia", Tema.verde, Array(0..<eq.nucleosE), c.promedioE, f.potencia?.frecE, tipE)
                            cluster("Rendimiento", Tema.cian, Array(eq.nucleosE..<eq.nucleos), c.promedioP,
                                    f.potencia?.frecP, tipP)
                        } else {
                            cluster("Núcleos", Tema.cian, Array(0..<eq.nucleos), c.total, nil,
                                    "Este equipo no tiene clusters separados de eficiencia y rendimiento.")
                        }
                    }
                }
                Rejilla {
                    Panel(titulo: "Carga") {
                        HStack(spacing: 16) {
                            ZStack {
                                Anillo(valor: c.total, color: Tema.nivel(c.total), grosor: 8)
                                Cifra(valor: "\(Int(c.total.rounded()))", unidad: "%", tam: 24)
                            }
                            .frame(width: 96, height: 96)
                            .help("Promedio de los \(eq.nucleos) núcleos.\(eq.hibrido ? " Puede parecer baja aunque los de eficiencia estén saturados: \(eq.nucleosE) de \(eq.nucleos) al 100 % son solo un \(Int(Double(eq.nucleosE) / Double(eq.nucleos) * 100)) % del total." : "")")
                            VStack(spacing: 0) {
                                if eq.hibrido {
                                    FilaDato("Eficiencia", Formato.pct(c.promedioE), color: Tema.verde)
                                    FilaDato("Rendimiento", Formato.pct(c.promedioP), color: Tema.cian)
                                }
                                FilaDato("Carga 1 · 5 · 15 min", c.carga.map { Formato.decimal($0, 2) }.joined(separator: " "),
                                         ayuda: "Load average: procesos esperando ejecución, no porcentaje. Un valor sostenido por encima de \(eq.nucleos) significaría más trabajo del que el chip puede atender.")
                                FilaDato("Procesos", "\(f.tabla.count)")
                                FilaDato("Hilos", f.totalHilos.map(String.init) ?? "—",
                                         ayuda: "Unidades de ejecución dentro de los procesos. Son los hilos, no los procesos, los que se reparten entre los \(eq.nucleos) núcleos.")
                            }
                        }
                    }
                    Panel(titulo: "Frecuencia y potencia", ayuda: "Leído de IOReport, sin sudo: tiempo de cada cluster en cada estado de frecuencia.") {
                        VStack(spacing: 0) {
                            ForEach(Array((f.potencia?.clusters ?? []).enumerated()), id: \.offset) { _, cl in
                                FilaDato(nombreCluster(cl.nombre), "\(Formato.mhz(cl.mhz)) · \(Formato.pct(cl.activa)) activo",
                                         color: cl.nombre.hasPrefix("E") ? Tema.verde : Tema.cian)
                            }
                            FilaDato("Potencia de CPU", Formato.vatios(f.potencia?.cpu, 2), color: Tema.ambar,
                                     ayuda: "Vatios que consumen los \(eq.nucleos) núcleos ahora mismo. En reposo suele estar bajo 1 W; bajo carga puede multiplicarse por treinta.")
                            FilaDato("Presión térmica", PresionTermica.nombre(f.potencia?.termico))
                        }
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.cpu], color: Tema.cian, relleno: true, nombre: "total")]
                                   + (eq.hibrido ? [Trazo(muestras: ui.historial[.cpuE], color: Tema.verde, nombre: "eficiencia"),
                                                    Trazo(muestras: ui.historial[.cpuP], color: Tema.violeta, nombre: "rendimiento")] : []),
                               ahora: ui.ahora)
                Panel(titulo: "Procesos con más CPU", detalle: "% de un núcleo") {
                    ListaProcesos(procesos: Array(f.procesos.prefix(8)), porMemoria: false, ui: ui)
                }
            }
        }
    }

    private func nombreCluster(_ n: String) -> String {
        if n.hasPrefix("E") { return "Cluster de eficiencia" }
        let num = n.dropFirst(4)
        return "Cluster de rendimiento" + (num.isEmpty ? "" : " \(num)")
    }

    private func cluster(_ titulo: String, _ color: Color, _ ids: [Int], _ promedio: Double,
                         _ mhz: Double?, _ ayuda: String) -> some View {
        let f = ui.foto
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("\(titulo.uppercased()) · \(ids.count) NÚCLEOS").font(.system(size: 10, weight: .semibold))
                    .tracking(1).foregroundStyle(color)
                Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(Tema.tenue2)
                Spacer()
                Text("prom \(Formato.pct(promedio)) · \(Formato.mhz(mhz))").font(Tema.numero(10)).foregroundStyle(Tema.tenue)
            }
            .help(ayuda)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columnas(ids.count)), spacing: 5) {
                ForEach(ids, id: \.self) { i in
                    let uso = i < f.cpu.nucleos.count ? f.cpu.nucleos[i] : 0
                    let mhz = i < (f.potencia?.nucleosMHz.count ?? 0) ? f.potencia?.nucleosMHz[i] : nil
                    Celda(rotulo: String(format: "%02d", i), valor: uso, pie: mhz.map { Formato.mhz($0) },
                          ayuda: "Núcleo \(i) · \(ui.equipo.esEficiencia(i) ? "eficiencia" : "rendimiento") · carga \(Int(uso.rounded())) %\(mhz.map { " · " + Formato.mhz($0) } ?? "")")
                }
            }
        }
    }
}

// MARK: - GPU

struct DetalleGPU: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let g = f.gpu
        let p = f.potencia
        Pagina(modulo: .gpu, extra: {
            if let n = ui.equipo.gpuNucleos { Insignia("\(n) núcleos", .info) }
        }) {
            VStack(spacing: 12) {
                Rejilla {
                    Panel(titulo: "Uso") {
                        HStack(spacing: 16) {
                            ZStack {
                                Anillo(valor: g?.uso ?? 0, color: Tema.violeta, grosor: 8)
                                Cifra(valor: g?.uso.map { "\(Int($0.rounded()))" } ?? "—", unidad: "%", tam: 24)
                            }
                            .frame(width: 96, height: 96)
                            VStack(spacing: 0) {
                                FilaDato("Renderizador", Formato.pct(g?.render),
                                         ayuda: "La etapa que dibuja los píxeles: sombreado, texturas, efectos.")
                                FilaDato("Teselador", Formato.pct(g?.tiler),
                                         ayuda: "Apple Silicon renderiza por tiles: ahorra ancho de banda de memoria, clave cuando CPU y GPU comparten RAM.")
                                FilaDato("Memoria en uso", Formato.mb(g?.memoriaEnUso.map { UInt64($0) }))
                                FilaDato("Memoria reservada", Formato.mb(g?.memoriaReservada.map { UInt64($0) }))
                            }
                        }
                    }
                    Panel(titulo: "Frecuencia y potencia", ayuda: "Leído de IOReport, sin sudo.") {
                        VStack(spacing: 0) {
                            FilaDato("Frecuencia media activa", Formato.mhz(p?.gpuMHz), color: Tema.violeta)
                            FilaDato("Tiempo activa", Formato.pct(p?.gpuActiva),
                                     ayuda: "Porcentaje del último segundo que la GPU estuvo ejecutando trabajo.")
                            FilaDato("Potencia de GPU", Formato.vatios(p?.gpu, 2), color: Tema.ambar,
                                     ayuda: "Sube con vídeo, juegos o cualquier cosa acelerada.")
                            FilaDato("Núcleos", ui.equipo.gpuNucleos.map(String.init) ?? "—",
                                     ayuda: "macOS no publica la carga de cada núcleo de la GPU: el firmware reparte el trabajo entre ellos por su cuenta. Lo más cercano es el tiempo por frecuencia.")
                        }
                    }
                }
                if let estados = p?.gpuEstados, !estados.isEmpty {
                    Panel(titulo: "Tiempo por frecuencia", detalle: "% del último segundo",
                          ayuda: "Porcentaje del último segundo que la GPU pasó en cada estado de frecuencia. El resto estuvo en reposo.") {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: columnas(estados.count)), spacing: 5) {
                            ForEach(Array(estados.enumerated()), id: \.offset) { _, e in
                                Celda(rotulo: "\(Int(e.mhz))", valor: e.pct, pie: "MHz", semaforo: false,
                                      ayuda: "\(Int(e.mhz)) MHz · \(Formato.decimal(e.pct, 1)) % del último segundo")
                            }
                        }
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.gpu], color: Tema.violeta, relleno: true, nombre: "uso")],
                               ahora: ui.ahora)
            }
        }
    }
}

// MARK: - Memoria

struct DetalleMemoria: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        Pagina(modulo: .memoria, extra: {
            if let m = f.memoria { Insignia(presion(m.presion).0, presion(m.presion).1) }
        }) {
            VStack(spacing: 12) {
                if let m = f.memoria {
                    Panel(titulo: "Reparto") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(alignment: .firstTextBaseline) {
                                Cifra(valor: Formato.gb(m.usada), unidad: "/ \(Formato.gb(m.total)) GB", tam: 28)
                                Spacer()
                                Text(Formato.pct(m.pct) + " usada").font(Tema.numero(12)).foregroundStyle(Tema.tenue)
                            }
                            BarraApilada(segmentos: [(Double(m.apps), Tema.cian), (Double(m.ancladas), Tema.violeta),
                                                     (Double(m.comprimidas), Tema.ambar), (Double(m.cache), Tema.tenue2)],
                                         total: Double(m.total), alto: 12)
                            HStack(spacing: 14) {
                                Leyenda(color: Tema.cian, nombre: "Apps", valor: Formato.gb(m.apps),
                                        ayuda: "Lo que piden tus programas para funcionar. Es la porción que puedes liberar cerrando cosas.")
                                Leyenda(color: Tema.violeta, nombre: "Anclada", valor: Formato.gb(m.ancladas),
                                        ayuda: "Reservada por el núcleo de macOS y los drivers. No se puede liberar.")
                                Leyenda(color: Tema.ambar, nombre: "Comprimida", valor: Formato.gb(m.comprimidas),
                                        ayuda: "macOS comprime páginas inactivas en vez de escribirlas a disco.")
                                Leyenda(color: Tema.tenue2, nombre: "Caché", valor: Formato.gb(m.cache),
                                        ayuda: "Archivos en caché. No es memoria ocupada: el sistema la cede al instante.")
                            }
                        }
                    }
                    Rejilla {
                        Panel(titulo: "Estado") {
                            VStack(spacing: 0) {
                                FilaDato("Presión", presion(m.presion).0, color: presion(m.presion).1.color,
                                         ayuda: "El nivel que calcula el propio kernel. Es la medida que de verdad importa, no el porcentaje usado.")
                                FilaDato("Swap", m.swapTotal > 0 ? "\(Formato.gb(m.swapUsado)) / \(Formato.gb(m.swapTotal)) GB" : "sin usar",
                                         ayuda: "Espacio en el SSD que macOS usa cuando la RAM se agota. 'Sin usar' es la mejor señal posible.")
                                FilaDato("Libre", Formato.gb(m.libre) + " GB",
                                         ayuda: "RAM sin asignar. Suele ser baja y eso no es malo: macOS usa la sobrante como caché.")
                                FilaDato("Total instalada", Formato.gb(m.total) + " GB")
                            }
                        }
                        Panel(titulo: "Procesos con más memoria", detalle: "memoria residente") {
                            ListaProcesos(procesos: Array(f.procesos.sorted { ($0.rss ?? 0) > ($1.rss ?? 0) }.prefix(6)),
                                          porMemoria: true, ui: ui)
                        }
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.memoria], color: Tema.violeta, relleno: true, nombre: "memoria"),
                                        Trazo(muestras: ui.historial[.cpu], color: Tema.cian, nombre: "cpu")],
                               ahora: ui.ahora)
            }
        }
    }

    private func presion(_ n: Int) -> (String, Tono) {
        n >= 4 ? ("presión crítica", .critico) : n >= 2 ? ("presión alta", .aviso) : ("presión normal", .ok)
    }
}

// MARK: - Termico

private let tipsTemp: [String: String] = [
    "CPU rendimiento": "Termistores de los núcleos P. Cuando el cluster está apagado no reportan: verás «reposo», no un cero falso.",
    "CPU eficiencia": "El cluster que absorbe el trabajo de fondo. Suele estar más caliente que el de rendimiento justamente porque casi siempre tiene algo entre manos.",
    "GPU": "Los núcleos gráficos comparten dado y memoria con la CPU. Sube al mover ventanas, reproducir vídeo o cualquier cosa acelerada.",
    "Reguladores": "Reguladores de voltaje (VRM). Casi siempre son lo más caliente del equipo, y es normal: disipan la pérdida de la conversión. No indican que el procesador esté sufriendo.",
    "Chasis": "Termistores repartidos por la carcasa. Es la temperatura que sientes al apoyar las manos.",
    "Batería": "Apple limita la carga si se calienta demasiado. Por encima de 35 °C conviene vigilarla: el calor es lo que más degrada su vida útil.",
    "SSD": "Controlador del almacenamiento. Sube al escribir mucho de forma sostenida.",
    "Entrada de aire": "Aire de admisión: aproxima la temperatura de la sala. Es la referencia contra la que se mide todo lo demás.",
]

struct DetalleTermico: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        Pagina(modulo: .termico, extra: {
            if let t = f.tempMax {
                Insignia("máx \(Int(t.rounded()))°", t < 55 ? .ok : t < 75 ? .aviso : .critico)
            }
        }) {
            VStack(spacing: 12) {
                Panel(titulo: "Familias de sensores", detalle: "\(f.fuentes.sensores) termistores leídos del SMC") {
                    if f.temperaturas.isEmpty {
                        Vacio(texto: f.fuentes.smc ? "Descubriendo sensores…" : "SMC no disponible: \(f.fuentes.smcMotivo)",
                              icono: "thermometer.medium.slash")
                    }
                    VStack(spacing: 8) {
                        ForEach(f.temperaturas, id: \.id) { t in
                            HStack(spacing: 10) {
                                Text(t.nombre).font(.system(size: 11.5)).foregroundStyle(Tema.texto)
                                    .frame(width: 130, alignment: .leading)
                                if let mx = t.max {
                                    // Escala 20-100 °C: por debajo de 20 no baja nunca.
                                    BarraNivel(fraccion: max(0.02, (mx - 20) / 80), color: Tema.temperatura(mx))
                                    Text(Formato.decimal(mx, 1) + "°").font(Tema.numero(12, .medium))
                                        .foregroundStyle(Tema.temperatura(mx)).frame(width: 54, alignment: .trailing)
                                    Text("prom \(Formato.decimal(t.promedio ?? 0, 0))°").font(Tema.numero(9.5))
                                        .foregroundStyle(Tema.tenue).frame(width: 58, alignment: .trailing)
                                } else {
                                    BarraNivel(fraccion: 0, color: Tema.tenue2)
                                    Text("reposo").font(Tema.numero(11)).foregroundStyle(Tema.tenue2)
                                        .frame(width: 112, alignment: .trailing)
                                }
                            }
                            .contentShape(Rectangle())
                            .help("\(tipsTemp[t.nombre] ?? t.nombre)\n\n\(t.n) sensores con lectura")
                        }
                    }
                }
                Rejilla {
                    Panel(titulo: "Estado") {
                        VStack(spacing: 0) {
                            FilaDato("Más caliente", f.familiaMax.map { "\($0.nombre) · \(Formato.temp($0.max))" } ?? "—")
                            FilaDato("Presión térmica", PresionTermica.nombre(f.potencia?.termico),
                                     ayuda: "El nivel que usa macOS para decidir si baja frecuencias. «Nominal» significa sin limitación.")
                            FilaDato("Ventiladores", f.rpmMax > 0 ? "\(Int(f.rpmMax)) rpm" : "detenidos")
                        }
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.temperatura], color: Tema.ambar, relleno: true, nombre: "máxima")],
                               escala: .auto(minimo: 60), ahora: ui.ahora,
                               formato: { Formato.decimal($0, 1) + " °C" })
            }
        }
    }
}

// MARK: - Ventiladores

struct DetalleVentiladores: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        Pagina(modulo: .ventiladores, extra: {
            Insignia(f.rpmMax > 0 ? "en marcha" : "detenidos", f.rpmMax > 0 ? .info : .neutro)
        }) {
            VStack(spacing: 12) {
                Panel(titulo: "Ventiladores", ayuda: "Se leen del chip SMC por IOKit.") {
                    if f.ventiladores.isEmpty {
                        Vacio(texto: "Este equipo no tiene ventiladores o el SMC no los publica.", icono: "fan.slash")
                    } else {
                        HStack(spacing: 12) {
                            ForEach(f.ventiladores, id: \.id) { v in
                                let rpm = v.rpm ?? 0
                                VStack(spacing: 6) {
                                    Helice(rpm: rpm, color: rpm > 0 ? Tema.nsCian : Tema.nsDinamico(0x3c4b5c, 0x98a5b4))
                                        .frame(width: 58, height: 58)
                                    Cifra(valor: v.rpm.map { "\(Int($0.rounded()))" } ?? "—", unidad: "rpm",
                                          color: rpm > 0 ? Tema.cian : Tema.tenue2, tam: 24)
                                    Rotulo("ventilador \(v.id)")
                                    BarraNivel(fraccion: v.pct / 100, color: Tema.cian, alto: 4)
                                    Text("\(Int(v.min))–\(Int(v.max)) rpm").font(Tema.numero(9.5)).foregroundStyle(Tema.tenue)
                                }
                                .padding(12)
                                .frame(maxWidth: 200)
                                .background(Tema.panel2, in: RoundedRectangle(cornerRadius: 8))
                                .help("Ventilador \(v.id): \(rpm > 0 ? "\(Int(rpm)) rpm" : "detenido") · rango \(Int(v.min))–\(Int(v.max)) rpm")
                            }
                            Spacer(minLength: 0)
                        }
                        Text("0 rpm es lo normal en reposo: los Mac con Apple Silicon disipan por el chasis sin aire forzado mientras el consumo sea bajo.")
                            .font(.system(size: 11)).foregroundStyle(Tema.tenue)
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.ventilador], color: Tema.cian, relleno: true, nombre: "máx")],
                               escala: .auto(minimo: 1000), ahora: ui.ahora, formato: { "\(Int($0)) rpm" })
            }
        }
    }
}

// MARK: - Consumo

struct DetalleConsumo: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let p = f.potencia
        let partes = (p?.cpu ?? 0) + (p?.gpu ?? 0) + (p?.ane ?? 0) + (p?.dram ?? 0)
        let total = f.vatios ?? partes
        let resto = max(0, total - partes)
        let congelados = p?.bloquesCongelados == true
        Pagina(modulo: .consumo, extra: {
            Insignia("sin sudo", .ok, icono: "lock.open")
                .help("Las cifras salen de IOReport, el mismo origen que powermetrics, sin privilegios de administrador.")
        }) {
            VStack(spacing: 12) {
                Panel(titulo: "Ahora", detalle: p?.sistema != nil ? "equipo completo · medido en \(p?.fuente == "SMC" ? "el SMC" : p?.fuente == "batería" ? "la batería" : "el cargador")" : "suma de bloques del chip") {
                    VStack(alignment: .leading, spacing: 10) {
                        Cifra(valor: Formato.decimal(total, 2), unidad: "W", color: Tema.ambar, tam: 32)
                        BarraApilada(segmentos: [(p?.cpu ?? 0, Tema.cian), (p?.gpu ?? 0, Tema.violeta), (p?.ane ?? 0, Tema.verde),
                                                 (p?.dram ?? 0, Tema.ambar), (resto, Tema.tenue2)],
                                     total: max(total, 0.01), alto: 12)
                        HStack(spacing: 14) {
                            Leyenda(color: Tema.cian, nombre: "CPU", valor: Formato.vatios(p?.cpu, 2))
                            Leyenda(color: Tema.violeta, nombre: "GPU", valor: Formato.vatios(p?.gpu, 2))
                            Leyenda(color: Tema.verde, nombre: "Neural Engine", valor: Formato.vatios(p?.ane, 2),
                                    ayuda: "Núcleos dedicados a aprendizaje automático. 0 W significa que ninguna app los está usando.")
                            Leyenda(color: Tema.ambar, nombre: "DRAM", valor: Formato.vatios(p?.dram, 2))
                            if p?.sistema != nil {
                                Leyenda(color: Tema.tenue2, nombre: congelados ? "Sin desglose" : "Resto", valor: Formato.vatios(resto, 2),
                                        ayuda: congelados ? "Todo lo que no es la GPU: con batería no se puede repartir por bloque."
                                                          : "Pantalla, SSD, Wi-Fi, controladores y todo lo que no es el chip.")
                            }
                        }
                        if congelados {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "battery.50percent").foregroundStyle(Tema.ambar)
                                Text("Con batería, macOS deja de actualizar los contadores de energía de CPU, DRAM y Neural Engine: solo se miden el total del equipo y la GPU. El desglose vuelve al conectar el cargador.")
                                    .font(.system(size: 11)).foregroundStyle(Tema.tenue)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Rejilla {
                    Panel(titulo: "Frecuencias") {
                        VStack(spacing: 0) {
                            ForEach(Array((p?.clusters ?? []).enumerated()), id: \.offset) { _, c in
                                FilaDato(c.nombre, "\(Formato.mhz(c.mhz)) · \(Formato.pct(c.activa))",
                                         color: c.nombre.hasPrefix("E") ? Tema.verde : Tema.cian)
                            }
                            FilaDato("GPU", "\(Formato.mhz(p?.gpuMHz)) · \(Formato.pct(p?.gpuActiva))", color: Tema.violeta)
                        }
                    }
                    Panel(titulo: "Contexto") {
                        VStack(spacing: 0) {
                            FilaDato("Presión térmica", PresionTermica.nombre(p?.termico))
                            if let b = f.bateria {
                                FilaDato("Alimentación", b.estado == .descargando ? "batería" : "cargador" + (b.adaptador.map { " de \(Int($0)) W" } ?? ""))
                                if b.estado == .cargando, let w = b.vatios {
                                    FilaDato("Cargando la batería", Formato.vatios(w, 1), color: Tema.verde)
                                }
                            }
                            if let s = p?.smc, p?.fuente != "SMC" {
                                FilaDato("Total según el SMC", Formato.vatios(s, 1),
                                         ayuda: "Clave PSTR del controlador del sistema. Queda por debajo de lo que entregan la batería o el cargador: no cuenta todos los componentes. Por eso el total de arriba sale de la batería o del cargador.")
                            }
                        }
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.potencia], color: Tema.ambar, relleno: true, nombre: "equipo"),
                                        Trazo(muestras: ui.historial[.potenciaCPU], color: Tema.cian, nombre: "cpu"),
                                        Trazo(muestras: ui.historial[.potenciaGPU], color: Tema.violeta, nombre: "gpu")],
                               escala: .auto(minimo: 10), ahora: ui.ahora, formato: { Formato.vatios($0, 1) })
            }
        }
    }
}

// MARK: - Bateria

struct DetalleBateria: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        Pagina(modulo: .bateria, extra: {
            if let b = f.bateria { Insignia(b.estado.rawValue, b.estado == .descargando ? (b.pct < 20 ? .critico : .neutro) : .ok) }
        }) {
            VStack(spacing: 12) {
                if let b = f.bateria {
                    let temp = b.temperatura ?? f.temperaturas.first { $0.id == "TB" }?.max
                    Rejilla {
                        Panel(titulo: "Carga") {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(alignment: .firstTextBaseline) {
                                    Cifra(valor: "\(Int(b.pct.rounded()))", unidad: "%", tam: 34)
                                    Spacer()
                                    if let m = b.minutosRestantes {
                                        Text("quedan \(Formato.lapso(Double(m) * 60))").font(Tema.numero(12)).foregroundStyle(Tema.tenue)
                                    }
                                }
                                BarraNivel(fraccion: b.pct / 100,
                                           color: b.estado == .descargando ? (b.pct < 20 ? Tema.rojo : b.pct < 40 ? Tema.ambar : Tema.verde) : Tema.verde,
                                           alto: 10)
                            }
                        }
                        Panel(titulo: "Estado") {
                            VStack(spacing: 0) {
                                FilaDato("Flujo", b.vatios.map { (b.estado == .descargando ? "−" : "+") + Formato.vatios($0, 2) } ?? "—",
                                         ayuda: "Vatios entrando (+) o saliendo (−) de la batería.")
                                if let a = b.adaptador { FilaDato("Cargador", "\(Int(a)) W") }
                                FilaDato("Ciclos", b.ciclos.map { "\($0)" } ?? "—",
                                         ayuda: "Un ciclo equivale a consumir el 100 % de la capacidad. Apple estima 1000 ciclos hasta bajar al 80 %.")
                                FilaDato("Salud", Formato.pct(b.salud),
                                         ayuda: "Capacidad máxima comparada con la de fábrica, la misma cifra que muestra Ajustes.")
                                FilaDato("Temperatura", Formato.temp(temp), color: temp.map { $0 > 35 ? Tema.ambar : Tema.texto } ?? Tema.texto,
                                         ayuda: "El calor es lo que más degrada una batería de litio.")
                            }
                        }
                    }
                } else {
                    Panel { Vacio(texto: "Este equipo no tiene batería.", icono: "powerplug") }
                }
                Panel { PanelAhorro(ajustes: ui.ajustes, ahorro: ui.ahorro, compacto: true) }
                PanelTramo(tramo: f.tramo, ui: ui)
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.bateria], color: Tema.verde, relleno: true, nombre: "carga")],
                               ahora: ui.ahora)
            }
        }
    }
}

// MARK: - Red y disco

struct DetalleRed: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        Pagina(modulo: .red) {
            VStack(spacing: 12) {
                Panel(titulo: "Ahora", ayuda: "Bytes por segundo por las interfaces físicas (en*). Los túneles de VPN no se suman: repetirían el mismo tráfico.") {
                    HStack(spacing: 28) {
                        VStack(alignment: .leading, spacing: 2) {
                            Rotulo("entrada", color: Tema.verde)
                            Cifra(valor: Formato.tasaPartes(f.red.entrada).0, unidad: Formato.tasaPartes(f.red.entrada).1, color: Tema.verde, tam: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Rotulo("salida", color: Tema.cian)
                            Cifra(valor: Formato.tasaPartes(f.red.salida).0, unidad: Formato.tasaPartes(f.red.salida).1, color: Tema.cian, tam: 28)
                        }
                        Spacer()
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.redEntrada], color: Tema.verde, relleno: true, nombre: "entrada"),
                                        Trazo(muestras: ui.historial[.redSalida], color: Tema.cian, nombre: "salida")],
                               escala: .auto(minimo: 10_240), ahora: ui.ahora, formato: { Formato.tasa($0) }, alto: 150)
                Panel(titulo: "Interfaces", detalle: "totales desde el arranque") {
                    VStack(spacing: 0) {
                        ForEach(f.interfaces, id: \.nombre) { i in
                            HStack {
                                Text(i.nombre).font(Tema.numero(11.5, .medium)).foregroundStyle(Tema.texto).frame(width: 50, alignment: .leading)
                                Text("↓ \(Formato.tasa(i.entrada))").font(Tema.numero(11)).foregroundStyle(Tema.verde).frame(width: 110, alignment: .leading)
                                Text("↑ \(Formato.tasa(i.salida))").font(Tema.numero(11)).foregroundStyle(Tema.cian).frame(width: 110, alignment: .leading)
                                Spacer()
                                Text("\(Formato.bytes(i.totalEntrada)) / \(Formato.bytes(i.totalSalida))")
                                    .font(Tema.numero(10)).foregroundStyle(Tema.tenue)
                            }
                            .padding(.vertical, 4)
                            .opacity(i.totalEntrada + i.totalSalida == 0 ? 0.45 : 1)
                        }
                    }
                }
            }
        }
    }
}

struct DetalleDisco: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        Pagina(modulo: .disco) {
            VStack(spacing: 12) {
                Panel(titulo: "Ahora", ayuda: "Lectura y escritura sobre todos los discos, internos y externos. Un SSD interno sostiene varios GB/s: estas cifras rara vez lo rozan.") {
                    HStack(spacing: 28) {
                        VStack(alignment: .leading, spacing: 2) {
                            Rotulo("lectura", color: Tema.ambar)
                            Cifra(valor: Formato.tasaPartes(f.disco.entrada).0, unidad: Formato.tasaPartes(f.disco.entrada).1, color: Tema.ambar, tam: 28)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Rotulo("escritura", color: Tema.violeta)
                            Cifra(valor: Formato.tasaPartes(f.disco.salida).0, unidad: Formato.tasaPartes(f.disco.salida).1, color: Tema.violeta, tam: 28)
                        }
                        Spacer()
                    }
                }
                PanelHistorial(titulo: "Historial",
                               trazos: [Trazo(muestras: ui.historial[.discoLectura], color: Tema.ambar, relleno: true, nombre: "lectura"),
                                        Trazo(muestras: ui.historial[.discoEscritura], color: Tema.violeta, nombre: "escritura")],
                               escala: .auto(minimo: 102_400), ahora: ui.ahora, formato: { Formato.tasa($0) }, alto: 150)
            }
        }
    }
}

// MARK: - ¿Qué gastó la batería?

/// El último tramo con batería según el registro de energía de macOS: curva
/// de carga, vatios y reparto del consumo por app.
struct PanelTramo: View {
    let tramo: TramoBateria?
    @ObservedObject var ui: Interfaz

    var body: some View {
        Panel(titulo: "¿Qué gastó la batería?", detalle: tramo.map { encabezado($0) },
              ayuda: "Sale del registro de energía de macOS, el mismo de la columna «Energía en 12 h» del Monitor de Actividad. Se lee cada 5 minutos con esta página abierta.") {
            if let t = tramo {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 18) {
                        dato("carga", "\(Int(t.nivelInicio)) % → \(Int(t.nivelFin)) %", t.puntos > 0 ? Tema.ambar : Tema.verde)
                        dato("gastó", "\(Int(t.puntos.rounded())) puntos", Tema.texto)
                        dato("despierta", Formato.lapso(t.despierta), Tema.texto)
                        dato("media", Formato.vatios(t.vatiosMedios), Tema.ambar)
                        if t.despierta > 600 && t.puntos > 0 {
                            dato("ritmo", "\(Formato.decimal(t.puntos / (t.despierta / 3600), 1)) %/h", Tema.texto)
                        }
                    }
                    if t.minutosCamara >= 3 {
                        HStack(spacing: 8) {
                            Insignia("videollamada", .info, icono: "video.fill")
                            Text("La cámara estuvo encendida \(Formato.lapso(t.minutosCamara * 60)) en este tramo.")
                                .font(.system(size: 11.5)).foregroundStyle(Tema.texto)
                        }
                    }
                    let ventana = max(600, t.fin.timeIntervalSince1970 - t.inicio.timeIntervalSince1970)
                    VStack(alignment: .leading, spacing: 4) {
                        Grafico(trazos: [Trazo(muestras: t.curva, color: Tema.verde, relleno: true, nombre: "carga")],
                                ventana: ventana, escala: .fija(100), ahora: t.fin.timeIntervalSince1970,
                                formato: { "\(Int($0.rounded())) %" }, interactivo: true, reticula: true, corte: 1800)
                            .frame(height: 90)
                        Grafico(trazos: [Trazo(muestras: t.potencia, color: Tema.ambar, relleno: true, nombre: "consumo")],
                                ventana: ventana, escala: .auto(minimo: 10), ahora: t.fin.timeIntervalSince1970,
                                formato: { Formato.vatios($0, 1) }, interactivo: true, corte: 1800)
                            .frame(height: 50)
                        HStack {
                            Text(hora(t.inicio)); Spacer(); Text(t.enCurso ? "ahora" : hora(t.fin))
                        }
                        .font(Tema.numero(9.5)).foregroundStyle(Tema.tenue)
                    }
                    Rotulo("consumo por app")
                    let tope = max(1, t.apps.map(\.pctEnergia).max() ?? 1)
                    VStack(spacing: 0) {
                        ForEach(t.apps) { a in
                            HStack(spacing: 8) {
                                Text(a.nombre).font(.system(size: 11.5)).foregroundStyle(Tema.texto).lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                BarraNivel(fraccion: a.pctEnergia / tope, color: Tema.ambar, alto: 5)
                                Text(Formato.decimal(a.pctEnergia, 1) + " %").font(Tema.numero(11, .medium))
                                    .foregroundStyle(Tema.texto).frame(width: 56, alignment: .trailing)
                                Text("CPU " + Formato.lapso(a.cpu)).font(Tema.numero(10)).foregroundStyle(Tema.tenue)
                                    .frame(width: 78, alignment: .trailing)
                                Text("GPU " + Formato.pct(a.pctGPU)).font(Tema.numero(10)).foregroundStyle(Tema.tenue)
                                    .frame(width: 62, alignment: .trailing)
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    Text("Proporciones del consumo atribuido a apps; la pantalla gasta además por su cuenta. El reposo no cuenta como tiempo despierta.")
                        .font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
                }
            } else {
                Vacio(texto: "Leyendo el registro de energía de macOS… Si no aparece, el sistema no dejó leerlo o no hubo tramos con batería en las últimas 48 h.",
                      icono: "hourglass")
            }
        }
    }

    private func encabezado(_ t: TramoBateria) -> String {
        t.enCurso ? "con batería desde las \(hora(t.inicio))" : "último tramo: \(hora(t.inicio)) – \(hora(t.fin))"
    }

    private func hora(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "dd/MM HH:mm"
        return f.string(from: d)
    }

    private func dato(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Rotulo(k)
            Text(v).font(Tema.numero(15, .medium)).foregroundStyle(c)
        }
    }
}
