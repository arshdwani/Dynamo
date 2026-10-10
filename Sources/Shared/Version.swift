/// The single source of truth for the version; build.sh copies it into Info.plist.
/// Bump it with Tools/release.sh.
let appVersion = "1.5"

/// Numeric, part-by-part comparison: 1.10 > 1.9, 1.2 == 1.2.0.
func isNewerVersion(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let (p, q) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
        if p != q { return p > q }
    }
    return false
}
