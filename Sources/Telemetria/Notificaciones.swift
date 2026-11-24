import Foundation
import UserNotifications

/// Notificaciones del sistema para lo critico, una vez por proceso.
///
/// Desde el .app se usan las notificaciones propias de la app (pulsarlas abre
/// la Vigilancia). Si se ejecuta el binario suelto, o si el usuario las
/// denego, se cae a osascript: los textos viajan como argumentos y nunca
/// dentro del codigo AppleScript, asi que un nombre de proceso no puede
/// inyectar instrucciones.
final class Notificador: NSObject, UNUserNotificationCenterDelegate {
    var alPulsar: (() -> Void)?
    private var autorizado = false

    private var desdeApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    func preparar() {
        guard desdeApp else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in
            DispatchQueue.main.async { self.autorizado = ok }
        }
    }

    func avisar(_ a: Alerta) {
        guard Preferencias.notificaciones else { return }
        let cpu = a.cpuSostenida.map { "\(Int($0.rounded()))% CPU sostenido · " } ?? ""
        let texto = "\(a.etiqueta) (pid \(a.pid)) · \(cpu)vivo hace \(Formato.lapso(a.vida))"
        if desdeApp && autorizado {
            let c = UNMutableNotificationContent()
            c.title = "Telemetría"
            c.subtitle = a.titulo
            c.body = texto
            c.sound = .default
            c.userInfo = ["alerta": a.id]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: a.id, content: c, trigger: nil))
            return
        }
        let args = ["-e", "on run argv",
                    "-e", "display notification (item 1 of argv) with title (item 2 of argv) subtitle (item 3 of argv)",
                    "-e", "end run", texto, "Telemetría", a.titulo]
        // Con espera, en otro hilo: un proceso lanzado y no recogido quedaria
        // como zombi de la propia app, y la vigilancia lo detectaria.
        DispatchQueue.global(qos: .utility).async { _ = Sys.ejecutar("/usr/bin/osascript", args, limite: 15) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.alPulsar?() }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
