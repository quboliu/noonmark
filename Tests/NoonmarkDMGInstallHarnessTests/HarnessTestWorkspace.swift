import Foundation

/// Descriptor-bound fixtures need a physical path without macOS /var aliases.
/// Foundation's temporaryDirectory does not honor the build wrapper's TMPDIR.
enum HarnessTestWorkspace {
    static var fixtureRoot: URL {
        let buildRoot = ProcessInfo.processInfo.environment["NOONMARK_BUILD_ROOT"]
            ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("BUILD/projs/noonmark", isDirectory: true).path
        return URL(fileURLWithPath: buildRoot, isDirectory: true)
            .appendingPathComponent("tmp/test-fixtures", isDirectory: true)
    }
}
