import AppKit

// Modos sin interfaz, para diagnostico y construccion.
let argumentos = CommandLine.arguments
if argumentos.contains("--volcar") {
    Volcado.ejecutar()
    exit(0)
}
if let i = argumentos.firstIndex(of: "--medir") {
    let segundos = i + 1 < argumentos.count ? Double(argumentos[i + 1]) ?? 30 : 30
    Volcado.medir(segundos: segundos, visible: !argumentos.contains("fondo"))
    exit(0)
}
if let i = argumentos.firstIndex(of: "--smc"), i + 1 < argumentos.count {
    let smc = SMC()
    while !smc.listo { Thread.sleep(forTimeInterval: 0.1) }
    for (k, v) in smc.listar(prefijo: argumentos[i + 1]) {
        print(k, v.map { Formato.decimal($0, 3) } ?? "—")
    }
    exit(0)
}
if let i = argumentos.firstIndex(of: "--icono"), i + 1 < argumentos.count {
    exit(Logo.generar(en: argumentos[i + 1]) ? 0 : 1)
}
if let i = argumentos.firstIndex(of: "--capturas"), i + 1 < argumentos.count {
    _ = NSApplication.shared
    MainActor.assumeIsolated { Capturas.ejecutar(en: argumentos[i + 1], claro: argumentos.contains("claro")) }
    exit(0)
}

if let i = argumentos.firstIndex(of: "--medir-ui"), i + 1 < argumentos.count, let m = Modulo(rawValue: argumentos[i + 1]) {
    _ = NSApplication.shared
    let segundos = i + 2 < argumentos.count ? Double(argumentos[i + 2]) ?? 20 : 20
    MainActor.assumeIsolated { Capturas.medirUI(m, segundos: segundos) }
    exit(0)
}

private let avisoMostrar = Notification.Name("local.grigory.mostrar")

final class Delegado: NSObject, NSApplicationDelegate {
    private let motor = Motor()
    private let ui = Interfaz()
    private let notificador = Notificador()
    private var ventana: ControladorVentana!
    private var barra: BarraMenu!
    private var menus: Menus!
    private var configuracion: ControladorConfiguracion!

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Una sola instancia: si ya hay otra, se le pide que muestre su ventana.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            DistributedNotificationCenter.default().postNotificationName(avisoMostrar, object: nil, userInfo: nil,
                                                                         deliverImmediately: true)
            NSApp.terminate(nil)
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: avisoMostrar, object: nil, queue: .main) { [weak self] _ in
            self?.ventana.mostrar(nil)
        }

        migrarPreferencias()
        Menus.aplicarApariencia()
        ventana = ControladorVentana(ui: ui)
        barra = BarraMenu(ui: ui)
        configuracion = ControladorConfiguracion(ajustes: ui.ajustes, ahorro: ui.ahorro)
        menus = Menus(ui: ui) { [weak self] m in self?.ventana.mostrar(m) }
        NSApp.mainMenu = menus.construir()
        ui.alAbrirConfiguracion = { [weak self] p in self?.configuracion.mostrar(pestana: p) }
        ui.ahorro.alCambiar = { [weak self] activo in
            guard let self else { return }
            self.motor.ponerAhorro(activo)
            self.barra.refrescar(self.ui.foto)
        }
        ui.ajustes.alCambiarBarra = { [weak self] in
            guard let self else { return }
            self.barra.refrescar(self.ui.foto)
        }
        motor.ponerAhorro(ui.ahorro.activo)

        ventana.alCambiarVisibilidad = { [weak self] in self?.visibilidad() }
        barra.alCambiarVisibilidad = { [weak self] in self?.visibilidad() }
        barra.alAbrirVentana = { [weak self] m in self?.ventana.mostrar(m) }
        ui.alCambiarDemanda = { [weak self] _ in self?.visibilidad() }
        ui.alPausar = { [weak self] p in self?.motor.pausar(p) }
        motor.alPublicar = { [weak self] f, h in
            self?.ui.recibir(f, h)
            self?.barra.actualizar(f)
        }
        motor.alAlertaCritica = { [weak self] a in self?.notificador.avisar(a) }
        notificador.alPulsar = { [weak self] in self?.ventana.mostrar(.vigilancia) }
        notificador.preparar()

        visibilidad()
        motor.iniciar()
        // Al iniciar sesion (LaunchAgent) arranca solo en la barra de menu.
        // --pagina <modulo> abre la ventana directamente en un detalle.
        if let i = argumentos.firstIndex(of: "--pagina"), i + 1 < argumentos.count,
           let m = Modulo(rawValue: argumentos[i + 1]) {
            ventana.mostrar(m)
        } else if !argumentos.contains("--fondo") {
            ventana.mostrar(nil)
        }
    }

    /// El motor trabaja a 1 s solo si algo esta a la vista, y la pagina abierta
    /// decide si hace falta lo caro (ps de ajenos, puertos, energia).
    private func visibilidad() {
        let vista = ventana.visible
        motor.ponerVisible(vista || barra.abierto)
        motor.ponerDemanda(vista ? (ui.seleccion ?? .resumen).demanda : Demanda())
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ventana.mostrar(nil)
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Preferencias de cuando la app se llamaba Telemetría (local.telemetria):
/// alertas silenciadas, tema, barra de menú, modo ahorro y caché del SMC.
private func migrarPreferencias() {
    let d = UserDefaults.standard
    guard !d.bool(forKey: "migradoDeTelemetria") else { return }
    d.set(true, forKey: "migradoDeTelemetria")
    guard let viejo = d.persistentDomain(forName: "local.telemetria") else { return }
    let prefijos = ["silenciadas", "notificaciones", "apariencia", "barra.", "ahorro.", "smc.claves."]
    for (k, v) in viejo where prefijos.contains(where: { k.hasPrefix($0) }) && d.object(forKey: k) == nil {
        d.set(v, forKey: k)
    }
}

let app = NSApplication.shared
let delegado = Delegado()
app.delegate = delegado
app.setActivationPolicy(.accessory)
app.run()
