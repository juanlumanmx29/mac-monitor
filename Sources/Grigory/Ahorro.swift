import AppKit
import CoreGraphics

/// Modo ahorro: para una llamada o cualquier rato con batería en que no hace
/// falta toda la potencia del equipo. Al activarlo:
///
///   - activa el modo de bajo consumo de macOS (powermode 1). Exige permiso de
///     administrador: macOS pide Touch ID o la contraseña, sin dejar ningún
///     cambio permanente en el sistema;
///   - baja el brillo de la pantalla integrada al nivel elegido;
///   - la propia app muestrea más lento.
///
/// Al desactivarlo deja todo como estaba: el modo de energía que hubiera en
/// batería y en cargador, y el brillo (salvo que el usuario lo haya movido).
final class Ahorro: ObservableObject {
    @Published private(set) var activo = Preferencias.ahorroActivo
    @Published private(set) var bajoConsumoMacOS = ProcessInfo.processInfo.isLowPowerModeEnabled
    @Published private(set) var aviso: String?
    var alCambiar: ((Bool) -> Void)?

    private typealias LeerBrillo = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
    private typealias FijarBrillo = @convention(c) (UInt32, Float) -> Int32
    private let leerBrillo: LeerBrillo?
    private let fijarBrillo: FijarBrillo?

    init() {
        let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        leerBrillo = h.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: LeerBrillo.self) }
        fijarBrillo = h.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: FijarBrillo.self) }
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.bajoConsumoMacOS = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    var hayBrillo: Bool { leerBrillo != nil && fijarBrillo != nil && pantallaIntegrada != nil }

    func alternar() { activo ? desactivar() : activar() }

    // MARK: - Activar y desactivar

    func activar() {
        guard !activo else { return }
        aviso = nil
        var previo: [String: Any] = [:]

        if Preferencias.ahorroBrillo, let b = brillo() {
            previo["brillo"] = b
            let nivel = Float(Preferencias.ahorroNivelBrillo)
            if b > nivel {
                ponerBrillo(nivel)
                previo["brilloPuesto"] = nivel
            }
        }

        if Preferencias.ahorroBajoConsumo && !ProcessInfo.processInfo.isLowPowerModeEnabled {
            let modos = modosDeEnergia()
            if comoAdministrador("/usr/bin/pmset -a powermode 1") {
                previo["bateria"] = modos.bateria
                previo["cargador"] = modos.cargador
                previo["bajoConsumo"] = true
            } else {
                aviso = "No se activó el modo de bajo consumo de macOS: el permiso se canceló o falló. El resto del modo ahorro sí está activo."
            }
        }

        Preferencias.ahorroPrevio = previo
        Preferencias.ahorroActivo = true
        activo = true
        bajoConsumoMacOS = ProcessInfo.processInfo.isLowPowerModeEnabled
        alCambiar?(true)
    }

    func desactivar() {
        guard activo else { return }
        aviso = nil
        let previo = Preferencias.ahorroPrevio

        // El brillo se devuelve solo si sigue donde lo dejo el modo: si el
        // usuario lo movio despues, manda su eleccion.
        if let antes = previo["brillo"] as? Float ?? (previo["brillo"] as? Double).map(Float.init),
           let puesto = previo["brilloPuesto"] as? Float ?? (previo["brilloPuesto"] as? Double).map(Float.init),
           let ahora = brillo(), abs(ahora - puesto) < 0.04 {
            ponerBrillo(antes)
        }

        if previo["bajoConsumo"] as? Bool == true {
            let b = previo["bateria"] as? Int ?? 0
            let c = previo["cargador"] as? Int ?? 0
            if !comoAdministrador("/usr/bin/pmset -b powermode \(b) && /usr/bin/pmset -c powermode \(c)") {
                aviso = "El modo de bajo consumo de macOS sigue activo: el permiso para desactivarlo se canceló. Puedes quitarlo en Ajustes › Batería."
            }
        }

        Preferencias.ahorroPrevio = [:]
        Preferencias.ahorroActivo = false
        activo = false
        bajoConsumoMacOS = ProcessInfo.processInfo.isLowPowerModeEnabled
        alCambiar?(false)
    }

    // MARK: - Sistema

    /// Modo de energia configurado para bateria y cargador (0 automatico,
    /// 1 bajo consumo, 2 alto rendimiento), segun `pmset -g custom`.
    private func modosDeEnergia() -> (bateria: Int, cargador: Int) {
        var b = 0, c = 0, seccion = ""
        for linea in (Sys.ejecutar("/usr/bin/pmset", ["-g", "custom"]) ?? "").split(separator: "\n") {
            if linea.hasSuffix(":") { seccion = String(linea); continue }
            let partes = linea.split(separator: " ", omittingEmptySubsequences: true)
            guard partes.count == 2, partes[0] == "powermode" || partes[0] == "lowpowermode",
                  let v = Int(partes[1]) else { continue }
            if seccion.hasPrefix("Battery") { b = v } else if seccion.hasPrefix("AC") { c = v }
        }
        return (b, c)
    }

    /// Ejecuta una orden con permiso de administrador: macOS muestra su propio
    /// diálogo (Touch ID o contraseña). Bloquea mientras el diálogo está
    /// abierto; la orden es fija, sin datos de terceros.
    private func comoAdministrador(_ orden: String) -> Bool {
        let fuente = "do shell script \"\(orden)\" with administrator privileges"
        var error: NSDictionary?
        NSApp.activate(ignoringOtherApps: true)
        _ = NSAppleScript(source: fuente)?.executeAndReturnError(&error)
        return error == nil
    }

    private var pantallaIntegrada: CGDirectDisplayID? {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &n) == .success else { return nil }
        return ids.prefix(Int(n)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Brillo de la pantalla integrada, de 0 a 1.
    func brillo() -> Float? {
        guard let id = pantallaIntegrada, let leerBrillo else { return nil }
        var b: Float = 0
        return leerBrillo(id, &b) == 0 ? b : nil
    }

    private func ponerBrillo(_ b: Float) {
        guard let id = pantallaIntegrada, let fijarBrillo else { return }
        _ = fijarBrillo(id, max(0.05, min(1, b)))
    }
}
