import XCTest
@testable import VolantCore

final class ChildProcessEnvironmentTests: XCTestCase {
    private let home = "/Users/fictional"
    private let user = "fictional"

    /// Every builder returns exactly the named keys and the fixed UTF-8 locale.
    func testEveryEnvironmentIsMinimalWithFixedLocale() {
        let built = [
            ChildProcessEnvironment.acpProvider(home: home, user: user, executable: "/opt/fictional/bin/agent", launch: [:]),
            ChildProcessEnvironment.herdr(home: home, user: user, sshAuthSocket: nil),
            ChildProcessEnvironment.appleTool(home: home, user: user)
        ]
        for environment in built {
            XCTAssertEqual(Set(environment.keys), ["HOME", "USER", "PATH", "LANG"])
            XCTAssertEqual(environment["HOME"], home)
            XCTAssertEqual(environment["USER"], user)
            XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
            XCTAssertNil(environment["LC_ALL"])
        }
    }

    /// ACP searches the provider's folder first, keeps sbin, and applies launch variables last.
    func testACPProviderPathAndLaunchVariables() {
        let environment = ChildProcessEnvironment.acpProvider(home: home, user: user, executable: "/opt/fictional/bin/node",
                                                              launch: ["CLAUDE_CODE_EXECUTABLE": "/opt/fictional/bin/claude"])
        XCTAssertEqual(environment["PATH"], "/opt/fictional/bin:/Users/fictional/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertEqual(environment["CLAUDE_CODE_EXECUTABLE"], "/opt/fictional/bin/claude")
        XCTAssertEqual(environment.count, 5)
    }

    /// Herdr omits sbin and forwards only an existing SSH agent socket.
    func testHerdrPathAndSSHSocket() {
        let plain = ChildProcessEnvironment.herdr(home: home, user: user, sshAuthSocket: nil)
        XCTAssertEqual(plain["PATH"], "/Users/fictional/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin")
        let forwarded = ChildProcessEnvironment.herdr(home: home, user: user, sshAuthSocket: "/private/tmp/fictional/agent.sock")
        XCTAssertEqual(forwarded["SSH_AUTH_SOCK"], "/private/tmp/fictional/agent.sock")
        XCTAssertEqual(forwarded.count, 5)
    }

    /// Apple tools search only system folders, never owner-writable ones.
    func testAppleToolUsesSystemFoldersOnly() {
        let environment = ChildProcessEnvironment.appleTool(home: home, user: user)
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }

    /// git status keeps its separate C locale for byte-stable parsing.
    func testRepositoryStatusKeepsCLocale() {
        XCTAssertEqual(RepositoryStatusCommand.environment(home: home)["LC_ALL"], "C")
    }
}
