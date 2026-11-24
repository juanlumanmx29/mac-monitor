import AppKit
import SwiftUI

/// Icono y cifras en la barra de menu. Clic: desplegable con el resumen.
/// Clic derecho: menu con las opciones. El titulo se arma con AppKit, sin
/// SwiftUI: con la ventana cerrada es lo unico que se actualiza (cada 5 s).
final class BarraMenu: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let ui: Interfaz
    private var ultimoTitulo = ""
    var alCambiarVisibilidad: (() -> Void)?
    var alAbrirVentana: ((Modulo?) -> Void)?

    private(set) var abierto = false

    init(ui: Interfaz) {
        self.ui = ui
        super.init()
        if let b = item.button {
            let img = NSImage(systemSymbolName: "waveform.path.ecg", accessibilityDescription: "Telemetría")
            img?.isTemplate = true
            b.image = img
            b.imagePosition = .imageLeading
            b.target = self
            b.action = #selector(pulsar(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "Telemetría"
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: Desplegable(ui: ui, abrir: { [weak self] m in
            self?.popover.performClose(nil)
            self?.alAbrirVentana?(m)
        }))
    }

    @objc private func pulsar(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(nil)
            item.menu = menu()
            item.button?.performClick(nil)
            item.menu = nil
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverDidShow(_ notification: Notification) {
        abierto = true
        alCambiarVisibilidad?()
    }

    func popoverDidClose(_ notification: Notification) {
        abierto = false
        alCambiarVisibilidad?()
    }

    // MARK: - Titulo

    func actualizar(_ f: Foto) {
        var partes: [String] = []
        if Preferencias.barra(.cpu) { partes.append("\(Int(f.cpu.total.rounded()))%") }
        if Preferencias.barra(.temperatura) {
            // En la barra, la temperatura de la CPU: la maxima de todas las
            // familias suele ser la de los reguladores, que siempre van calientes.
            let cpu = f.temperaturas.filter { $0.id == "Tp" || $0.id == "Te" }.compactMap(\.max).max() ?? f.tempMax
            if let t = cpu { partes.append("\(Int(t.rounded()))°") }
        }
        if Preferencias.barra(.memoria), let m = f.memoria { partes.append("\(Int(m.pct.rounded()))% mem") }
        if Preferencias.barra(.potencia), let w = f.vatios { partes.append(Formato.decimal(w, w < 10 ? 1 : 0) + " W") }
        if Preferencias.barra(.red) {
            let (v, u) = Formato.tasaPartes(f.red.entrada + f.red.salida)
            partes.append("\(v) \(u.replacingOccurrences(of: "/s", with: ""))")
        }
        let alertas = f.activas.count
        let texto = partes.joined(separator: "  ")
        let clave = "\(texto)|\(alertas)|\(f.peorNivel?.rawValue ?? -1)"
        guard clave != ultimoTitulo, let b = item.button else { return }
        ultimoTitulo = clave

        let fuente = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let titulo = NSMutableAttributedString()
        if alertas > 0 {
            let color = f.peorNivel == .critico ? Tema.nsRojo : f.peorNivel == .aviso ? Tema.nsAmbar : Tema.nsCian
            titulo.append(NSAttributedString(string: " ●\(alertas)", attributes: [.font: fuente, .foregroundColor: color]))
        }
        if !texto.isEmpty {
            titulo.append(NSAttributedString(string: " " + texto, attributes: [.font: fuente]))
        }
        b.attributedTitle = titulo
        b.toolTip = alertas > 0 ? "Telemetría · \(alertas) alerta\(alertas == 1 ? "" : "s")" : "Telemetría"
    }

    // MARK: - Menu

    private func menu() -> NSMenu {
        let m = NSMenu()
        m.addItem(accion("Abrir panel", #selector(abrirPanel)))
        m.addItem(.separator())
        let barra = NSMenu()
        for metrica in MetricaBarra.allCases {
            let it = accion(metrica.nombre, #selector(alternarMetrica(_:)))
            it.representedObject = metrica.rawValue
            it.state = Preferencias.barra(metrica) ? .on : .off
            barra.addItem(it)
        }
        let sub = NSMenuItem(title: "Mostrar en la barra", action: nil, keyEquivalent: "")
        sub.submenu = barra
        m.addItem(sub)
        let notif = accion("Notificar alertas críticas", #selector(alternarNotificaciones))
        notif.state = Preferencias.notificaciones ? .on : .off
        m.addItem(notif)
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Salir de Telemetría", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return m
    }

    private func accion(_ titulo: String, _ sel: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: titulo, action: sel, keyEquivalent: "")
        it.target = self
        return it
    }

    @objc private func abrirPanel() { alAbrirVentana?(nil) }

    @objc private func alternarMetrica(_ s: NSMenuItem) {
        guard let r = s.representedObject as? String, let m = MetricaBarra(rawValue: r) else { return }
        Preferencias.ponerBarra(m, !Preferencias.barra(m))
        ultimoTitulo = ""
        actualizar(ui.foto)
    }

    @objc private func alternarNotificaciones() { Preferencias.notificaciones.toggle() }
}

/// Contenido del desplegable: seis cifras con su ultimo minuto, las alertas y
/// acceso al panel.
struct Desplegable: View {
    @ObservedObject var ui: Interfaz
    let abrir: (Modulo?) -> Void

    var body: some View {
        let f = ui.foto
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").foregroundStyle(Tema.cian)
                Text("TELEMETRÍA").font(.system(size: 11, weight: .semibold)).tracking(2).foregroundStyle(Tema.texto)
                Text(ui.equipo.chipCorto).font(Tema.numero(10)).foregroundStyle(Tema.tenue)
                Spacer()
                Text("T+ " + Formato.reloj(ui.actividad)).font(Tema.numero(10)).foregroundStyle(Tema.cian)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach([Modulo.cpu, .gpu, .memoria, .termico, .consumo, .red]) { m in
                    Mini(modulo: m, r: ui.resumen(m), ahora: ui.ahora) { abrir(m) }
                }
            }
            if !f.activas.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Rotulo("alertas · \(f.activas.count)", color: Tema.color(f.peorNivel))
                    ForEach(f.activas.prefix(4)) { a in
                        Button { ui.verAlerta(a); abrir(.vigilancia) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Tema.color(a.nivel)).frame(width: 6, height: 6)
                                Text(a.titulo).font(.system(size: 11)).foregroundStyle(Tema.texto)
                                Text(a.etiqueta).font(.system(size: 11)).foregroundStyle(Tema.tenue).lineLimit(1)
                                Spacer(minLength: 0)
                                Text(valorAlerta(a).0 + valorAlerta(a).1).font(Tema.numero(10.5)).foregroundStyle(Tema.color(a.nivel))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(10)
                .background(Tema.panel, in: RoundedRectangle(cornerRadius: 8))
            }
            HStack {
                Button("Abrir panel") { abrir(nil) }.keyboardShortcut(.defaultAction)
                Spacer()
                Text("\(f.tabla.count) procesos · \(f.activas.isEmpty ? "sin alertas" : "\(f.activas.count) alertas")")
                    .font(.system(size: 10)).foregroundStyle(Tema.tenue)
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 372)
        .background(Tema.fondo)
    }

    private struct Mini: View {
        let modulo: Modulo
        let r: Resumen
        let ahora: Double
        let accion: () -> Void

        var body: some View {
            Button(action: accion) {
                VStack(alignment: .leading, spacing: 2) {
                    Rotulo(modulo.titulo, tam: 8.5)
                    Cifra(valor: r.valor, unidad: r.unidad.trimmingCharacters(in: .whitespaces), color: r.color, tam: 19)
                    Grafico(trazos: r.trazos, ventana: 60, escala: r.escala, ahora: ahora, punto: false)
                        .frame(height: 20)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .resaltable()
        }
    }
}
