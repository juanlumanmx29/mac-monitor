import Foundation
import IOKit

// Lectura directa del SMC (System Management Controller) por IOKit. Es la
// unica via a los ventiladores y termistores en Apple Silicon, y no requiere
// privilegios: solo abrir el servicio AppleSMC.
//
// La estructura que se intercambia con el driver (SMCKeyData_t, 80 bytes) se
// arma a mano sobre un buffer de bytes con los desplazamientos de C. Una
// struct de Swift no sirve: Swift coloca el campo siguiente dentro del
// relleno final de una struct anidada, y C no.

struct Ventilador {
    let id: Int
    let rpm: Double?
    let objetivo: Double
    let min: Double
    let max: Double
    var pct: Double {
        guard let rpm, max > min else { return 0 }
        return Swift.max(0, Swift.min(100, 100 * (rpm - min) / (max - min)))
    }
}

struct FamiliaTermica {
    let id: String
    let nombre: String
    /// nil significa "cluster en reposo" (sus termistores no reportan mientras
    /// esta apagado), no "sensor ausente".
    let max: Double?
    let promedio: Double?
    let n: Int
}

final class SMC {
    // El orden define el orden de presentacion en el panel.
    static let familias: [(String, String)] = [
        ("Tp", "CPU rendimiento"), ("Te", "CPU eficiencia"), ("Tg", "GPU"),
        ("TV", "Reguladores"), ("Ts", "Chasis"), ("TB", "Batería"),
        ("TH", "SSD"), ("Ta", "Entrada de aire"),
    ]
    /// Cuantos sensores leer por familia. Hay cientos de termistores validos;
    /// leerlos todos en cada muestra es gasto puro cuando basta una muestra
    /// representativa.
    static let maxPorFamilia = 10

    private static let kernelIndex: UInt32 = 2
    private static let leerClave: UInt8 = 5
    private static let claveEnIndice: UInt8 = 8
    private static let infoDeClave: UInt8 = 9

    private var conexion: io_connect_t = 0
    private let cerrojo = NSLock()
    private var infoClaves: [UInt32: (tam: UInt32, tipo: UInt32)] = [:]
    private var rangos: [(min: Double, max: Double)] = []
    private var clavesTemp: [String: [String]] = [:]

    private(set) var disponible = false
    private(set) var listo = false
    private(set) var motivo = ""
    private(set) var tieneSistema = false

    var sensores: Int {
        cerrojo.lock(); defer { cerrojo.unlock() }
        return clavesTemp.values.reduce(0) { $0 + $1.count }
    }

    init() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { motivo = "servicio AppleSMC no encontrado"; listo = true; return }
        defer { IOObjectRelease(svc) }
        let rc = IOServiceOpen(svc, mach_task_self_, 0, &conexion)
        guard rc == KERN_SUCCESS else { motivo = "IOServiceOpen devolvió \(rc)"; listo = true; return }
        disponible = true
        // El descubrimiento recorre las ~3000 claves del SMC y tarda cerca de un
        // segundo: corre aparte para no retrasar el arranque. Hasta que termina,
        // los muestreos devuelven listas vacias.
        DispatchQueue.global(qos: .utility).async {
            self.descubrir()
            self.listo = true
        }
    }

    deinit {
        if conexion != 0 { IOServiceClose(conexion) }
    }

    // MARK: - Protocolo

    private static func codigo(_ clave: String) -> UInt32 {
        clave.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func texto(_ codigo: UInt32) -> String {
        let b = [24, 16, 8, 0].map { UInt8((codigo >> UInt32($0)) & 0xff) }
        return String(decoding: b, as: UTF8.self)
    }

    private static func pon32(_ b: inout [UInt8], _ off: Int, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { for (i, x) in $0.enumerated() { b[off + i] = x } }
    }

    private static func lee32(_ b: [UInt8], _ off: Int) -> UInt32 {
        UInt32(b[off]) | UInt32(b[off + 1]) << 8 | UInt32(b[off + 2]) << 16 | UInt32(b[off + 3]) << 24
    }

    /// Llamada cruda al driver. Exige el cerrojo tomado.
    private func llamar(_ entrada: [UInt8]) -> [UInt8]? {
        var salida = [UInt8](repeating: 0, count: 80)
        var tam = 80
        let rc = entrada.withUnsafeBytes { e in
            salida.withUnsafeMutableBytes { s in
                IOConnectCallStructMethod(conexion, Self.kernelIndex, e.baseAddress, 80, s.baseAddress, &tam)
            }
        }
        // El byte 40 es el resultado del SMC: distinto de 0 es "clave inexistente"
        // u otro error, aunque la llamada de IOKit haya ido bien.
        guard rc == KERN_SUCCESS, salida[40] == 0 else { return nil }
        return salida
    }

    /// Valor decodificado de una clave, o nil.
    func leer(_ clave: String) -> Double? {
        guard disponible else { return nil }
        let k = Self.codigo(clave)
        cerrojo.lock()
        defer { cerrojo.unlock() }
        let info: (tam: UInt32, tipo: UInt32)
        if let i = infoClaves[k] {
            info = i
        } else {
            var e = [UInt8](repeating: 0, count: 80)
            Self.pon32(&e, 0, k)
            e[42] = Self.infoDeClave
            guard let s = llamar(e) else { return nil }
            info = (Self.lee32(s, 28), Self.lee32(s, 32))
            infoClaves[k] = info
        }
        var e = [UInt8](repeating: 0, count: 80)
        Self.pon32(&e, 0, k)
        Self.pon32(&e, 28, info.tam)
        Self.pon32(&e, 32, info.tipo)
        e[42] = Self.leerClave
        guard let s = llamar(e) else { return nil }
        let tam = Int(min(info.tam, 32))
        return Self.decodificar(Array(s[48..<(48 + tam)]), tipo: Self.texto(info.tipo))
    }

    private static func decodificar(_ b: [UInt8], tipo: String) -> Double? {
        switch tipo {
        case "flt " where b.count == 4:
            let v = Float(bitPattern: UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24)
            return v.isFinite ? Double(v) : nil
        case "fpe2" where b.count == 2:                       // Macs Intel
            return Double(Int(b[0]) << 6 | Int(b[1]) >> 2)
        case "sp78" where b.count == 2:
            return Double(Int8(bitPattern: b[0])) + Double(b[1]) / 256
        case _ where tipo.hasPrefix("ui"):
            return Double(b.reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        default:
            return nil
        }
    }

    private func claveEn(_ indice: UInt32) -> String? {
        var e = [UInt8](repeating: 0, count: 80)
        e[42] = Self.claveEnIndice
        Self.pon32(&e, 44, indice)
        cerrojo.lock()
        defer { cerrojo.unlock() }
        guard let s = llamar(e) else { return nil }
        return Self.texto(Self.lee32(s, 0))
    }

    // MARK: - Descubrimiento (una vez al arrancar)

    private var claveCache: String {
        "smc.claves.\(Equipo.actual.modelo).\(Sys.cadena("kern.osversion") ?? "")"
    }

    private func descubrir() {
        let n = Int(leer("FNum") ?? 0)
        let r = (0..<n).map { f in (min: leer("F\(f)Mn") ?? 0, max: leer("F\(f)Mx") ?? 0) }
        let sistema = leer("PSTR") != nil

        // Las claves de cada familia se guardan por modelo y version del sistema:
        // el recorrido completo solo se hace la primera vez.
        var familias: [String: [String]] = [:]
        if let guardadas = UserDefaults.standard.dictionary(forKey: claveCache) as? [String: [String]],
           !guardadas.isEmpty {
            familias = guardadas
        } else {
            familias = recorrer()
            if !familias.isEmpty { UserDefaults.standard.set(familias, forKey: claveCache) }
        }
        cerrojo.lock()
        rangos = r
        clavesTemp = familias
        tieneSistema = sistema
        cerrojo.unlock()
    }

    private func recorrer() -> [String: [String]] {
        guard let total = leer("#KEY"), total > 0 else { return [:] }
        let prefijos = Set(Self.familias.map(\.0))
        var candidatas: [String: [String]] = [:]
        for i in 0..<UInt32(total) {
            guard let k = claveEn(i) else { continue }
            let p = String(k.prefix(2))
            guard prefijos.contains(p), (candidatas[p]?.count ?? 0) < Self.maxPorFamilia * 3 else { continue }
            candidatas[p, default: []].append(k)
        }
        // El SMC expone muchos termistores reservados o inactivos: se prefieren
        // las claves que ya dan una lectura plausible. Si una familia no tiene
        // ninguna viva en este instante se conservan igual sus primeras claves:
        // los sensores de los nucleos P leen 0 con el cluster apagado y volveran
        // a dar valores al despertar. Sin esto la familia desapareceria del
        // panel de forma intermitente.
        var r: [String: [String]] = [:]
        for (p, claves) in candidatas {
            var vivas: [String] = []
            for k in claves {
                if let v = leer(k), v > 5, v < 120 { vivas.append(k) }
                if vivas.count >= Self.maxPorFamilia { break }
            }
            r[p] = vivas.isEmpty ? Array(claves.prefix(Self.maxPorFamilia)) : vivas
        }
        return r
    }

    // MARK: - Muestreo

    func ventiladores() -> [Ventilador] {
        cerrojo.lock()
        let r = rangos
        cerrojo.unlock()
        return r.enumerated().map { f, rango in
            Ventilador(id: f, rpm: leer("F\(f)Ac"), objetivo: leer("F\(f)Tg") ?? 0,
                       min: rango.min, max: rango.max)
        }
    }

    /// `solo`: limita la lectura a esas familias (la barra de menu en fondo
    /// solo necesita las de CPU).
    func temperaturas(solo: Set<String>? = nil) -> [FamiliaTermica] {
        cerrojo.lock()
        let claves = clavesTemp
        cerrojo.unlock()
        return Self.familias.compactMap { prefijo, nombre in
            if let solo, !solo.contains(prefijo) { return nil }
            guard let lista = claves[prefijo], !lista.isEmpty else { return nil }
            let vals = lista.compactMap { leer($0) }.filter { $0 > 5 && $0 < 120 }
            return FamiliaTermica(
                id: prefijo, nombre: nombre,
                max: vals.max(),
                promedio: vals.isEmpty ? nil : vals.reduce(0, +) / Double(vals.count),
                n: vals.count)
        }
    }

    /// Potencia total del equipo en vatios (clave PSTR), si el SMC la publica.
    func potenciaSistema() -> Double? {
        guard tieneSistema, let v = leer("PSTR"), v >= 0, v < 1000 else { return nil }
        return v
    }

    /// Todas las claves con un prefijo y su valor, para diagnostico
    /// (`--smc <prefijo>`). Recorre el SMC entero: tarda cerca de un segundo.
    func listar(prefijo: String) -> [(String, Double?)] {
        guard let total = leer("#KEY"), total > 0 else { return [] }
        return (0..<UInt32(total)).compactMap { i -> (String, Double?)? in
            guard let k = claveEn(i), k.hasPrefix(prefijo) else { return nil }
            return (k, leer(k))
        }
    }

    /// Volcado de una clave para diagnostico.
    func describir(_ clave: String) -> String {
        leer(clave).map { String(format: "%.2f", $0) } ?? "—"
    }
}
