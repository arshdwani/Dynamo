import Foundation

/// The same four choices as System Settings > Battery > Low Power Mode.
/// Reading works as any user; applying needs root, so the app asks the daemon
/// via `Config.lowPowerRequest`.
enum LowPowerMode: String, Codable, CaseIterable, Identifiable {
    case never, always, battery, adapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: return "Never"
        case .always: return "Always"
        case .battery: return "Only on Battery"
        case .adapter: return "Only on Power Adapter"
        }
    }

    private var flags: (battery: Bool, ac: Bool) {
        switch self {
        case .never: return (false, false)
        case .always: return (true, true)
        case .battery: return (true, false)
        case .adapter: return (false, true)
        }
    }

    static func current() -> LowPowerMode? {
        guard let out = run(["-g", "custom"]) else { return nil }
        var section = "", battery: Bool?, ac: Bool?
        for line in out.split(separator: "\n") {
            if line.hasSuffix("Power:") { section = String(line); continue }
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2, parts[0] == "lowpowermode" else { continue }
            if section.hasPrefix("Battery") { battery = parts[1] == "1" }
            if section.hasPrefix("AC") { ac = parts[1] == "1" }
        }
        // Desktop Macs have no battery section.
        return allCases.first { $0.flags == (battery ?? ac ?? false, ac ?? false) }
    }

    func apply() -> Bool {
        let f = flags
        return Self.run(["-b", "lowpowermode", f.battery ? "1" : "0"]) != nil
            && Self.run(["-c", "lowpowermode", f.ac ? "1" : "0"]) != nil
    }

    @discardableResult
    private static func run(_ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }
}
