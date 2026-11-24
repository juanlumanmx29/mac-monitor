import AppKit
import SwiftUI

/// La ventana del panel. Al cerrarla se destruye entera (vista de SwiftUI
/// incluida): con la ventana cerrada no queda nada que dibujar ni que
/// actualizar, y la app vuelve a ser solo un icono en la barra de menu.
final class ControladorVentana: NSObject, NSWindowDelegate {
    private var ventana: NSWindow?
    private let ui: Interfaz
    var alCambiarVisibilidad: (() -> Void)?

    init(ui: Interfaz) {
        self.ui = ui
    }

    var visible: Bool {
        guard let w = ventana else { return false }
        return w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
    }

    var abierta: Bool { ventana != nil }

    func mostrar(_ modulo: Modulo? = nil) {
        if let modulo { ui.seleccion = modulo }
        if ventana == nil { crear() }
        NSApp.setActivationPolicy(.regular)
        ventana?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        alCambiarVisibilidad?()
    }

    func cerrar() { ventana?.performClose(nil) }

    private func crear() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Telemetría"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.minSize = NSSize(width: 940, height: 620)
        w.isReleasedWhenClosed = false
        w.backgroundColor = Tema.nsDinamico(0x05080d, 0xeef1f6)
        w.contentView = NSHostingView(rootView: VistaPrincipal(ui: ui))
        if !w.setFrameUsingName("Principal") { w.center() }
        w.setFrameAutosaveName("Principal")
        w.delegate = self
        ventana = w
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        ventana?.delegate = nil
        let w = ventana
        ventana = nil
        // Se suelta la vista en la vuelta siguiente: AppKit aun la usa durante
        // el cierre.
        DispatchQueue.main.async {
            w?.contentView = nil
            NSApp.setActivationPolicy(.accessory)
            self.alCambiarVisibilidad?()
        }
    }

    func windowDidMiniaturize(_ notification: Notification) { alCambiarVisibilidad?() }
    func windowDidDeminiaturize(_ notification: Notification) { alCambiarVisibilidad?() }
    func windowDidChangeOcclusionState(_ notification: Notification) { alCambiarVisibilidad?() }
}

/// Menu principal: el de cualquier app de macOS, mas Ver con los atajos de
/// cada modulo. Edicion hace falta para que el buscador acepte ⌘C y ⌘V.
final class Menus: NSObject {
    private let ui: Interfaz
    private let mostrar: (Modulo?) -> Void

    init(ui: Interfaz, mostrar: @escaping (Modulo?) -> Void) {
        self.ui = ui
        self.mostrar = mostrar
    }

    func construir() -> NSMenu {
        let principal = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "Acerca de Telemetría", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Ocultar Telemetría", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let otras = app.addItem(withTitle: "Ocultar otras", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        otras.keyEquivalentModifierMask = [.command, .option]
        app.addItem(.separator())
        app.addItem(withTitle: "Salir de Telemetría", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        principal.addItem(submenu(app, "Telemetría"))

        let edicion = NSMenu(title: "Edición")
        edicion.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edicion.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edicion.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edicion.addItem(withTitle: "Seleccionar todo", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        principal.addItem(submenu(edicion, "Edición"))

        let ver = NSMenu(title: "Ver")
        ver.addItem(item("Resumen", #selector(irA(_:)), "0", Modulo.resumen))
        for (i, m) in Modulo.numerados.enumerated() {
            ver.addItem(item(m.titulo, #selector(irA(_:)), "\(i + 1)", m))
        }
        for m in [Modulo.procesos, .energia, .puertos, .reposo] {
            ver.addItem(item(m.titulo, #selector(irA(_:)), "", m))
        }
        let alertas = item("Vigilancia", #selector(irA(_:)), "a", Modulo.vigilancia)
        alertas.keyEquivalentModifierMask = [.command, .shift]
        ver.addItem(alertas)
        ver.addItem(.separator())
        let buscar = item("Buscar proceso", #selector(buscarProceso(_:)), "f", nil)
        ver.addItem(buscar)
        let pausa = item("Pausar o reanudar", #selector(pausar(_:)), "p", nil)
        pausa.keyEquivalentModifierMask = [.command, .shift]
        ver.addItem(pausa)
        let apariencia = NSMenu(title: "Apariencia")
        for (i, n) in ["Como el sistema", "Oscura", "Clara"].enumerated() {
            let it = item(n, #selector(ponerApariencia(_:)), "", nil)
            it.tag = i
            apariencia.addItem(it)
        }
        ver.addItem(.separator())
        ver.addItem(submenu(apariencia, "Apariencia"))
        principal.addItem(submenu(ver, "Ver"))

        let ventana = NSMenu(title: "Ventana")
        ventana.addItem(withTitle: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        ventana.addItem(withTitle: "Cerrar", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        principal.addItem(submenu(ventana, "Ventana"))
        NSApp.windowsMenu = ventana
        return principal
    }

    private func submenu(_ m: NSMenu, _ titulo: String) -> NSMenuItem {
        let it = NSMenuItem(title: titulo, action: nil, keyEquivalent: "")
        m.title = titulo
        it.submenu = m
        return it
    }

    private func item(_ titulo: String, _ accion: Selector, _ tecla: String, _ modulo: Modulo?) -> NSMenuItem {
        let it = NSMenuItem(title: titulo, action: accion, keyEquivalent: tecla)
        it.target = self
        it.representedObject = modulo?.rawValue
        return it
    }

    @objc private func irA(_ s: NSMenuItem) {
        guard let r = s.representedObject as? String, let m = Modulo(rawValue: r) else { return }
        mostrar(m)
    }

    @objc private func buscarProceso(_ s: NSMenuItem) {
        mostrar(.procesos)
    }

    @objc private func pausar(_ s: NSMenuItem) { ui.pausado.toggle() }

    @objc private func ponerApariencia(_ s: NSMenuItem) {
        Preferencias.apariencia = s.tag
        Menus.aplicarApariencia()
    }

    static func aplicarApariencia() {
        switch Preferencias.apariencia {
        case 1: NSApp.appearance = NSAppearance(named: .darkAqua)
        case 2: NSApp.appearance = NSAppearance(named: .aqua)
        default: NSApp.appearance = nil
        }
    }
}

extension Menus: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(ponerApariencia(_:)) {
            item.state = item.tag == Preferencias.apariencia ? .on : .off
        }
        if item.action == #selector(irA(_:)) {
            item.state = item.representedObject as? String == ui.seleccion?.rawValue ? .on : .off
        }
        return true
    }
}
