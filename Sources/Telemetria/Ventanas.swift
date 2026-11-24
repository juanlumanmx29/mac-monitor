import AppKit

/// La app con ventanas de la que depende un proceso, para traerla al frente.
///
/// Un proceso suelto (node, zsh, un Code Helper, un WebContent de Safari) no
/// tiene ventanas propias: las tiene la app responsable de el. Se pregunta
/// primero al kernel quien es el responsable (la misma funcion que usa el
/// Monitor de Actividad, privada, enlazada en ejecucion) y, si no responde,
/// se sube por los padres hasta dar con una app normal.
enum Ventanas {
    private typealias Responsable = @convention(c) (Int32) -> Int32
    private static let responsable: Responsable? = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                                                         "responsibility_get_pid_responsible_for_pid")
        .map { unsafeBitCast($0, to: Responsable.self) }

    static func app(de pid: Int32, tabla: [Int32: Proceso]) -> NSRunningApplication? {
        func conVentanas(_ p: Int32) -> NSRunningApplication? {
            guard p > 1, p != getpid(), let a = NSRunningApplication(processIdentifier: p),
                  a.activationPolicy == .regular else { return nil }
            return a
        }
        if let a = conVentanas(pid) { return a }
        if let r = responsable?(pid), r != pid, let a = conVentanas(r) { return a }
        var actual = tabla[pid]?.ppid ?? 0
        var pasos = 0
        while actual > 1 && pasos < 32 {
            if let a = conVentanas(actual) { return a }
            actual = tabla[actual]?.ppid ?? 0
            pasos += 1
        }
        return nil
    }

    /// Trae al frente las ventanas de la app. Devuelve false si no hay ninguna.
    @discardableResult
    static func traer(_ app: NSRunningApplication) -> Bool {
        if app.isHidden { app.unhide() }
        NSApp.yieldActivation(to: app)
        return app.activate(from: NSRunningApplication.current, options: [.activateAllWindows])
    }
}
