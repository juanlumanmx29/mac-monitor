import AppKit

/// Que es un proceso y que pasa si se termina. Responde a la pregunta que
/// hace cualquier alerta sobre un proceso del sistema: «¿qué es esto?».
///
/// Solo programas genericos de macOS: nada propio de un equipo concreto.
/// Lo que no esta en el catalogo se describe por su ruta (proceso del
/// sistema) o por la app de la que depende (proceso auxiliar).
struct Descripcion {
    enum Riesgo {
        /// Terminarlo es seguro y tiene efecto.
        case normal
        /// launchd lo vuelve a lanzar: terminarlo no suele servir de nada.
        case relanza
        /// Terminarlo cierra la sesion, cuelga el equipo o no es posible.
        case peligroso
    }

    let texto: String
    let riesgo: Riesgo
    /// Rotulo corto: "macOS" o el nombre de la app de la que depende.
    let origen: String

    var consecuencia: String? {
        switch riesgo {
        case .normal: return nil
        case .relanza: return "Terminarlo no suele servir de nada: el sistema lo vuelve a lanzar enseguida."
        case .peligroso: return "No lo termines."
        }
    }
}

enum Conocidos {
    private typealias Entrada = (texto: String, riesgo: Descripcion.Riesgo)

    private static let porNombre: [String: Entrada] = [
        // Spotlight
        "corespotlightd": ("Spotlight del contenido de las apps: indexa correos, mensajes, notas, el historial de Safari y lo que publiquen otras apps para que aparezca en las búsquedas. Tiene ráfagas largas tras actualizar macOS o al sincronizar mucho correo.", .relanza),
        "mds": ("Servidor de Spotlight: coordina el índice de los archivos del disco.", .relanza),
        "mds_stores": ("Almacén del índice de Spotlight. Sube al indexar muchos archivos nuevos, como una copia grande o una compilación.", .relanza),
        // Nucleo y sesion
        "kernel_task": ("El núcleo de macOS. Cuando su CPU sube mucho suele ser el sistema frenando el chip para enfriarlo: el problema está en lo que lo calienta, no en él. No se puede terminar.", .peligroso),
        "WindowServer": ("Dibuja todo lo que ves en pantalla. Sube con muchas ventanas, pantallas externas o animaciones. Terminarlo cierra la sesión y todas las apps.", .peligroso),
        "launchd": ("El primer proceso del sistema: arranca y vigila a todos los demás.", .peligroso),
        "loginwindow": ("Tu sesión de usuario. Terminarlo cierra la sesión y todas las apps.", .peligroso),
        // Archivos, copias y nube
        "fseventsd": ("Registra los cambios en los archivos para Spotlight, Time Machine y las apps que vigilan carpetas. Sube cuando algo escribe muchos archivos seguidos.", .relanza),
        "backupd": ("Time Machine: hay una copia de seguridad en curso.", .relanza),
        "backupd-helper": ("Time Machine: prepara y programa las copias de seguridad.", .relanza),
        "cloudd": ("iCloud: sincroniza con la nube los datos de las apps.", .relanza),
        "bird": ("iCloud Drive: sincroniza tus archivos con la nube.", .relanza),
        "nsurlsessiond": ("Descargas y subidas en segundo plano de las apps: actualizaciones, iCloud, fotos.", .relanza),
        // Fotos y aprendizaje automatico
        "photoanalysisd": ("Fotos: analiza la fototeca (caras, objetos, recuerdos). Trabaja sobre todo con el equipo enchufado y en reposo.", .relanza),
        "mediaanalysisd": ("Análisis de imágenes y vídeo para Fotos, la búsqueda visual y el texto en imágenes.", .relanza),
        "photolibraryd": ("Gestiona la fototeca de Fotos.", .relanza),
        // Seguridad
        "trustd": ("Verifica certificados y firmas de código. Sube al abrir apps nuevas o al navegar.", .relanza),
        "syspolicyd": ("Gatekeeper: comprueba las apps antes de abrirlas.", .relanza),
        // Actualizaciones
        "softwareupdated": ("Busca y descarga actualizaciones de macOS.", .relanza),
        "installd": ("Instala actualizaciones y apps. Terminarlo puede dejar una instalación a medias.", .relanza),
        // Servicios del sistema
        "coreaudiod": ("El audio del sistema. Si lo terminas, el sonido se corta un momento y vuelve.", .relanza),
        "bluetoothd": ("Bluetooth.", .relanza),
        "airportd": ("Wi-Fi.", .relanza),
        "configd": ("Configuración de red. Terminarlo corta la red unos segundos.", .relanza),
        "powerd": ("Gestión de energía y del reposo.", .relanza),
        "thermalmonitord": ("Vigila la temperatura y decide cuándo frenar el chip.", .relanza),
        "logd": ("El registro del sistema. Sube cuando algún proceso escribe muchos mensajes.", .relanza),
        "distnoted": ("Mensajería interna entre procesos.", .relanza),
        "cfprefsd": ("Lee y guarda las preferencias de las apps.", .relanza),
        "opendirectoryd": ("Cuentas de usuario y autenticación.", .relanza),
        "symptomsd": ("Diagnóstico de red: mide la calidad de las conexiones.", .relanza),
        "triald": ("Ajustes y experimentos que Apple activa en segundo plano.", .relanza),
        "UserEventAgent": ("Reacciona a eventos del sistema (red, dispositivos, energía) por cuenta de otros servicios.", .relanza),
        "sharingd": ("AirDrop y funciones de Compartir.", .relanza),
        "rapportd": ("Continuidad de Apple: Handoff, portapapeles universal y descubrimiento de tus otros dispositivos.", .relanza),
        "corebrightnessd": ("Brillo automático y True Tone.", .relanza),
        "ControlCenter": ("Centro de control y receptor AirPlay.", .relanza),
        "NotificationCenter": ("Centro de notificaciones.", .relanza),
        "SystemUIServer": ("Iconos del sistema en la barra de menú.", .relanza),
        "Dock": ("El Dock, Mission Control y el Launchpad. Si lo terminas vuelve a aparecer enseguida.", .relanza),
        "Finder": ("El Finder. Si lo terminas se vuelve a abrir solo.", .relanza),
        // Motor web
        "com.apple.WebKit.WebContent": ("El contenido de una página web: una pestaña de Safari o una vista web dentro de otra app. Terminarlo deja esa página en blanco hasta recargarla.", .normal),
        "com.apple.WebKit.GPU": ("El dibujo con GPU de las páginas web de Safari y de las vistas web de otras apps.", .relanza),
        "com.apple.WebKit.Networking": ("La red de las páginas web de Safari y de las vistas web de otras apps.", .relanza),
    ]

    private static let porPrefijo: [(String, Entrada)] = [
        ("mdworker", ("Trabajador de Spotlight: lee el contenido de cada archivo para indexarlo. Hay varios y viven poco.", .relanza)),
        ("spotlightknowledge", ("Sugerencias de Spotlight: aprende de lo que usas para ordenar los resultados.", .relanza)),
        ("XProtect", ("XProtect, el antimalware de macOS: revisa el sistema periódicamente.", .relanza)),
        ("biome", ("Registro de actividad que usan Siri y las sugerencias.", .relanza)),
    ]

    private static let rutasSistema = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    /// Descripcion del catalogo o, si no esta, de la ruta. `app` es la app
    /// responsable, si se conoce (para los procesos auxiliares).
    static func describir(nombre: String, ruta: String, app: NSRunningApplication?) -> Descripcion? {
        if let e = porNombre[nombre] ?? porPrefijo.first(where: { nombre.hasPrefix($0.0) })?.1 {
            return Descripcion(texto: e.texto, riesgo: e.riesgo, origen: "macOS")
        }
        if rutasSistema.contains(where: { ruta.hasPrefix($0) }) {
            return Descripcion(texto: "Proceso de macOS (\((ruta as NSString).deletingLastPathComponent)).",
                               riesgo: .relanza, origen: "macOS")
        }
        if let app, let n = app.localizedName {
            return Descripcion(texto: "Proceso auxiliar de \(n). Terminarlo cierra solo esa parte (una pestaña, una extensión, un servidor local); la app suele volver a crearlo.",
                               riesgo: .normal, origen: n)
        }
        return nil
    }
}
