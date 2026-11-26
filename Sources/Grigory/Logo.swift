import AppKit

// Icono de la app, dibujado con Core Graphics: un indicador de 270° con la
// paleta del panel y una linea de pulso dentro. `--icono <carpeta>` genera
// el .iconset que construir.sh empaqueta con iconutil.

enum Logo {
    static func generar(en carpeta: String) -> Bool {
        let base = URL(fileURLWithPath: carpeta, isDirectory: true)
        let set = base.appendingPathComponent("Grigory.iconset", isDirectory: true)
        try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
        let tamanos: [(String, Int)] = [
            ("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
            ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512),
            ("512x512", 512), ("512x512@2x", 1024),
        ]
        for (nombre, px) in tamanos {
            guard guardar(px, set.appendingPathComponent("icon_\(nombre).png")) else { return false }
        }
        return guardar(1024, base.appendingPathComponent("logo.png"))
    }

    private static func guardar(_ px: Int, _ url: URL) -> Bool {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        dibujar(ctx.cgContext, CGFloat(px))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    private static func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }

    private static func mezcla(_ a: UInt32, _ b: UInt32, _ t: CGFloat) -> CGColor {
        func c(_ x: UInt32, _ s: UInt32) -> CGFloat { CGFloat((x >> s) & 0xff) / 255 }
        return CGColor(srgbRed: c(a, 16) + (c(b, 16) - c(a, 16)) * t, green: c(a, 8) + (c(b, 8) - c(a, 8)) * t,
                       blue: c(a, 0) + (c(b, 0) - c(a, 0)) * t, alpha: 1)
    }

    static func dibujar(_ g: CGContext, _ s: CGFloat) {
        let chico = s <= 64
        // Rejilla de iconos de macOS: el cuerpo ocupa 824 de 1024.
        let lado = s * 824 / 1024
        let o = (s - lado) / 2
        let cuerpo = CGRect(x: o, y: o + s * 0.008, width: lado, height: lado)
        let radio = lado * 0.2237
        let forma = CGPath(roundedRect: cuerpo, cornerWidth: radio, cornerHeight: radio, transform: nil)

        g.saveGState()
        g.setShadow(offset: CGSize(width: 0, height: -s * 0.01), blur: s * 0.025, color: rgb(0x000000, 0.45))
        g.addPath(forma)
        g.setFillColor(rgb(0x05080d))
        g.fillPath()
        g.restoreGState()

        g.saveGState()
        g.addPath(forma)
        g.clip()
        let fondo = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                               colors: [rgb(0x12243a), rgb(0x05080d)] as CFArray, locations: [0, 1])!
        g.drawLinearGradient(fondo, start: CGPoint(x: 0, y: cuerpo.maxY), end: CGPoint(x: 0, y: cuerpo.minY), options: [])
        if !chico {
            g.setStrokeColor(rgb(0x00d4ff, 0.07))
            g.setLineWidth(max(1, s / 512))
            let paso = lado / 8
            var x = cuerpo.minX + paso
            while x < cuerpo.maxX { g.move(to: CGPoint(x: x, y: cuerpo.minY)); g.addLine(to: CGPoint(x: x, y: cuerpo.maxY)); x += paso }
            var y = cuerpo.minY + paso
            while y < cuerpo.maxY { g.move(to: CGPoint(x: cuerpo.minX, y: y)); g.addLine(to: CGPoint(x: cuerpo.maxX, y: y)); y += paso }
            g.strokePath()
        }
        // Borde interior fino.
        g.addPath(forma)
        g.setStrokeColor(rgb(0x00d4ff, 0.22))
        g.setLineWidth(max(1, s / 256))
        g.strokePath()
        g.restoreGState()

        // Indicador de 270°, abierto por abajo.
        let c = CGPoint(x: s / 2, y: s / 2 - lado * 0.01)
        let r = lado * 0.315
        let grosor = lado * (chico ? 0.11 : 0.082)
        let inicio = CGFloat.pi * 1.25
        let barrido = CGFloat.pi * 1.5
        g.setLineCap(.round)
        g.setLineWidth(grosor)
        g.setStrokeColor(rgb(0x1b2a3a))
        g.addArc(center: c, radius: r, startAngle: inicio, endAngle: inicio - barrido, clockwise: true)
        g.strokePath()

        // Valor al 72 %: degradado del verde al cian por tramos cortos.
        let valor: CGFloat = 0.72
        let pasos = 90
        g.setLineCap(.butt)
        for i in 0..<pasos {
            let t0 = CGFloat(i) / CGFloat(pasos) * valor
            let t1 = CGFloat(i + 1) / CGFloat(pasos) * valor + 0.002
            g.setStrokeColor(mezcla(0x00e08a, 0x00d4ff, t0 / valor))
            g.addArc(center: c, radius: r, startAngle: inicio - barrido * t0, endAngle: inicio - barrido * t1, clockwise: true)
            g.strokePath()
        }
        func punta(_ t: CGFloat, _ color: CGColor) {
            let a = inicio - barrido * t
            let p = CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r)
            g.setFillColor(color)
            g.fillEllipse(in: CGRect(x: p.x - grosor / 2, y: p.y - grosor / 2, width: grosor, height: grosor))
        }
        punta(0, rgb(0x00e08a))
        punta(valor, rgb(0x00d4ff))

        // Pulso dentro del indicador.
        let ancho = r * 1.5
        let x0 = c.x - ancho / 2
        let pts: [(CGFloat, CGFloat)] = [(0, 0), (0.28, 0), (0.36, 0.12), (0.44, -0.06), (0.52, 0.62),
                                         (0.60, -0.42), (0.68, 0.05), (0.74, 0), (1, 0)]
        let alto = r * 0.62
        let linea = CGMutablePath()
        for (i, p) in pts.enumerated() {
            let q = CGPoint(x: x0 + p.0 * ancho, y: c.y + p.1 * alto)
            if i == 0 { linea.move(to: q) } else { linea.addLine(to: q) }
        }
        g.saveGState()
        g.setLineCap(.round)
        g.setLineJoin(.round)
        g.setLineWidth(lado * (chico ? 0.06 : 0.034))
        if !chico { g.setShadow(offset: .zero, blur: s * 0.03, color: rgb(0x00d4ff, 0.8)) }
        g.setStrokeColor(rgb(0xe6fbff))
        g.addPath(linea)
        g.strokePath()
        g.restoreGState()
    }
}
