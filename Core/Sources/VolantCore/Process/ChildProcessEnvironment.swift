import Foundation

/// The complete environment for every helper process Volant spawns. A child never inherits the
/// caller's environment: each spawn receives only a home folder, user name, fixed search path and
/// a fixed UTF-8 locale, plus the few named variables its caller adds. The locale is deliberately
/// `en_US.UTF-8` rather than derived from `Locale.current`; see docs/agent-integrations.md.
/// git status parsing uses `LC_ALL=C` instead, through `RepositoryStatusCommand.environment`.
public enum ChildProcessEnvironment {
    public static let locale = "en_US.UTF-8"
    public static let systemPath = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    /// Search path for owner-installed command-line tools: `~/.local/bin` and Homebrew first, then the
    /// system folders. The `sbin` folders are included only when asked for.
    public static func userToolPath(home: String, includeSbin: Bool) -> [String] {
        [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"] + (includeSbin ? ["/usr/sbin", "/sbin"] : [])
    }

    /// Base environment shared by every spawn.
    public static func base(home: String, user: String, path: [String]) -> [String: String] {
        ["HOME": home, "USER": user, "PATH": path.joined(separator: ":"), "LANG": locale]
    }

    /// An ACP provider: its own executable folder searched first, then owner tool folders. The resolved
    /// launch's variables (such as `CLAUDE_CODE_EXECUTABLE`) are applied last.
    public static func acpProvider(home: String, user: String, executable: String, launch: [String: String]) -> [String: String] {
        let folder = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        var environment = base(home: home, user: user, path: [folder] + userToolPath(home: home, includeSbin: true))
        for (key, value) in launch { environment[key] = value }
        return environment
    }

    /// The Herdr CLI, including SSH to saved remote machines: the agent socket is forwarded when present.
    public static func herdr(home: String, user: String, sshAuthSocket: String?) -> [String: String] {
        var environment = base(home: home, user: user, path: userToolPath(home: home, includeSbin: false))
        if let sshAuthSocket { environment["SSH_AUTH_SOCK"] = sshAuthSocket }
        return environment
    }

    /// A fixed Apple executable such as `/usr/bin/shortcuts` or `/usr/bin/pmset`: system folders only.
    public static func appleTool(home: String, user: String) -> [String: String] {
        base(home: home, user: user, path: systemPath)
    }
}
