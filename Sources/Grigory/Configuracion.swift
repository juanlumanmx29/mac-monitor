import AppKit
import SwiftUI

/// Ajustes editables desde la ventana de configuración. Cada cambio se guarda
/// al momento en las preferencias y avisa a quien deba reaccionar.
final class Ajustes: ObservableObject {
    @Published var apariencia = Preferencias.apariencia {
        didSet {
            Preferencias.apariencia = apariencia
            Menus.aplicarApariencia()
        }
    }
    @Published var notificaciones = Preferencias.notificaciones {
        didSet { Preferencias.notificaciones = notificaciones }
    }
    @Published var barra: [MetricaBarra: Bool] = Dictionary(uniqueKeysWithValues: MetricaBarra.allCases.map { ($0, Preferencias.barra($0)) }) {
        didSet {
            for (m, v) in barra { Preferencias.ponerBarra(m, v) }
            alCambiarBarra?()
        }
    }
    @Published var ahorroBajoConsumo = Preferencias.ahorroBajoConsumo {
        didSet { Preferencias.ahorroBajoConsumo = ahorroBajoConsumo }
    }
    @Published var ahorroBrillo = Preferencias.ahorroBrillo {
        didSet { Preferencias.ahorroBrillo = ahorroBrillo }
    }
    @Published var ahorroNivelBrillo = Preferencias.ahorroNivelBrillo {
        didSet { Preferencias.ahorroNivelBrillo = ahorroNivelBrillo }
    }
    @Published private(set) var silenciadas = Preferencias.silenciadas.sorted()

    var alCambiarBarra: (() -> Void)?

    func barraBinding(_ m: MetricaBarra) -> Binding<Bool> {
        Binding(get: { self.barra[m] ?? false }, set: { self.barra[m] = $0 })
    }

    func reactivar(_ firma: String) {
        var s = Preferencias.silenciadas
        s.remove(firma)
        Preferencias.silenciadas = s
        silenciadas = s.sorted()
    }

    func releer() {
        silenciadas = Preferencias.silenciadas.sorted()
        barra = Dictionary(uniqueKeysWithValues: MetricaBarra.allCases.map { ($0, Preferencias.barra($0)) })
        notificaciones = Preferencias.notificaciones
    }
}

final class ControladorConfiguracion: NSObject, NSWindowDelegate {
    private var ventana: NSWindow?
    private let ajustes: Ajustes
    private let ahorro: Ahorro

    init(ajustes: Ajustes, ahorro: Ahorro) {
        self.ajustes = ajustes
        self.ahorro = ahorro
    }

    func mostrar(pestana: Int = 0) {
        ajustes.releer()
        if ventana == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Configuración de Grigory"
            w.isReleasedWhenClosed = false
            w.contentView = Ventanas.anfitrion(VistaConfiguracion(ajustes: ajustes, ahorro: ahorro, inicial: pestana))
            w.center()
            w.delegate = self
            ventana = w
        }
        NSApp.setActivationPolicy(.regular)
        ventana?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        let w = ventana
        ventana = nil
        DispatchQueue.main.async {
            w?.contentView = nil
            // Si no queda ninguna ventana a la vista, vuelve a ser solo barra de menu.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.styleMask.contains(.titled) }) {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

struct VistaConfiguracion: View {
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var ahorro: Ahorro
    private let pestana: State<Int>

    init(ajustes: Ajustes, ahorro: Ahorro, inicial: Int) {
        self.ajustes = ajustes
        self.ahorro = ahorro
        pestana = State(initialValue: inicial)
    }

    var body: some View {
        TabView(selection: pestana.projectedValue) {
            general.tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            AjustesAhorro(ajustes: ajustes, ahorro: ahorro).tabItem { Label("Modo ahorro", systemImage: "leaf") }.tag(1)
            vigilancia.tabItem { Label("Vigilancia", systemImage: "eye") }.tag(2)
            acerca.tabItem { Label("Acerca de", systemImage: "info.circle") }.tag(3)
        }
        .frame(width: 560, height: 480)
    }

    private var general: some View {
        Form {
            Section("Apariencia") {
                Picker("Tema", selection: $ajustes.apariencia) {
                    Text("Como el sistema").tag(0)
                    Text("Oscuro").tag(1)
                    Text("Claro").tag(2)
                }
                .pickerStyle(.segmented)
            }
            Section("Barra de menú") {
                ForEach(MetricaBarra.allCases, id: \.self) { m in
                    Toggle(m.nombre, isOn: ajustes.barraBinding(m))
                }
            }
            Section("Notificaciones") {
                Toggle("Avisar de las alertas críticas", isOn: $ajustes.notificaciones)
                Text("Una notificación por proceso: olvidados que consumen CPU de forma sostenida.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var vigilancia: some View {
        Form {
            Section("Alertas silenciadas") {
                if ajustes.silenciadas.isEmpty {
                    Text("Ninguna. Para silenciar un programa, usa «Silenciar» en su alerta.").foregroundStyle(.secondary)
                }
                ForEach(ajustes.silenciadas, id: \.self) { firma in
                    HStack {
                        Text(firma.replacingOccurrences(of: ":", with: " · ", options: [], range: firma.range(of: ":")))
                            .font(.system(size: 11, design: .monospaced)).lineLimit(2)
                        Spacer()
                        Button("Reactivar") { ajustes.reactivar(firma) }
                    }
                }
            }
            Section("Reglas") {
                Text("Olvidado: proceso tuyo sin terminal, app ni launchd que lo mantenga. Crítico con \(Int(Reglas.umbralOlvidado)) % de CPU durante \(Formato.lapso(Reglas.ventanaOlvidado)).")
                Text("Desbocado: \(Int(Reglas.umbralDesbocado)) % de un núcleo durante \(Formato.lapso(Reglas.ventanaDesbocado)).")
                Text("Suspendido: detenido más de \(Formato.lapso(Reglas.minDetenido)). Reposo: impide dormir más de \(Formato.lapso(Reglas.minReposo)) con batería.")
            }
            .font(.system(size: 12))
        }
        .formStyle(.grouped)
    }

    private var acerca: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Grigory").font(.system(size: 22, weight: .semibold))
            Text("Versión \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")")
                .foregroundStyle(.secondary)
            Text("Del griego Grēgórios: «el que vigila, el que está en vela».")
                .italic().foregroundStyle(.secondary)
            Text("Monitor del sistema nativo para macOS. Sin servidor, sin sudo y sin dependencias.")
                .multilineTextAlignment(.center)
            Link("github.com/juanlumanmx29/grigory", destination: URL(string: "https://github.com/juanlumanmx29/grigory")!)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Estado del modo ahorro con su botón. Se usa en la ventana de
/// configuración y en la página de Batería.
struct PanelAhorro: View {
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var ahorro: Ahorro
    var compacto = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: ahorro.activo ? "leaf.fill" : "leaf")
                    .font(.system(size: 22)).foregroundStyle(ahorro.activo ? Tema.verde : Tema.tenue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ahorro.activo ? "Modo ahorro activo" : "Modo ahorro").font(.system(size: 14, weight: .semibold))
                    Text(estado).font(.system(size: 11.5)).foregroundStyle(Tema.tenue)
                }
                Spacer()
                Button(ahorro.activo ? "Desactivar" : "Activar") { ahorro.alternar() }
                    .controlSize(.large)
                    .keyboardShortcut(compacto ? nil : .defaultAction)
            }
            if let aviso = ahorro.aviso {
                Label(aviso, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Tema.ambar)
            }
        }
    }

    private var estado: String {
        var partes: [String] = []
        partes.append(ahorro.bajoConsumoMacOS ? "bajo consumo de macOS activo" : "bajo consumo de macOS apagado")
        if let b = ahorro.brillo() { partes.append("brillo \(Int((b * 100).rounded())) %") }
        return partes.joined(separator: " · ")
    }
}

/// Pestaña de configuración del modo ahorro.
struct AjustesAhorro: View {
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var ahorro: Ahorro

    var body: some View {
        Form {
            Section {
                PanelAhorro(ajustes: ajustes, ahorro: ahorro).padding(.vertical, 4)
            }
            Section("Al activarlo") {
                Toggle("Activar el modo de bajo consumo de macOS", isOn: $ajustes.ahorroBajoConsumo)
                Text("Baja los relojes del chip y la actividad de fondo. macOS pide Touch ID o tu contraseña al activarlo y al desactivarlo; no queda ningún cambio permanente.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Bajar el brillo de la pantalla", isOn: $ajustes.ahorroBrillo).disabled(!ahorro.hayBrillo)
                HStack {
                    Slider(value: $ajustes.ahorroNivelBrillo, in: 0.2...0.8, step: 0.05) { Text("Brillo") }
                    Text("\(Int((ajustes.ahorroNivelBrillo * 100).rounded())) %").monospacedDigit().frame(width: 44)
                }
                .disabled(!ajustes.ahorroBrillo || !ahorro.hayBrillo)
                Text("Al salir del modo se devuelve el brillo anterior, salvo que lo hayas cambiado tú mientras tanto. Grigory, además, refresca cada 3 s y deja de medir el impacto energético.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Ciclos de la batería") {
                Text("Un ciclo se cuenta al acumular el 100 % de descarga. El modo ahorro reduce el consumo, pero la única forma de no gastar ciclos es usar el cargador: en una llamada larga, si puedes, enchufa. Mantener la carga en 80 % con el cargador, como ya haces, es lo que más alarga la vida de la batería.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
