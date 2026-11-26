import Darwin
import Foundation
import IOKit

// Acceso de bajo nivel compartido por todos los lectores: sysctl, procesos
// auxiliares y propiedades del registro de IOKit. Nada de esto conoce el
// formato de ninguna metrica concreta.

enum Sys {
    static func cadena(_ nombre: String) -> String? {
        var tam = 0
        guard sysctlbyname(nombre, nil, &tam, nil, 0) == 0, tam > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: tam)
        guard sysctlbyname(nombre, &buf, &tam, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func entero(_ nombre: String) -> Int? {
        var tam = 0
        guard sysctlbyname(nombre, nil, &tam, nil, 0) == 0 else { return nil }
        switch tam {
        case 4:
            var v: Int32 = 0
            return sysctlbyname(nombre, &v, &tam, nil, 0) == 0 ? Int(v) : nil
        case 8:
            var v: Int64 = 0
            return sysctlbyname(nombre, &v, &tam, nil, 0) == 0 ? Int(v) : nil
        default:
            return nil
        }
    }

    /// Ejecuta un programa y devuelve su salida estandar, o nil si fallo o
    /// supero el limite de tiempo. Se usa solo para lo que no tiene API
    /// publica sin privilegios (ps de otros usuarios, netstat, launchctl, top).
    static func ejecutar(_ ruta: String, _ args: [String], limite: TimeInterval = 6) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ruta)
        p.arguments = args
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let vigia = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + limite, execute: vigia)
        let datos = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        vigia.cancel()
        guard p.terminationStatus == 0 else { return nil }
        return String(decoding: datos, as: UTF8.self)
    }

    /// Tiempo monotono en segundos, inmune a cambios de hora del sistema.
    static func reloj() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9
    }

    static let base: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Convierte unidades de tiempo absoluto de Mach a segundos. En Apple
    /// Silicon no son nanosegundos (la base es 125/3).
    static func segundos(mach: UInt64) -> Double {
        Double(mach) * Double(base.numer) / Double(base.denom) / 1e9
    }

    static let host: mach_port_t = mach_host_self()

    private static var usuarios: [uid_t: String] = [:]
    private static let cerrojoUsuarios = NSLock()

    static func usuario(_ uid: uid_t) -> String {
        cerrojoUsuarios.lock()
        defer { cerrojoUsuarios.unlock() }
        if let u = usuarios[uid] { return u }
        let nombre = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        usuarios[uid] = nombre
        return nombre
    }
}

enum IOK {
    static func propiedades(_ e: io_registry_entry_t) -> [String: Any]? {
        var p: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(e, &p, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = p?.takeRetainedValue() else { return nil }
        return d as? [String: Any]
    }

    static func propiedad(_ e: io_registry_entry_t, _ clave: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, clave as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Recorre los servicios de una clase. El cuerpo devuelve false para cortar.
    static func cadaServicio(_ clase: String, _ cuerpo: (io_object_t) -> Bool) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(clase), &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while true {
            let s = IOIteratorNext(it)
            if s == 0 { break }
            let seguir = cuerpo(s)
            IOObjectRelease(s)
            if !seguir { break }
        }
    }
}

func numero(_ v: Any?) -> Double? {
    (v as? NSNumber)?.doubleValue
}

/// "1-02:03:04", "02:03:04", "03:04" o "3:27.74" -> segundos.
func segundosDeTexto(_ texto: Substring) -> Double? {
    var dias = 0.0
    var resto = texto
    if let guion = resto.firstIndex(of: "-") {
        guard let d = Double(resto[..<guion]) else { return nil }
        dias = d
        resto = resto[resto.index(after: guion)...]
    }
    var total = 0.0
    for parte in resto.split(separator: ":") {
        guard let v = Double(parte) else { return nil }
        total = total * 60 + v
    }
    return dias * 86400 + total
}
