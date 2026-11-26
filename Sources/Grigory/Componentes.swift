import AppKit
import QuartzCore
import SwiftUI

// Piezas comunes de la interfaz: paneles, filas de datos, graficos, anillos,
// barras y celdas. Ninguna anima nada por su cuenta: la unica animacion
// continua (la helice de los ventiladores) corre en el servidor de render.

/// Recuadro con titulo opcional, fondo de panel y borde fino.
struct Panel<Contenido: View>: View {
    var titulo: String?
    var detalle: String?
    var ayuda: String?
    @ViewBuilder var contenido: Contenido

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if titulo != nil || detalle != nil {
                HStack(spacing: 6) {
                    if let titulo { Rotulo(titulo) }
                    if let ayuda {
                        Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(Tema.tenue2)
                            .help(ayuda)
                    }
                    Spacer(minLength: 4)
                    if let detalle {
                        Text(detalle).font(Tema.numero(10)).foregroundStyle(Tema.tenue).lineLimit(1)
                    }
                }
            }
            contenido
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Tema.panel, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Tema.linea, lineWidth: 1))
    }
}

/// Fila "etiqueta ........ valor", con explicacion al pasar el cursor.
struct FilaDato: View {
    let etiqueta: String
    let valor: String
    var color: Color = Tema.texto
    var ayuda: String?

    init(_ etiqueta: String, _ valor: String, color: Color = Tema.texto, ayuda: String? = nil) {
        self.etiqueta = etiqueta
        self.valor = valor
        self.color = color
        self.ayuda = ayuda
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(etiqueta).font(.system(size: 11.5)).foregroundStyle(Tema.tenue)
            Spacer(minLength: 8)
            Text(valor).font(Tema.numero(11.5, .medium)).foregroundStyle(color).lineLimit(1)
        }
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Tema.linea.opacity(0.6)).frame(height: 1) }
        .contentShape(Rectangle())
        .help(ayuda ?? "")
    }
}

/// Valor grande con unidad pequena: "42 %", "13,4 W".
struct Cifra: View {
    let valor: String
    var unidad: String = ""
    var color: Color = Tema.texto
    var tam: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(valor).font(Tema.numero(tam, .light)).foregroundStyle(color)
            if !unidad.isEmpty {
                Text(unidad).font(Tema.numero(tam * 0.42)).foregroundStyle(Tema.tenue)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Indicador circular de 0 a 100.
struct Anillo: View {
    let valor: Double
    var color: Color = Tema.cian
    var grosor: CGFloat = 7

    var body: some View {
        ZStack {
            Circle().stroke(Tema.linea, lineWidth: grosor)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, valor / 100)))
                .stroke(color, style: StrokeStyle(lineWidth: grosor, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(grosor / 2)
    }
}

/// Barra horizontal con relleno proporcional.
struct BarraNivel: View {
    let fraccion: Double
    var color: Color = Tema.cian
    var alto: CGFloat = 6

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Tema.linea)
                Capsule().fill(color).frame(width: max(alto, g.size.width * max(0, min(1, fraccion))))
            }
        }
        .frame(height: alto)
    }
}

/// Barra con varios segmentos (memoria, consumo).
struct BarraApilada: View {
    let segmentos: [(Double, Color)]
    let total: Double
    var alto: CGFloat = 10

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 1) {
                ForEach(Array(segmentos.enumerated()), id: \.offset) { _, s in
                    Rectangle().fill(s.1).frame(width: total > 0 ? max(0, g.size.width * s.0 / total - 1) : 0)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Tema.linea)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: alto)
    }
}

/// Muestra de leyenda: cuadradito de color, nombre y valor.
struct Leyenda: View {
    let color: Color
    let nombre: String
    let valor: String
    var ayuda: String?

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(nombre).font(.system(size: 10.5)).foregroundStyle(Tema.tenue)
            Text(valor).font(Tema.numero(10.5, .medium)).foregroundStyle(Tema.texto)
        }
        .help(ayuda ?? "")
    }
}

// MARK: - Graficos

struct Trazo {
    let muestras: [Muestra]
    let color: Color
    var relleno = false
    var nombre = ""
}

enum Escala {
    case fija(Double)
    case auto(minimo: Double)
}

/// Serie temporal dibujada con Canvas. El eje x es tiempo real: los huecos
/// (la ventana estuvo cerrada) se dibujan como cortes, no como rampas.
/// Con `interactivo`, el cursor muestra el valor de cada trazo en ese instante.
struct Grafico: View {
    let trazos: [Trazo]
    var ventana: Double = 60
    var escala: Escala = .fija(100)
    let ahora: Double
    var formato: (Double) -> String = { "\(Int($0.rounded()))" }
    var interactivo = false
    var reticula = false
    var punto = true

    /// Segundos sin muestras a partir de los cuales la linea se corta.
    var corte = 12.0

    private let cursor = State<CGFloat?>(initialValue: nil)

    private var tope: Double {
        switch escala {
        case .fija(let v): return v
        case .auto(let minimo):
            let inicio = ahora - ventana
            let mx = trazos.flatMap { $0.muestras.filter { $0.t >= inicio }.map(\.v) }.max() ?? 0
            return max(minimo, mx * 1.15)
        }
    }

    var body: some View {
        let tope = self.tope
        Canvas { ctx, size in
            let inicio = ahora - ventana
            func x(_ t: Double) -> CGFloat { CGFloat((t - inicio) / ventana) * size.width }
            func y(_ v: Double) -> CGFloat { size.height - CGFloat(min(v, tope) / tope) * (size.height - 2) - 1 }

            if reticula {
                for i in 1..<4 {
                    var l = Path()
                    let yy = size.height * CGFloat(i) / 4
                    l.move(to: CGPoint(x: 0, y: yy))
                    l.addLine(to: CGPoint(x: size.width, y: yy))
                    ctx.stroke(l, with: .color(Tema.linea), lineWidth: 1)
                }
            }

            for trazo in trazos {
                let visibles = trazo.muestras.drop { $0.t < inicio - corte }
                guard visibles.count > 1 else { continue }
                // Tramos continuos: se corta donde falta mas de `corte` segundos.
                var tramos: [[Muestra]] = [[]]
                var previa: Muestra?
                for m in visibles {
                    if let p = previa, m.t - p.t > corte { tramos.append([]) }
                    tramos[tramos.count - 1].append(m)
                    previa = m
                }
                for tramo in tramos where tramo.count > 1 {
                    var linea = Path()
                    linea.move(to: CGPoint(x: x(tramo[0].t), y: y(tramo[0].v)))
                    for m in tramo.dropFirst() { linea.addLine(to: CGPoint(x: x(m.t), y: y(m.v))) }
                    if trazo.relleno {
                        var area = linea
                        area.addLine(to: CGPoint(x: x(tramo.last!.t), y: size.height))
                        area.addLine(to: CGPoint(x: x(tramo[0].t), y: size.height))
                        area.closeSubpath()
                        ctx.fill(area, with: .linearGradient(
                            Gradient(colors: [trazo.color.opacity(0.24), trazo.color.opacity(0)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    ctx.stroke(linea, with: .color(trazo.color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
                if punto, let u = visibles.last {
                    let c = CGPoint(x: x(u.t), y: y(u.v))
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)), with: .color(trazo.color))
                }
            }

            if interactivo, let cx = cursor.wrappedValue {
                var l = Path()
                l.move(to: CGPoint(x: cx, y: 0))
                l.addLine(to: CGPoint(x: cx, y: size.height))
                ctx.stroke(l, with: .color(Tema.tenue), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                let t = inicio + Double(cx / size.width) * ventana
                for trazo in trazos {
                    if let m = cercana(trazo.muestras, t) {
                        let c = CGPoint(x: x(m.t), y: y(m.v))
                        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)), with: .color(trazo.color))
                    }
                }
            }
        }
        .modifier(Lector(activo: interactivo, cursor: cursor.projectedValue) { cx, ancho in
            lectura(ahora - ventana + Double(cx / max(1, ancho)) * ventana)
        })
    }

    /// Seguimiento del cursor y etiqueta flotante. Solo se instala en los
    /// graficos interactivos: en las miniaturas seria trabajo sin uso.
    private struct Lector<Etiqueta: View>: ViewModifier {
        let activo: Bool
        let cursor: Binding<CGFloat?>
        let etiqueta: (CGFloat, CGFloat) -> Etiqueta

        func body(content: Content) -> some View {
            if activo {
                content
                    .overlay(alignment: .topLeading) {
                        if let cx = cursor.wrappedValue {
                            GeometryReader { g in
                                etiqueta(cx, g.size.width)
                                    .fixedSize()
                                    .offset(x: cx > g.size.width * 0.6 ? max(0, cx - 150) : cx + 8, y: 2)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { fase in
                        switch fase {
                        case .active(let p): cursor.wrappedValue = p.x
                        case .ended: cursor.wrappedValue = nil
                        }
                    }
            } else {
                content
            }
        }
    }

    private func lectura(_ t: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ahora - t < 1.5 ? "ahora" : "hace \(Formato.lapso(ahora - t))")
                .font(.system(size: 9.5)).foregroundStyle(Tema.tenue)
            ForEach(Array(trazos.enumerated()), id: \.offset) { _, trazo in
                if let m = cercana(trazo.muestras, t) {
                    HStack(spacing: 4) {
                        Circle().fill(trazo.color).frame(width: 6, height: 6)
                        if !trazo.nombre.isEmpty {
                            Text(trazo.nombre).font(.system(size: 10)).foregroundStyle(Tema.tenue)
                        }
                        Text(formato(m.v)).font(Tema.numero(10.5, .semibold)).foregroundStyle(Tema.texto)
                    }
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(Tema.panel2.opacity(0.96), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Tema.linea, lineWidth: 1))
    }

    /// Muestra mas cercana a `t` (busqueda binaria), si no esta en un hueco.
    private func cercana(_ m: [Muestra], _ t: Double) -> Muestra? {
        guard !m.isEmpty else { return nil }
        var lo = 0, hi = m.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if m[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        let candidatas = [lo - 1, lo].filter { $0 >= 0 && $0 < m.count }.map { m[$0] }
        guard let c = candidatas.min(by: { abs($0.t - t) < abs($1.t - t) }), abs(c.t - t) < corte / 2 else { return nil }
        return c
    }
}

// MARK: - Celdas

/// Celda de la rejilla de nucleos o de estados de frecuencia. El tono indica
/// el nivel y la opacidad la intensidad: un nucleo en reposo casi desaparece
/// y uno saturado resalta sin leer el numero.
struct Celda: View {
    let rotulo: String
    let valor: Double
    var pie: String?
    var semaforo = true
    var ayuda = ""

    var body: some View {
        let base = semaforo ? Tema.nivel(valor) : Tema.violeta
        let texto: Color = valor < 8 ? Tema.tenue2
            : !semaforo ? Tema.texto
            : valor < 55 ? Tema.celdaBajo : valor < 80 ? Tema.celdaMedio : Tema.celdaAlto
        VStack(spacing: 1) {
            HStack {
                Text(rotulo).font(Tema.numero(8.5)).foregroundStyle(Tema.tenue)
                Spacer(minLength: 0)
            }
            Text("\(Int(valor.rounded()))").font(Tema.numero(15, .medium)).foregroundStyle(texto)
            Text(pie ?? " ").font(Tema.numero(8.5)).foregroundStyle(valor < 8 ? Tema.tenue : texto.opacity(0.75)).lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(base.opacity(0.07 + valor / 100 * 0.55), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(base.opacity(0.16 + valor / 100 * 0.5), lineWidth: 1))
        .background(Tema.celda, in: RoundedRectangle(cornerRadius: 5))
        .help(ayuda)
    }
}

/// Columnas de una rejilla segun cuantos elementos haya, para que la forma
/// resultante sea compacta en cualquier Mac, de 4 a 24 nucleos.
func columnas(_ n: Int) -> Int {
    n <= 4 ? max(1, n) : n <= 6 ? 3 : n <= 8 ? 4 : n <= 12 ? 5 : n <= 18 ? 6 : 8
}

// MARK: - Helice

/// Icono de ventilador que gira a una velocidad proporcional a las RPM
/// reales. Es una CABasicAnimation: la ejecuta el servidor de render y la app
/// no gasta CPU por cuadro (un TimelineView o una animacion de SwiftUI si).
struct Helice: NSViewRepresentable {
    let rpm: Double
    let color: NSColor

    func makeNSView(context: Context) -> VistaHelice { VistaHelice() }

    func updateNSView(_ v: VistaHelice, context: Context) {
        v.configurar(rpm: rpm, color: color)
    }
}

final class VistaHelice: NSView {
    private let capa = CALayer()
    private var periodo = 0.0
    private var colorActual: NSColor?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(capa)
        capa.contentsGravity = .resizeAspect
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        capa.bounds = bounds
        capa.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colorActual = nil
        needsLayout = true
    }

    func configurar(rpm: Double, color: NSColor) {
        if colorActual != color || capa.contents == nil {
            colorActual = color
            var resuelto = color
            effectiveAppearance.performAsCurrentDrawingAppearance { resuelto = color.usingColorSpace(.sRGB) ?? color }
            let conf = NSImage.SymbolConfiguration(pointSize: 64, weight: .light)
                .applying(.init(paletteColors: [resuelto]))
            capa.contents = NSImage(systemSymbolName: "fan", accessibilityDescription: nil)?
                .withSymbolConfiguration(conf)
        }
        // Periodo inversamente proporcional a las RPM, acotado para que siga
        // siendo legible a maxima velocidad.
        let nuevo = rpm > 0 ? max(0.12, 60 / rpm * 8) : 0
        guard abs(nuevo - periodo) > periodo * 0.1 || (nuevo == 0) != (periodo == 0) else { return }
        periodo = nuevo
        capa.removeAnimation(forKey: "giro")
        guard nuevo > 0 else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = nuevo
        a.repeatCount = .infinity
        capa.add(a, forKey: "giro")
    }
}

// MARK: - Varios

struct Vacio: View {
    let texto: String
    var icono = "checkmark.circle"

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icono).foregroundStyle(Tema.tenue2)
            Text(texto).font(.system(size: 11.5)).foregroundStyle(Tema.tenue)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

/// Fondo de reticula sutil, como el del panel web. Solo se redibuja al
/// cambiar de tamano.
struct Reticula: View {
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            stride(from: 0, through: size.width, by: 44).forEach { x in
                p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: size.height))
            }
            stride(from: 0, through: size.height, by: 44).forEach { y in
                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: size.width, y: y))
            }
            ctx.stroke(p, with: .color(Tema.cian.opacity(0.035)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Pasar el cursor por encima: borde y fondo resaltados.
struct Resaltable: ViewModifier {
    var activo = false
    private let encima = State(initialValue: false)

    func body(content: Content) -> some View {
        content
            .background(encima.wrappedValue || activo ? Tema.panel2 : Tema.panel, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .strokeBorder(encima.wrappedValue || activo ? Tema.cian.opacity(0.5) : Tema.linea, lineWidth: 1))
            .onHover { encima.wrappedValue = $0 }
    }
}

extension View {
    func resaltable(_ activo: Bool = false) -> some View { modifier(Resaltable(activo: activo)) }
}
