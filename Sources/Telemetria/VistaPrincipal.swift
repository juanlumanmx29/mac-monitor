import SwiftUI

/// Ventana principal: barra lateral con el valor vivo de cada modulo y, a la
/// derecha, el resumen o el detalle elegido.
struct VistaPrincipal: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        NavigationSplitView {
            BarraLateral(ui: ui)
                .navigationSplitViewColumnWidth(min: 210, ideal: 228, max: 300)
        } detail: {
            VStack(spacing: 0) {
                ZStack {
                    Tema.fondo
                    Reticula()
                    contenido
                }
                PieEstado(ui: ui)
            }
            .background(Tema.fondo)
        }
        .tint(Tema.cian)
    }

    @ViewBuilder private var contenido: some View {
        switch ui.seleccion ?? .resumen {
        case .resumen: PaginaResumen(ui: ui)
        case .cpu: DetalleCPU(ui: ui)
        case .gpu: DetalleGPU(ui: ui)
        case .memoria: DetalleMemoria(ui: ui)
        case .termico: DetalleTermico(ui: ui)
        case .ventiladores: DetalleVentiladores(ui: ui)
        case .consumo: DetalleConsumo(ui: ui)
        case .bateria: DetalleBateria(ui: ui)
        case .red: DetalleRed(ui: ui)
        case .disco: DetalleDisco(ui: ui)
        case .procesos: DetalleProcesos(ui: ui)
        case .energia: DetalleEnergia(ui: ui)
        case .puertos: DetallePuertos(ui: ui)
        case .reposo: DetalleReposo(ui: ui)
        case .vigilancia: DetalleVigilancia(ui: ui)
        }
    }
}

// MARK: - Barra lateral

struct BarraLateral: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        VStack(spacing: 0) {
            Marca(ui: ui)
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 10)
            List(selection: $ui.seleccion) {
                fila(.resumen)
                Section { ForEach(Modulo.equipo) { fila($0) } } header: { Rotulo("Equipo") }
                Section { ForEach(Modulo.actividad) { fila($0) } } header: { Rotulo("Actividad") }
                Section { fila(.vigilancia) } header: { Rotulo("Vigilancia") }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            ControlMotor(ui: ui)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
        }
        .background(Tema.lateral)
    }

    private func fila(_ m: Modulo) -> some View {
        let r = m == .resumen ? Resumen() : ui.resumen(m)
        let alerta = m == .vigilancia && !ui.foto.activas.isEmpty
        return HStack(spacing: 8) {
            Image(systemName: m.icono)
                .font(.system(size: 12))
                .frame(width: 18)
                .foregroundStyle(alerta ? Tema.color(ui.foto.peorNivel) : Tema.tenue)
            Text(m.titulo).font(.system(size: 12.5))
            Spacer(minLength: 4)
            if m != .resumen {
                Text(r.corto)
                    .font(Tema.numero(11, .medium))
                    .foregroundStyle(r.color)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 1)
        .tag(m)
    }
}

/// Logotipo, chip y reloj de mision (tiempo desde el arranque del sistema).
struct Marca: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).strokeBorder(Tema.cian, lineWidth: 1)
                    .background(Tema.cian.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                Image(systemName: "waveform.path.ecg").font(.system(size: 13, weight: .semibold)).foregroundStyle(Tema.cian)
            }
            .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("TELEMETRÍA").font(.system(size: 11.5, weight: .semibold)).tracking(2.2)
                    .foregroundStyle(Tema.texto)
                HStack(spacing: 5) {
                    Text(ui.equipo.chipCorto).font(Tema.numero(9.5)).foregroundStyle(Tema.tenue)
                    Text("T+ " + Formato.reloj(ui.actividad)).font(Tema.numero(9.5)).foregroundStyle(Tema.cian)
                        .help("Tiempo desde el arranque del sistema")
                }
            }
            Spacer(minLength: 0)
        }
    }
}

struct ControlMotor: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ui.pausado ? Tema.ambar : Tema.verde)
                .frame(width: 7, height: 7)
                .shadow(color: ui.pausado ? Tema.ambar : Tema.verde, radius: 3)
            Text(ui.pausado ? "EN PAUSA" : "NOMINAL")
                .font(Tema.numero(10, .medium)).tracking(1.2).foregroundStyle(Tema.tenue)
            Spacer()
            Button {
                ui.pausado.toggle()
            } label: {
                Image(systemName: ui.pausado ? "play.fill" : "pause.fill").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help(ui.pausado ? "Reanudar el refresco (⇧⌘P)" : "Congelar el refresco (⇧⌘P). La vigilancia sigue en segundo plano.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Tema.panel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Tema.linea, lineWidth: 1))
    }
}

/// Lo que gasta la propia app, a la vista: es la promesa del proyecto.
struct PieEstado: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        let f = ui.foto
        let c = f.propio
        HStack(spacing: 14) {
            dato("muestreo", "\(Int(f.intervalo)) s")
            dato("ciclo", Formato.decimal(c.ciclo, 1) + " ms")
            dato("cpu app", Formato.decimal(c.cpu, 1) + " %")
                .help("CPU de un núcleo que usa esta app, sin contar el dibujo de la ventana.")
            dato("auxiliares", Formato.decimal(c.auxiliares, 1) + " %")
                .help("ps (procesos de otros usuarios), launchctl y top (energía e hilos), lanzados con cadencias lentas.")
            dato("memoria", Formato.mb(c.memoria))
            Spacer(minLength: 8)
            fuente("smc", f.fuentes.smc, f.fuentes.smc ? "\(f.fuentes.sensores) sensores" : f.fuentes.smcMotivo)
            fuente("ioreport", f.fuentes.ioreport, f.fuentes.ioreport ? "potencia y frecuencias sin sudo" : f.fuentes.ioreportMotivo)
            fuente("vigilancia", f.fuentes.vigilancia, f.fuentes.vigilancia ? "launchd leído" : "sin lista de launchd")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(Tema.lateral)
        .overlay(alignment: .top) { Rectangle().fill(Tema.linea).frame(height: 1) }
    }

    private func dato(_ k: String, _ v: String) -> some View {
        HStack(spacing: 4) {
            Text(k).foregroundStyle(Tema.tenue2)
            Text(v).foregroundStyle(Tema.tenue)
        }
        .font(Tema.numero(9.5))
    }

    private func fuente(_ k: String, _ ok: Bool, _ ayuda: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Tema.verde : Tema.ambar).frame(width: 5, height: 5)
            Text(k).font(Tema.numero(9.5)).foregroundStyle(Tema.tenue)
        }
        .help(ayuda)
    }
}

// MARK: - Paginas

/// Marco comun de una pagina de detalle: cabecera y contenido desplazable.
struct Pagina<Contenido: View, Extra: View>: View {
    let modulo: Modulo
    var desplazable = true
    @ViewBuilder var extra: Extra
    @ViewBuilder var contenido: Contenido

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: modulo.icono)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Tema.cian)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(modulo.titulo).font(.system(size: 18, weight: .semibold)).foregroundStyle(Tema.texto)
                    Text(modulo.subtitulo).font(.system(size: 11)).foregroundStyle(Tema.tenue)
                }
                Spacer(minLength: 8)
                extra
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 12)
            if desplazable {
                ScrollView {
                    contenido
                        .padding(.horizontal, 20)
                        .padding(.bottom, 20)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                contenido
                    .padding(.horizontal, 20)
                    .padding(.bottom, 14)
            }
        }
    }
}

extension Pagina where Extra == EmptyView {
    init(modulo: Modulo, desplazable: Bool = true, @ViewBuilder contenido: () -> Contenido) {
        self.modulo = modulo
        self.desplazable = desplazable
        self.extra = EmptyView()
        self.contenido = contenido()
    }
}

/// Rejilla adaptable de paneles: dos o tres columnas segun el ancho.
struct Rejilla<Contenido: View>: View {
    var minimo: CGFloat = 330
    @ViewBuilder var contenido: Contenido

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimo), spacing: 12, alignment: .top)],
                  alignment: .leading, spacing: 12) {
            contenido
        }
    }
}
