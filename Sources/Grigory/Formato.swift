import Foundation

/// Formatos de cifras para el usuario. Decimales con coma, como el resto de
/// textos en español.
enum Formato {
    /// Duracion legible: 45s, 12m, 3h 20m, 1d 20h.
    static func lapso(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "—" }
        let t = Int(max(0, s))
        let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m" }
        return "\(t)s"
    }

    /// Reloj de mision: 3d 04:12:55.
    static func reloj(_ s: Double?) -> String {
        guard let s, s.isFinite else { return "--:--:--" }
        let t = Int(max(0, s))
        let d = t / 86400, h = t % 86400 / 3600, m = t % 3600 / 60, seg = t % 60
        let hms = String(format: "%02d:%02d:%02d", h, m, seg)
        return d > 0 ? "\(d)d \(hms)" : hms
    }

    static func decimal(_ v: Double, _ decimales: Int) -> String {
        String(format: "%.\(decimales)f", v).replacingOccurrences(of: ".", with: ",")
    }

    static func gb(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        return decimal(Double(bytes) / 1_073_741_824, 1)
    }

    static func mb(_ bytes: UInt64?) -> String {
        guard let bytes else { return "—" }
        let m = Double(bytes) / 1_048_576
        return m >= 1024 ? decimal(m / 1024, 1) + " GB" : "\(Int(m.rounded())) MB"
    }

    /// Caudal: valor y unidad por separado, para componer tarjetas.
    static func tasaPartes(_ b: Double) -> (String, String) {
        if b >= 1_073_741_824 { return (decimal(b / 1_073_741_824, 2), "GB/s") }
        if b >= 1_048_576 { return (decimal(b / 1_048_576, 1), "MB/s") }
        if b >= 1024 { return ("\(Int((b / 1024).rounded()))", "kB/s") }
        return ("\(Int(b.rounded()))", "B/s")
    }

    static func tasa(_ b: Double) -> String {
        let (v, u) = tasaPartes(b)
        return "\(v) \(u)"
    }

    static func bytes(_ b: UInt64) -> String {
        let d = Double(b)
        if d >= 1_099_511_627_776 { return decimal(d / 1_099_511_627_776, 2) + " TB" }
        if d >= 1_073_741_824 { return decimal(d / 1_073_741_824, 1) + " GB" }
        if d >= 1_048_576 { return "\(Int((d / 1_048_576).rounded())) MB" }
        return "\(Int((d / 1024).rounded())) kB"
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "—" }
        return "\(Int(v.rounded()))%"
    }

    static func vatios(_ v: Double?, _ decimales: Int = 1) -> String {
        guard let v else { return "—" }
        return decimal(v, decimales) + " W"
    }

    static func mhz(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v >= 1000 ? decimal(v / 1000, 2) + " GHz" : "\(Int(v.rounded())) MHz"
    }

    static func temp(_ v: Double?) -> String {
        guard let v else { return "—" }
        return decimal(v, 1) + " °C"
    }
}
