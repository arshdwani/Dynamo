import AppKit

/// Checks GitHub once a day for a newer release, and runs the update in Terminal.
/// It only reads the public "latest release" endpoint; nothing about this Mac is sent.
struct Release: Equatable {
    var version: String
    var url: URL
}

enum Updater {
    static let repo = "arshdwani/Dynamo"
    static let checkInterval: TimeInterval = 24 * 3600

    static func latestRelease() async -> Release? {
        guard let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var req = URLRequest(url: api, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        return Release(version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")), url: page)
    }

    /// How Dynamo was installed, from where install.sh ran (recorded at install time).
    enum Source { case git(String), homebrew, unknown }

    static var source: Source {
        guard let s = try? String(contentsOfFile: Paths.dir + "/source-path", encoding: .utf8) else { return .unknown }
        let path = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.contains("/Cellar/dynamo/") { return .homebrew }
        return FileManager.default.fileExists(atPath: path + "/.git") ? .git(path) : .unknown
    }

    /// Opens Terminal with the update commands (it asks for the password there).
    static func runUpdate(_ release: Release) {
        let script: String
        switch source {
        case .git(let folder): script = updateScript(version: release.version, folder: folder)
        case .homebrew: script = brewUpdateScript(version: release.version)
        case .unknown:
            NSWorkspace.shared.open(release.url)
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Update Dynamo.command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSWorkspace.shared.open(release.url)
        }
    }

    static let brewFormula = "arshdwani/tap/dynamo"

    static func brewUpdateScript(version: String) -> String {
        """
        #!/bin/bash
        export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
        echo "Updating Dynamo to \(version) with Homebrew…"
        brew update && brew upgrade \(brewFormula) && dynamo-setup
        """
    }

    static func updateScript(version: String, folder: String) -> String {
        let quoted = "'" + folder.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/bash
        echo "Updating Dynamo to \(version)…"
        cd \(quoted) || exit 1
        if ! git pull --ff-only; then
            echo
            echo "Couldn't update automatically (local changes in this folder?)."
            echo "Resolve them, then run: git pull && ./install.sh"
            exit 1
        fi
        ./install.sh
        """
    }
}
