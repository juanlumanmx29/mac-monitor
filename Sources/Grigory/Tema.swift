import AppKit
import SwiftUI

// Paleta del panel: la misma del dashboard web, en version oscura y clara.
// Cada color es un NSColor dinamico: se resuelve segun la apariencia activa,
// tambien dentro de un Canvas, asi que cambiar de tema no exige repintar a mano.

enum Tema {
    static func dinamico(_ oscuro: UInt32, _ claro: UInt32) -> Color {
        Color(nsColor: nsDinamico(oscuro, claro))
    }

    static func nsDinamico(_ oscuro: UInt32, _ claro: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            let hex = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? oscuro : claro
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        }
    }

    static let fondo = dinamico(0x05080d, 0xeef1f6)
    static let lateral = dinamico(0x070b11, 0xe6eaf0)
    static let panel = dinamico(0x0a0f16, 0xffffff)
    static let panel2 = dinamico(0x0d141d, 0xf5f7fa)
    static let linea = dinamico(0x18232f, 0xd8dfe8)
    static let texto = dinamico(0xdbe6f2, 0x0f1720)
    static let tenue = dinamico(0x5e7186, 0x5b6b7d)
    static let tenue2 = dinamico(0x3c4b5c, 0x98a5b4)
    static let celda = dinamico(0x0d1620, 0xe6ebf1)

    // Los tonos claros son mas saturados y oscuros: los del tema oscuro no
    // alcanzan contraste suficiente sobre fondo blanco.
    static let cian = dinamico(0x00d4ff, 0x0072a8)
    static let verde = dinamico(0x00e08a, 0x0f7a45)
    static let ambar = dinamico(0xffb020, 0xa35f00)
    static let rojo = dinamico(0xff4d4d, 0xc0392b)
    static let violeta = dinamico(0xa67aff, 0x6b3fc4)

    static let celdaBajo = dinamico(0x8affc8, 0x0b5c34)
    static let celdaMedio = dinamico(0xffd98a, 0x7d4900)
    static let celdaAlto = dinamico(0xffb3b3, 0x8f2b20)

    static let nsCian = nsDinamico(0x00d4ff, 0x0072a8)
    static let nsAmbar = nsDinamico(0xffb020, 0xa35f00)
    static let nsRojo = nsDinamico(0xff4d4d, 0xc0392b)

    /// Semaforo de carga: verde, ambar, rojo.
    static func nivel(_ v: Double) -> Color { v < 55 ? verde : v < 80 ? ambar : rojo }
    static func temperatura(_ t: Double) -> Color { t < 55 ? verde : t < 75 ? ambar : rojo }

    static func color(_ n: Nivel?) -> Color {
        switch n {
        case .critico: return rojo
        case .aviso: return ambar
        case .info: return cian
        case nil: return verde
        }
    }

    static func numero(_ tam: CGFloat, _ peso: Font.Weight = .regular) -> Font {
        .system(size: tam, weight: peso, design: .monospaced)
    }
}

/// Etiqueta en mayusculas con espaciado amplio, como las cabeceras del panel.
struct Rotulo: View {
    let texto: String
    var color: Color = Tema.tenue
    var tam: CGFloat = 9.5

    init(_ texto: String, color: Color = Tema.tenue, tam: CGFloat = 9.5) {
        self.texto = texto
        self.color = color
        self.tam = tam
    }

    var body: some View {
        Text(texto.uppercased())
            .font(.system(size: tam, weight: .medium))
            .tracking(1.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

enum Tono {
    case ok, aviso, critico, info, neutro

    init(_ n: Nivel?) {
        switch n {
        case .critico: self = .critico
        case .aviso: self = .aviso
        case .info: self = .info
        case nil: self = .ok
        }
    }

    var color: Color {
        switch self {
        case .ok: return Tema.verde
        case .aviso: return Tema.ambar
        case .critico: return Tema.rojo
        case .info: return Tema.cian
        case .neutro: return Tema.tenue
        }
    }
}

/// Pildora de estado: "en orden", "crítico", "expuesto"...
struct Insignia: View {
    let texto: String
    var tono: Tono = .neutro
    var icono: String?

    init(_ texto: String, _ tono: Tono = .neutro, icono: String? = nil) {
        self.texto = texto
        self.tono = tono
        self.icono = icono
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icono { Image(systemName: icono).font(.system(size: 8, weight: .semibold)) }
            Text(texto.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8)
        }
        .foregroundStyle(tono.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tono.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tono.color.opacity(0.35), lineWidth: 1))
        .fixedSize()
    }
}
