import Foundation

// `Grigory --volcar`: muestrea unos segundos sin abrir ventanas e imprime
// todo lo leido. Sustituye a `python3 smc.py`, `python3 vigilancia.py` y al
// curl contra /api/metrics de la version anterior.
//
// `Grigory --medir <segundos> [fondo|visible]`: mide lo que gasta el motor
// en ese regimen (CPU propia y de procesos auxiliares).

enum Volcado {
    static func ejecutar() {
        let motor = Motor()
        let eq = motor.equipo
        print("equipo   \(eq.chip) · \(eq.modelo) · \(eq.nucleos) núcleos (\(eq.nucleosE) E + \(eq.nucleosP) P)"
              + " · \(Formato.gb(eq.ram)) GB · gpu \(eq.gpuNucleos.map(String.init) ?? "—") · macOS \(eq.macos)")
        // Tres ciclos: el primero no tiene base para las tasas.
        var foto = Foto()
        for i in 0..<4 {
            if i > 0 { Thread.sleep(forTimeInterval: 1.1) }
            foto = motor.cicloSincrono(visible: true).0
        }
        let f = foto
        let c = f.cpu
        print("\n[cpu]    total \(Formato.pct(c.total)) · E \(Formato.pct(c.promedioE)) · P \(Formato.pct(c.promedioP))"
              + " · carga \(c.carga.map { Formato.decimal($0, 2) }.joined(separator: " "))")
        print("         núcleos " + c.nucleos.map { "\(Int($0.rounded()))" }.joined(separator: " "))
        if let m = f.memoria {
            print("[memoria] usada \(Formato.gb(m.usada)) / \(Formato.gb(m.total)) GB (\(Formato.pct(m.pct)))"
                  + " · apps \(Formato.gb(m.apps)) · anclada \(Formato.gb(m.ancladas)) · compr. \(Formato.gb(m.comprimidas))"
                  + " · caché \(Formato.gb(m.cache)) · libre \(Formato.gb(m.libre)) · swap \(Formato.gb(m.swapUsado))/\(Formato.gb(m.swapTotal))"
                  + " · presión \(m.presion)")
        }
        if let g = f.gpu {
            print("[gpu]    uso \(Formato.pct(g.uso)) · render \(Formato.pct(g.render)) · tiler \(Formato.pct(g.tiler))"
                  + " · memoria \(Formato.mb(g.memoriaEnUso.map { UInt64($0) }))")
        }
        if let p = f.potencia {
            print("[potencia] sistema \(Formato.vatios(p.sistema, 2)) · cpu \(Formato.vatios(p.cpu, 2)) · gpu \(Formato.vatios(p.gpu, 2))"
                  + " · ane \(Formato.vatios(p.ane, 2)) · dram \(Formato.vatios(p.dram, 2)) · térmica \(PresionTermica.nombre(p.termico))")
            print("         clusters " + p.clusters.map { "\($0.nombre) \(Formato.mhz($0.mhz)) \(Formato.pct($0.activa))" }.joined(separator: " · "))
            print("         núcleos MHz " + p.nucleosMHz.map { $0.map { "\(Int($0))" } ?? "—" }.joined(separator: " "))
            print("         gpu \(Formato.mhz(p.gpuMHz)) activa \(Formato.pct(p.gpuActiva)) · estados "
                  + p.gpuEstados.map { "\(Int($0.mhz)):\(Formato.decimal($0.pct, 1))" }.joined(separator: " "))
        }
        let smc = SMC()
        while !smc.listo { Thread.sleep(forTimeInterval: 0.1) }
        print("         smc PSTR \(Formato.vatios(smc.potenciaSistema(), 2))")
        if let b = f.bateria {
            print("[batería] \(Formato.pct(b.pct)) \(b.estado.rawValue) · flujo \(Formato.vatios(b.vatios, 2)) · ciclos \(b.ciclos.map(String.init) ?? "—")"
                  + " · salud \(Formato.pct(b.salud)) · temp \(Formato.temp(b.temperatura)) · adaptador \(Formato.vatios(b.adaptador, 0))"
                  + " · carga del sistema \(Formato.vatios(b.cargaSistema, 2)) · quedan \(b.minutosRestantes.map { "\($0) min" } ?? "—")")
        }
        if let t = RegistroEnergia.ultimoTramo() {
            let h = DateFormatter()
            h.dateFormat = "dd/MM HH:mm"
            print("[tramo con batería] \(h.string(from: t.inicio)) → \(t.enCurso ? "ahora" : h.string(from: t.fin)) (\(Formato.lapso(t.duracion)))"
                  + " · \(Int(t.nivelInicio))% → \(Int(t.nivelFin))% · media \(Formato.vatios(t.vatiosMedios)) · cámara \(Int(t.minutosCamara)) min · \(t.curva.count) muestras")
            for a in t.apps.prefix(8) {
                print("         \(a.nombre.padding(toLength: 22, withPad: " ", startingAt: 0)) \(Formato.decimal(a.pctEnergia, 1).padding(toLength: 5, withPad: " ", startingAt: 0))% energía · CPU \(Formato.lapso(a.cpu)) · GPU \(Formato.decimal(a.pctGPU, 1))%")
            }
        } else {
            print("[tramo con batería] sin registro legible")
        }
        print("[ventiladores] " + (f.ventiladores.isEmpty ? "ninguno" : f.ventiladores.map {
            "#\($0.id) \($0.rpm.map { "\(Int($0))" } ?? "—") rpm (\(Int($0.min))–\(Int($0.max)))" }.joined(separator: " · ")))
        print("[térmico] \(f.fuentes.sensores) sensores")
        for t in f.temperaturas {
            print("         \(t.nombre.padding(toLength: 18, withPad: " ", startingAt: 0)) máx \(Formato.temp(t.max))  prom \(Formato.temp(t.promedio))  (\(t.n))")
        }
        print("[red]    ↓ \(Formato.tasa(f.red.entrada)) ↑ \(Formato.tasa(f.red.salida)) · "
              + f.interfaces.map { "\($0.nombre) ↓\(Formato.tasa($0.entrada)) ↑\(Formato.tasa($0.salida))" }.joined(separator: " · "))
        print("[disco]  lectura \(Formato.tasa(f.disco.entrada)) · escritura \(Formato.tasa(f.disco.salida))")
        let propios = f.procesos.filter(\.propio).count
        let conCPU = f.procesos.filter { $0.cpuTotal != nil }.count
        print("[procesos] \(f.procesos.count) (\(propios) propios, \(conCPU) con CPU medida) · hilos \(f.totalHilos.map(String.init) ?? "—")")
        for p in f.procesos.prefix(8) {
            print("         \(String(p.pid).padding(toLength: 7, withPad: " ", startingAt: 0)) \(Formato.decimal(p.pcpu, 1).padding(toLength: 6, withPad: " ", startingAt: 0))% "
                  + "\(Formato.mb(p.rss).padding(toLength: 8, withPad: " ", startingAt: 0)) \(p.usuario.padding(toLength: 14, withPad: " ", startingAt: 0)) \(p.etiqueta.prefix(40))")
        }
        print("[puertos] \(f.puertos.count) · \(f.puertos.filter(\.expuesto).count) expuestos")
        for p in f.puertos.prefix(12) {
            let nombre = f.tabla[p.pid]?.etiqueta ?? p.proceso
            print("         \(String(p.puerto).padding(toLength: 6, withPad: " ", startingAt: 0)) \(p.expuesto ? "expuesto" : "local   ") \(p.host.padding(toLength: 12, withPad: " ", startingAt: 0)) \(p.protocolos.padding(toLength: 10, withPad: " ", startingAt: 0)) pid \(p.pid) \(nombre)")
        }
        print("[reposo] con batería: \(f.enBateria.map { $0 ? "sí" : "no" } ?? "—") · \(f.reposo.count) bloqueos")
        for r in f.reposo {
            print("         \(r.proceso.padding(toLength: 22, withPad: " ", startingAt: 0)) \(r.tipo.padding(toLength: 30, withPad: " ", startingAt: 0)) \(Formato.lapso(r.duracion))\(r.paraNombre.map { " · para \($0)" } ?? "")")
        }
        let v = f.vigilancia
        print("[vigilancia] procesos \(v.cuentas.procesos) · sin terminal \(v.cuentas.sinTerminal) · huérfanos \(v.cuentas.huerfanos)"
              + " · zombis \(v.cuentas.zombis) · detenidos \(v.cuentas.detenidos) · launchd \(v.gestionadosOk ? "ok" : "no")")
        for a in v.alertas {
            print("         [\(a.nivel.nombre)] \(a.titulo.padding(toLength: 28, withPad: " ", startingAt: 0)) pid \(String(a.pid).padding(toLength: 6, withPad: " ", startingAt: 0)) \(a.etiqueta.prefix(34)) \(a.cpuSostenida.map { Formato.pct($0) } ?? "—")")
            print("            padre \(a.padre ?? "—") · vida \(Formato.lapso(a.vida)) · \(a.args.prefix(90))")
            if a.familia.count > 1 { print("            familia \(a.familia.count) procesos") }
            if let c = a.cwd { print("            carpeta \(c.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") }
            print("            escucha \(a.escucha.map { ":\($0)" }.joined(separator: " ")) · conexiones entrantes \(a.conexiones.map(String.init) ?? "—")")
            for c in a.usoCopias {
                print("            copia pid \(c.pid) · escucha \(c.escucha.map { ":\($0)" }.joined(separator: " ")) · conexiones \(c.conexiones) · terminal \(c.tty)")
            }
        }
        if ProcessInfo.processInfo.environment["GRIGORY_PERFIL"] != nil {
            print("[perfil] " + motor.perfil.map { "\($0.0) \(Formato.decimal($0.1, 1))" }.joined(separator: " · "))
        }
        print("[app]    ciclo \(Formato.decimal(f.propio.ciclo, 1)) ms · memoria \(Formato.mb(f.propio.memoria))"
              + " · smc \(f.fuentes.smc ? "ok" : f.fuentes.smcMotivo) · ioreport \(f.fuentes.ioreport ? "ok" : f.fuentes.ioreportMotivo)")
    }

    static func medir(segundos: Double, visible: Bool) {
        let motor = Motor()
        func cpu() -> (Double, Double) {
            var yo = rusage(), hijos = rusage()
            getrusage(RUSAGE_SELF, &yo)
            getrusage(RUSAGE_CHILDREN, &hijos)
            func s(_ tv: timeval) -> Double { Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6 }
            return (s(yo.ru_utime) + s(yo.ru_stime), s(hijos.ru_utime) + s(hijos.ru_stime))
        }
        // Calentamiento: descubrimiento del SMC, primeras rutas y argumentos.
        _ = motor.cicloSincrono(visible: visible)
        Thread.sleep(forTimeInterval: 2)
        _ = motor.cicloSincrono(visible: visible)
        let (p0, h0) = cpu()
        let t0 = Sys.reloj()
        let paso = visible ? 1.0 : Reglas.muestreo
        var ciclos = 0
        var duraciones: [Double] = []
        while Sys.reloj() - t0 < segundos {
            Thread.sleep(forTimeInterval: paso)
            duraciones.append(motor.cicloSincrono(visible: visible).0.propio.ciclo)
            ciclos += 1
        }
        Thread.sleep(forTimeInterval: 1.5)   // deja terminar una medicion de energia en curso
        let (p1, h1) = cpu()
        let dt = Sys.reloj() - t0
        print("régimen \(visible ? "visible" : "fondo") · \(ciclos) ciclos en \(Formato.decimal(dt, 1)) s")
        print("CPU propia      \(Formato.decimal(100 * (p1 - p0) / dt, 2)) % de un núcleo")
        print("CPU auxiliares  \(Formato.decimal(100 * (h1 - h0) / dt, 2)) % de un núcleo")
        print("ciclo medio     \(Formato.decimal(duraciones.reduce(0, +) / Double(max(1, duraciones.count)), 1)) ms"
              + " · máx \(Formato.decimal(duraciones.max() ?? 0, 1)) ms")
    }
}
