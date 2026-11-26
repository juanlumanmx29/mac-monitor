import Darwin
import Foundation
import IOKit.pwr_mgt

// Puertos en escucha, bloqueos de reposo e impacto energetico.

// MARK: - Puertos

struct Puerto: Identifiable {
    let puerto: Int
    let pid: Int32
    let proceso: String
    let host: String
    let expuesto: Bool
    let protocolos: String
    var id: String { "\(pid):\(puerto)" }
}

/// Uso de red de un proceso: puertos en los que escucha y puerto local de
/// cada conexion establecida. Una conexion cuyo puerto local es uno de los de
/// escucha es entrante: alguien esta usando el servicio.
struct UsoRed {
    var escucha: [Int] = []
    var establecidas: [Int] = []
}

/// Sockets TCP en LISTEN de los procesos propios, con libproc: la misma via
/// que usa lsof, pero sin lanzar nada.
///
/// netstat no sirve: desde macOS 27 el kernel filtra net.inet.tcp.pcblist_n
/// para cualquier proceso que no sea de Apple, y tambien para sus hijos, asi
/// que netstat lanzado desde la app devuelve la lista vacia. Los procesos de
/// otros usuarios quedan fuera, como con lsof sin sudo.
func leerPuertos(_ pids: [Int32]) -> [Puerto] {
    recorrerSockets(pids).puertos
}

/// Recorre los sockets TCP de esos procesos: puertos en escucha (agrupados)
/// y uso de red de cada pid.
func recorrerSockets(_ pids: [Int32]) -> (puertos: [Puerto], uso: [Int32: UsoRed]) {
    var uso: [Int32: UsoRed] = [:]
    let tamFD = MemoryLayout<proc_fdinfo>.stride
    let tamSock = Int32(MemoryLayout<socket_fdinfo>.size)
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: 256)
    var agrupado: [String: (Puerto, Set<String>)] = [:]
    for pid in pids {
        var bytes = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * tamFD)))
        // Lista llena: puede que haya mas descriptores; se amplia y se repite.
        while bytes == fds.count * tamFD && fds.count < 65536 {
            fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fds.count * 4)
            bytes = Int(proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * tamFD)))
        }
        guard bytes > 0 else { continue }
        for i in 0..<(bytes / tamFD) where fds[i].proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            guard proc_pidfdinfo(pid, fds[i].proc_fd, PROC_PIDFDSOCKETINFO, &si, tamSock) == tamSock,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            var ini = tcp.tcpsi_ini
            let puerto = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))
            if tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED) {
                uso[pid, default: UsoRed()].establecidas.append(puerto)
                continue
            }
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            if !(uso[pid]?.escucha.contains(puerto) ?? false) { uso[pid, default: UsoRed()].escucha.append(puerto) }
            let v6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
            var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            if v6 {
                inet_ntop(AF_INET6, &ini.insi_laddr.ina_6, &buf, socklen_t(buf.count))
            } else {
                inet_ntop(AF_INET, &ini.insi_laddr.ina_46.i46a_addr4, &buf, socklen_t(buf.count))
            }
            var host = String(cString: buf)
            if host == "0.0.0.0" || host == "::" { host = "*" }
            // Solo loopback es local de verdad. "*" escucha en todas las
            // interfaces, y una IP concreta de la red tambien es alcanzable.
            let local = host.hasPrefix("127.") || host == "::1" || host.hasPrefix("::ffff:127.")
            let proto = v6 ? (ini.insi_vflag & UInt8(INI_IPV4) != 0 ? "IPv4/IPv6" : "IPv6") : "IPv4"
            // Un servicio suele escuchar dos veces, en IPv4 y en IPv6: se agrupa
            // por (pid, puerto). Basta un socket no local para que este expuesto.
            let clave = "\(pid):\(puerto)"
            if var a = agrupado[clave] {
                a.1.insert(proto)
                if !local && !a.0.expuesto {
                    a.0 = Puerto(puerto: puerto, pid: pid, proceso: a.0.proceso, host: host, expuesto: true, protocolos: "")
                }
                agrupado[clave] = a
            } else {
                agrupado[clave] = (Puerto(puerto: puerto, pid: pid, proceso: "", host: host,
                                          expuesto: !local, protocolos: ""), [proto])
            }
        }
    }
    let puertos = agrupado.values.map { p, protos in
        Puerto(puerto: p.puerto, pid: p.pid, proceso: p.proceso, host: p.host, expuesto: p.expuesto,
               protocolos: protos.contains("IPv4/IPv6") ? "IPv4/IPv6" : protos.sorted().joined(separator: "/"))
    }.sorted { ($0.expuesto ? 0 : 1, $0.puerto) < ($1.expuesto ? 0 : 1, $1.puerto) }
    return (puertos, uso)
}

// MARK: - Reposo

struct Asercion: Identifiable {
    let pid: Int32
    let proceso: String
    let tipo: String
    let motivo: String
    let detalle: String
    let paraPid: Int32?
    let duracion: Double
    var paraNombre: String?
    var id: String { "\(pid):\(tipo):\(motivo)" }
}

/// Quien impide que el equipo duerma, sin lanzar pmset. Se omiten la
/// asercion fija de powerd mientras la pantalla esta encendida y la de
/// actividad del usuario: existen siempre y no dicen nada.
func leerReposo() -> [Asercion]? {
    var d: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&d) == kIOReturnSuccess,
          let dict = d?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
    let ahora = Date()
    var r: [Asercion] = []
    for (pid, lista) in dict {
        for a in lista {
            let tipo = a["AssertType"] as? String ?? ""
            let nombre = a["AssertName"] as? String ?? ""
            let proceso = a["Process Name"] as? String ?? "pid \(pid)"
            if let nivel = numero(a["AssertLevel"]), nivel == 0 { continue }
            if tipo == "UserIsActive" { continue }
            if proceso == "powerd" && nombre.contains("display is on") { continue }
            let inicio = a["AssertStartWhen"] as? Date
            r.append(Asercion(
                pid: pid.int32Value, proceso: proceso, tipo: tipo,
                motivo: String(nombre.prefix(160)),
                detalle: String((a["Details"] as? String ?? "").prefix(200)),
                paraPid: (a["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value,
                duracion: inicio.map { max(0, ahora.timeIntervalSince($0)) } ?? 0))
        }
    }
    return r.sorted { $0.duracion > $1.duracion }
}

// MARK: - Energia

struct FilaEnergia: Identifiable {
    let pid: Int32
    var nombre: String
    var etiqueta: String
    var usuario: String?
    let impacto: Double
    var id: Int32 { pid }
}

/// Impacto energetico por proceso: la columna Energia del Monitor de
/// Actividad. top necesita dos muestras para calcularlo, asi que bloquea algo
/// mas de un segundo; se llama aparte y solo con el panel a la vista.
func leerEnergia(limite: Int = 12) -> (filas: [FilaEnergia], hilos: Int?)? {
    guard let s = Sys.ejecutar("/usr/bin/top", ["-l", "2", "-s", "1", "-n", String(limite),
                                                "-o", "power", "-stats", "pid,command,power"], limite: 12) else { return nil }
    // La primera muestra no tiene base de comparacion: vale la segunda tabla.
    // Su cabecera trae ademas el total de hilos del sistema, que sin
    // privilegios solo top conoce.
    guard let ultima = s.components(separatedBy: "\nPID").last else { return nil }
    var hilos: Int?
    if let r = s.range(of: #"(\d+) threads"#, options: [.regularExpression, .backwards]) {
        hilos = Int(s[r].split(separator: " ").first ?? "")
    }
    var filas: [FilaEnergia] = []
    for linea in ultima.split(separator: "\n").dropFirst() {
        let c = linea.split(separator: " ", omittingEmptySubsequences: true)
        guard c.count >= 3, let pid = Int32(c[0]), let impacto = Double(c[c.count - 1]) else { continue }
        let nombre = c[1..<(c.count - 1)].joined(separator: " ")
        filas.append(FilaEnergia(pid: pid, nombre: nombre, etiqueta: nombre, usuario: nil, impacto: impacto))
    }
    return (filas, hilos)
}

/// Total de hilos del sistema con `top -l 1`, para cuando no se esta
/// midiendo la energia (cuya cabecera ya lo trae).
func leerTotalHilos() -> Int? {
    guard let s = Sys.ejecutar("/usr/bin/top", ["-l", "1", "-n", "0"], limite: 8),
          let r = s.range(of: #"(\d+) threads"#, options: .regularExpression) else { return nil }
    return Int(s[r].split(separator: " ").first ?? "")
}
