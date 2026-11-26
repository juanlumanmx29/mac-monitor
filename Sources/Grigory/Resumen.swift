import SwiftUI

/// Todo el equipo de un vistazo: una tarjeta por modulo, en tres bloques, y
/// una tarjeta por alerta. Pulsar una tarjeta abre su detalle.
struct PaginaResumen: View {
    @ObservedObject var ui: Interfaz

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                cabecera
                bloque("Equipo", "hardware y energía", Modulo.equipo)
                bloque("Actividad", "red, procesos y servicios", Modulo.actividad)
                VStack(alignment: .leading, spacing: 8) {
                    titulo("Vigilancia", "olvidados, fantasmas y desbocados")
                    rejilla {
                        Tarjeta(modulo: .vigilancia, ui: ui)
                        ForEach(ui.foto.activas.prefix(16)) { a in TarjetaAlerta(alerta: a, ui: ui) }
                    }
                }
            }
            .padding(20)
        }
    }

    private var cabecera: some View {
        let eq = ui.equipo
        var partes = ["\(eq.nucleos) núcleos"]
        if eq.hibrido { partes[0] += " (\(eq.nucleosE) E + \(eq.nucleosP) P)" }
        if let g = eq.gpuNucleos { partes.append("\(g) núcleos de GPU") }
        partes.append("\(Int((Double(eq.ram) / 1_073_741_824).rounded())) GB")
        if !eq.macos.isEmpty { partes.append("macOS \(eq.macos)") }
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Grigory · \(eq.chipCorto)").font(.system(size: 22, weight: .semibold)).foregroundStyle(Tema.texto)
                Text(partes.joined(separator: " · ")).font(Tema.numero(11)).foregroundStyle(Tema.tenue)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 3) {
                Rotulo("activo desde el arranque")
                Text(Formato.reloj(ui.actividad)).font(Tema.numero(15, .medium)).foregroundStyle(Tema.cian)
            }
        }
    }

    private func titulo(_ t: String, _ sub: String) -> some View {
        HStack(spacing: 8) {
            Text(t.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(1.4).foregroundStyle(Tema.texto)
            Text(sub).font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
        }
    }

    private func bloque(_ t: String, _ sub: String, _ modulos: [Modulo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            titulo(t, sub)
            rejilla { ForEach(modulos) { Tarjeta(modulo: $0, ui: ui) } }
        }
    }

    private func rejilla<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 205), spacing: 10)], spacing: 10) { c() }
    }
}

/// Tarjeta de un modulo: valor, contexto, dos cifras y la ultima hora en
/// miniatura (60 s).
struct Tarjeta: View {
    let modulo: Modulo
    @ObservedObject var ui: Interfaz

    var body: some View {
        let r = ui.resumen(modulo)
        Button { ui.ir(modulo) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: modulo.icono).font(.system(size: 11)).foregroundStyle(Tema.tenue)
                    Rotulo(modulo.titulo, tam: 9.5)
                    Spacer(minLength: 0)
                    if let i = Modulo.numerados.firstIndex(of: modulo) {
                        Text("⌘\(i + 1)").font(Tema.numero(8.5)).foregroundStyle(Tema.tenue2)
                    }
                }
                Cifra(valor: r.valor, unidad: r.unidad, color: r.color, tam: 27)
                Text(r.sub.isEmpty ? " " : r.sub).font(.system(size: 11)).foregroundStyle(Tema.tenue).lineLimit(1)
                HStack(spacing: 10) {
                    ForEach(Array(r.extras.prefix(3).enumerated()), id: \.offset) { _, e in
                        HStack(spacing: 3) {
                            Text(e.0).foregroundStyle(Tema.tenue)
                            Text(e.1).foregroundStyle(Tema.texto).fontWeight(.medium)
                        }
                        .font(.system(size: 10))
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 2)
                Grafico(trazos: r.trazos, ventana: 60, escala: r.escala, ahora: ui.ahora)
                    .frame(height: 30)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 148, maxHeight: 148, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .resaltable()
    }
}

/// Una alerta de la vigilancia como tarjeta del resumen.
struct TarjetaAlerta: View {
    let alerta: Alerta
    @ObservedObject var ui: Interfaz

    var body: some View {
        let a = alerta
        Button { ui.verAlerta(a) } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Insignia(a.nivel.nombre, Tono(a.nivel))
                    Rotulo(a.regla.nombre)
                    Spacer(minLength: 0)
                }
                Cifra(valor: valorAlerta(a).0, unidad: valorAlerta(a).1, color: Tema.color(a.nivel), tam: 27)
                Text(a.nombreFamilia).font(.system(size: 11)).foregroundStyle(Tema.texto).lineLimit(1)
                HStack(spacing: 10) {
                    if let v = a.veredicto {
                        Text(v.corto).foregroundStyle(v.tono.color).fontWeight(.semibold)
                    }
                    if let c = a.cwd {
                        Text((c as NSString).lastPathComponent).foregroundStyle(Tema.tenue).lineLimit(1)
                    } else {
                        Text("pid ").foregroundStyle(Tema.tenue) + Text("\(a.pid)").foregroundStyle(Tema.texto)
                    }
                    Text("vida ").foregroundStyle(Tema.tenue) + Text(Formato.lapso(a.vida)).foregroundStyle(Tema.texto)
                }
                .font(.system(size: 10))
                Spacer(minLength: 2)
                Text(a.titulo + (a.tty == "??" ? " · sin terminal" : ""))
                    .font(.system(size: 10.5)).foregroundStyle(Tema.tenue).lineLimit(2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 148, maxHeight: 148, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .resaltable()
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(Tema.color(a.nivel)).frame(width: 3).padding(.vertical, 10)
        }
        .help("\(a.titulo)\n\n\(ui.descripcion(a).map { $0.texto + "\n\n" } ?? "")\(a.motivo)")
    }
}

/// La cifra que mejor resume cada alerta.
func valorAlerta(_ a: Alerta) -> (String, String) {
    switch a.regla {
    case .zombi: return ("\(Int(a.valor ?? 0))", " zombis")
    case .reposo: return (Formato.lapso(a.valor), "")
    default:
        if let c = a.cpuSostenida { return ("\(Int(c.rounded()))", "%") }
        return (Formato.lapso(a.vida), "")
    }
}
