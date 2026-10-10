import Foundation

/// Charging, adapter and MagSafe LED switches on Apple Silicon. Newer firmware
/// (macOS 15+) exposes CHTE/CHIE; older firmware uses CH0B+CH0C and CH0I.
enum ChargeControl {
    enum Err: Error, CustomStringConvertible {
        case unsupported(String), smc(String, Int32)
        var description: String {
            switch self {
            case .unsupported(let what): return "This Mac's SMC has no known \(what) key"
            case .smc(let key, let rc): return "SMC write to \(key) failed (rc=\(rc)); is the daemon running as root?"
            }
        }
    }

    static func read(_ key: String) -> [UInt8]? {
        var buf = [UInt8](repeating: 0, count: 32)
        var size: UInt32 = 0
        guard smc_read(key, &buf, &size, nil) == 0 else { return nil }
        return Array(buf.prefix(Int(size)))
    }

    static func write(_ key: String, _ bytes: [UInt8]) throws {
        let rc = smc_write(key, bytes, UInt32(bytes.count))
        if rc != 0 { throw Err.smc(key, rc) }
    }

    private static func has(_ key: String) -> Bool { read(key) != nil }

    // Which keys this firmware has, probed once.
    static let hasCHTE = has("CHTE")
    static let hasCH0B = has("CH0B")
    static let hasCHIE = has("CHIE")
    static let hasCH0I = has("CH0I")
    static let hasLED = has("ACLC")

    static var keySummary: String {
        let charge = hasCHTE ? "CHTE" : hasCH0B ? "CH0B/CH0C" : "none"
        let adapter = hasCHIE ? "CHIE" : hasCH0I ? "CH0I" : "none"
        return "charging=\(charge) adapter=\(adapter) led=\(hasLED ? "ACLC" : "none")"
    }

    // MARK: Charging

    static var chargingInhibited: Bool? {
        if hasCHTE { return read("CHTE").map { $0.contains { $0 != 0 } } }
        if hasCH0B { return read("CH0B").map { $0.first != 0 } }
        return nil
    }

    static func setChargingInhibited(_ inhibit: Bool) throws {
        if hasCHTE {
            try write("CHTE", inhibit ? [1, 0, 0, 0] : [0, 0, 0, 0])
        } else if hasCH0B {
            let v: UInt8 = inhibit ? 0x02 : 0x00
            try write("CH0B", [v])
            try write("CH0C", [v])
        } else {
            throw Err.unsupported("charging")
        }
    }

    // MARK: Adapter (forced discharge)

    static var adapterDisabled: Bool? {
        if hasCHIE { return read("CHIE").map { $0.first != 0 } }
        if hasCH0I { return read("CH0I").map { $0.first != 0 } }
        return nil
    }

    static func setAdapterDisabled(_ disable: Bool) throws {
        if hasCHIE {
            try write("CHIE", [disable ? 0x08 : 0x00])
        } else if hasCH0I {
            try write("CH0I", [disable ? 0x01 : 0x00])
        } else {
            throw Err.unsupported("adapter")
        }
    }

    // MARK: MagSafe LED

    enum LED: UInt8 { case system = 0x00, off = 0x01, green = 0x03, orange = 0x04 }

    static var led: UInt8? { hasLED ? read("ACLC")?.first : nil }

    static func setLED(_ c: LED) throws {
        guard hasLED else { return }
        try write("ACLC", [c.rawValue])
    }
}
