import AppKit
import SQLite3

// «¿Qué gastó la batería?»: el registro de energía que lleva macOS
// (powerlog), el mismo que usa la columna «Energía en 12 h» del Monitor de
// Actividad. Es legible sin privilegios. Se copia a una carpeta temporal y se
// abre en solo lectura: el original está en modo WAL y abrirlo en sitio
// exigiría escribir su archivo de memoria compartida.

struct ConsumoApp: Identifiable {
    let id: String
    let nombre: String
    /// Proporción de la energía atribuida a apps en el tramo.
    let pctEnergia: Double
    /// Segundos de CPU en el tramo.
    let cpu: Double
    let pctGPU: Double
}

struct TramoBateria {
    let inicio: Date
    let fin: Date
    let nivelInicio: Double
    let nivelFin: Double
    /// Sigue con batería ahora mismo.
    let enCurso: Bool
    let curva: [Muestra]
    let potencia: [Muestra]
    let apps: [ConsumoApp]
    /// Minutos con la cámara encendida: delata una videollamada.
    let minutosCamara: Double
    let vatiosMedios: Double?
    /// Tiempo con la Mac despierta: el registro no anota nada durante el
    /// reposo, asi que los saltos de mas de 10 min entre muestras no cuentan.
    let despierta: Double

    var puntos: Double { nivelInicio - nivelFin }
    var duracion: Double { fin.timeIntervalSince(inicio) }
}

enum RegistroEnergia {
    static let ruta = "/private/var/db/powerlog/Library/BatteryLife/CurrentPowerlog.PLSQL"

    /// El último tramo con batería de las últimas 48 h (el actual, si se está
    /// descargando ahora), o nil si no hay registro legible.
    static func ultimoTramo() -> TramoBateria? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("grigory-powerlog", isDirectory: true)
        let fm = FileManager.default
        try? fm.removeItem(at: tmp)
        defer { try? fm.removeItem(at: tmp) }
        guard (try? fm.createDirectory(at: tmp, withIntermediateDirectories: true)) != nil else { return nil }
        let destino = tmp.appendingPathComponent("p.PLSQL")
        for sufijo in ["", "-wal", "-shm"] where fm.fileExists(atPath: ruta + sufijo) {
            guard (try? fm.copyItem(atPath: ruta + sufijo, toPath: destino.path + sufijo)) != nil else {
                if sufijo.isEmpty { return nil } else { continue }
            }
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(destino.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return nil }
        defer { sqlite3_close(db) }

        // Nivel y cargador en las ultimas 48 h.
        let desde = Date().timeIntervalSince1970 - 48 * 3600
        var filas: [(t: Double, nivel: Double, conectado: Bool, amp: Double, volt: Double)] = []
        consulta(db, """
            select timestamp, Level, ExternalConnected, InstantAmperage, Voltage
            from PLBatteryAgent_EventBackward_Battery where timestamp > \(desde) order by timestamp
            """) { s in
            filas.append((sqlite3_column_double(s, 0), sqlite3_column_double(s, 1),
                          sqlite3_column_int(s, 2) != 0, sqlite3_column_double(s, 3), sqlite3_column_double(s, 4)))
        }
        guard let ultima = filas.last else { return nil }

        // Ultimo bloque continuo sin cargador.
        var fin = filas.count - 1
        if ultima.conectado {
            while fin >= 0 && filas[fin].conectado { fin -= 1 }
            guard fin >= 0 else { return nil }
        }
        var ini = fin
        while ini > 0 && !filas[ini - 1].conectado { ini -= 1 }
        let bloque = Array(filas[ini...fin])
        guard bloque.count >= 2 else { return nil }
        let tIni = bloque.first!.t
        let tFin = ultima.conectado ? bloque.last!.t : Date().timeIntervalSince1970

        let curva = bloque.map { Muestra(t: $0.t, v: $0.nivel) }
        let potencia = bloque.filter { $0.amp < 0 }.map { Muestra(t: $0.t, v: abs($0.amp) * $0.volt / 1e6) }
        let vatios = potencia.isEmpty ? nil : potencia.map(\.v).reduce(0, +) / Double(potencia.count)

        // Energia por app (coalicion) dentro del tramo.
        var porApp: [String: (energia: Double, cpu: Double, gpu: Double)] = [:]
        var camara = 0.0
        consulta(db, """
            select coalesce(nullif(BundleId, ''), LaunchdName), energy, cpu_time, gpu_energy_nj,
                   timestamp, timestampEnd, LaunchdName
            from PLCoalitionAgent_EventInterval_CoalitionInterval
            where timestamp >= \(tIni) and timestampEnd <= \(tFin)
            """) { s in
            guard let c = sqlite3_column_text(s, 0) else { return }
            let clave = String(cString: c)
            var a = porApp[clave] ?? (0, 0, 0)
            a.energia += sqlite3_column_double(s, 1)
            a.cpu += sqlite3_column_double(s, 2)
            a.gpu += sqlite3_column_double(s, 3)
            porApp[clave] = a
            let launchd = sqlite3_column_text(s, 6).map { String(cString: $0) } ?? ""
            if (clave.contains("cameracaptured") || launchd.contains("cameracaptured")) && sqlite3_column_double(s, 2) > 0.5 {
                camara += sqlite3_column_double(s, 5) - sqlite3_column_double(s, 4)
            }
        }
        let totalE = porApp.values.reduce(0) { $0 + $1.energia }
        let totalG = porApp.values.reduce(0) { $0 + $1.gpu }
        let apps = porApp.filter { $0.value.energia > 0 }
            .sorted { $0.value.energia > $1.value.energia }
            .prefix(10)
            .map { clave, v in
                ConsumoApp(id: clave, nombre: nombre(clave),
                           pctEnergia: totalE > 0 ? 100 * v.energia / totalE : 0,
                           cpu: v.cpu, pctGPU: totalG > 0 ? 100 * v.gpu / totalG : 0)
            }

        let despierta = zip(bloque, bloque.dropFirst()).reduce(0.0) { n, par in
            let dt = par.1.t - par.0.t
            return dt <= 600 ? n + dt : n
        }
        return TramoBateria(inicio: Date(timeIntervalSince1970: tIni), fin: Date(timeIntervalSince1970: tFin),
                            nivelInicio: bloque.first!.nivel, nivelFin: bloque.last!.nivel,
                            enCurso: !ultima.conectado, curva: curva, potencia: potencia, apps: Array(apps),
                            minutosCamara: camara / 60, vatiosMedios: vatios, despierta: despierta)
    }

    private static func consulta(_ db: OpaquePointer, _ sql: String, _ fila: (OpaquePointer) -> Void) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK, let s else { return }
        defer { sqlite3_finalize(s) }
        while sqlite3_step(s) == SQLITE_ROW { fila(s) }
    }

    /// Nombre legible: el de la app si el identificador es de una app
    /// instalada; si no, la parte significativa del nombre del servicio.
    private static func nombre(_ clave: String) -> String {
        var id = clave
        if id.hasPrefix("application.") {
            id = String(id.dropFirst(12))
            // application.com.x.App.123.456 -> com.x.App
            while let u = id.split(separator: ".").last, u.allSatisfy(\.isNumber) {
                id = String(id.dropLast(u.count + 1))
            }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        let partes = id.split(separator: ".").map(String.init)
        let genericos: Set<String> = ["daemon", "agent", "macos", "service", "helper", "xpc"]
        if let u = partes.last, genericos.contains(u.lowercased()), partes.count >= 2 {
            return partes.suffix(2).joined(separator: " ")
        }
        return partes.last ?? id
    }
}
