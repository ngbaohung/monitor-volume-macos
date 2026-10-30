import Foundation

enum LoginSession {
    /// How soon after login a launch still counts as "started automatically".
    private static let window: TimeInterval = 120

    /// `true` when this process started within a couple of minutes of the user's console login,
    /// i.e. it was opened as a login item rather than by hand.
    static var appWasLaunchedAtLogin: Bool {
        guard let login = consoleLoginDate else { return false }
        return Date().timeIntervalSince(login) < window
    }

    /// Most recent console login of the current user, from the utmpx login records.
    private static var consoleLoginDate: Date? {
        let user = NSUserName()
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            var record = entry.pointee
            guard record.ut_type == USER_PROCESS else { continue }
            let name = withUnsafeBytes(of: &record.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let line = withUnsafeBytes(of: &record.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard name == user, line == "console" else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(record.ut_tv.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }
}
