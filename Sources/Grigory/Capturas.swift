import AppKit
import SwiftUI

// `Grigory --capturas <carpeta> [claro]`: muestrea unos segundos con datos
// reales y guarda un PNG de cada pagina y del desplegable. La ventana es
// transparente e ignora el raton: no aparece nada en pantalla ni roba el foco.
// Se captura la ventana real (y no ImageRenderer) porque las tablas y la
// helice son vistas de AppKit, que ImageRenderer no dibuja.

enum Capturas {
    @MainActor
    static func ejecutar(en carpeta: String, claro: Bool) {
        let destino = URL(fileURLWithPath: carpeta, isDirectory: true)
        try? FileManager.default.createDirectory(at: destino, withIntermediateDirectories: true)
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = NSAppearance(named: claro ? .aqua : .darkAqua)
        let sufijo = claro ? "-claro" : ""

        let motor = Motor()
        let ui = Interfaz()
        motor.ponerDemanda(.todo)
        for i in 0..<12 {
            let (f, h) = motor.cicloSincrono(visible: true)
            ui.recibir(f, h)
            if i < 11 { esperar(1) }
        }

        let ventana = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1280, height: 860),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        ventana.titlebarAppearsTransparent = true
        ventana.titleVisibility = .hidden
        ventana.isReleasedWhenClosed = false
        ventana.alphaValue = 0
        ventana.ignoresMouseEvents = true
        ventana.contentView = Ventanas.anfitrion(VistaPrincipal(ui: ui))
        ventana.orderFrontRegardless()

        for m in Modulo.allCases {
            ui.seleccion = m
            // En Procesos se elige un proceso de macOS conocido, para ver su ficha.
            if m == .procesos, let p = ui.foto.procesos.first(where: { $0.nombre == "corespotlightd" })
                ?? ui.foto.procesos.first(where: { $0.propio }) {
                ui.procesosElegidos = [p.pid]
            }
            var (f, h) = motor.cicloSincrono(visible: true)
            if m == .bateria {
                // El registro de energia se lee aparte: se espera a que llegue.
                for _ in 0..<20 where f.tramo == nil {
                    esperar(0.5)
                    (f, h) = motor.cicloSincrono(visible: true)
                }
            }
            ui.recibir(f, h)
            esperar(0.7)
            guardar(ventana.contentView!, destino.appendingPathComponent("\(m.rawValue)\(sufijo).png"))
        }
        ventana.orderOut(nil)

        let pop = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 372, height: 420), styleMask: [.borderless],
                           backing: .buffered, defer: false)
        pop.alphaValue = 0
        pop.ignoresMouseEvents = true
        let anfitrion = NSHostingView(rootView: Desplegable(ui: ui, abrir: { _ in }))
        pop.contentView = anfitrion
        pop.setContentSize(anfitrion.fittingSize)
        pop.orderFrontRegardless()
        esperar(0.6)
        guardar(anfitrion, destino.appendingPathComponent("desplegable\(sufijo).png"))
        pop.orderOut(nil)

        for (n, pestana) in [("general", 0), ("ahorro", 1)] {
            let w = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 560, height: 480), styleMask: [.titled],
                             backing: .buffered, defer: false)
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.contentView = Ventanas.anfitrion(VistaConfiguracion(ajustes: ui.ajustes, ahorro: ui.ahorro, inicial: pestana))
            w.orderFrontRegardless()
            esperar(0.6)
            guardar(w.contentView!, destino.appendingPathComponent("configuracion-\(n)\(sufijo).png"))
            w.orderOut(nil)
        }

        let b = BarraMenu(ui: ui)
        b.actualizar(ui.foto)
        print("Capturas en \(destino.path)")
    }

    /// `--medir-ui <pagina> [segundos]`: CPU que gasta dibujar una pagina,
    /// separada de la del motor, en una ventana transparente propia. No depende
    /// de que la ventana real este tapada o no.
    @MainActor
    static func medirUI(_ pagina: Modulo, segundos: Double) {
        NSApp.setActivationPolicy(.accessory)
        let motor = Motor()
        let ui = Interfaz()
        ui.seleccion = pagina
        motor.ponerDemanda(pagina.demanda)
        let ventana = NSWindow(contentRect: NSRect(x: 80, y: 80, width: 1200, height: 800),
                               styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        ventana.titlebarAppearsTransparent = true
        ventana.titleVisibility = .hidden
        ventana.isReleasedWhenClosed = false
        // Casi transparente, por encima de todo y en todos los Spaces: macOS la
        // considera visible y la dibuja de verdad, sin que se note en pantalla.
        ventana.alphaValue = 0.01
        ventana.level = .floating
        ventana.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        ventana.ignoresMouseEvents = true
        ventana.contentView = Ventanas.anfitrion(VistaPrincipal(ui: ui))
        ventana.orderFrontRegardless()
        func cpu() -> Double {
            var r = rusage()
            getrusage(RUSAGE_SELF, &r)
            return Double(r.ru_utime.tv_sec + r.ru_stime.tv_sec) + Double(r.ru_utime.tv_usec + r.ru_stime.tv_usec) / 1e6
        }
        func hilo() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }
        for _ in 0..<6 {
            let (f, h) = motor.cicloSincrono(visible: true)
            ui.recibir(f, h)
            esperar(1)
        }
        let c0 = cpu(), t0 = Sys.reloj()
        var motorCPU = 0.0
        while Sys.reloj() - t0 < segundos {
            let h0 = hilo()
            let (f, h) = motor.cicloSincrono(visible: true)
            motorCPU += hilo() - h0
            ui.recibir(f, h)
            esperar(1)
        }
        let dt = Sys.reloj() - t0
        let total = 100 * (cpu() - c0) / dt
        let mot = 100 * motorCPU / dt
        print("\(pagina.rawValue): total \(Formato.decimal(total, 2)) % · motor \(Formato.decimal(mot, 2)) % · interfaz \(Formato.decimal(total - mot, 2)) %"
              + " · ventana visible: \(ventana.occlusionState.contains(.visible) ? "sí" : "no")")
    }

    private static func esperar(_ s: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(s))
    }

    private static func guardar(_ v: NSView, _ url: URL) {
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
    }
}
