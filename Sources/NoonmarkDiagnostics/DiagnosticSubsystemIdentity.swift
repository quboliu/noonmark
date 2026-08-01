import Foundation

enum DiagnosticSubsystemIdentity {
    static let invalidRuntime = "app.noonmark.invalid-runtime"

    static func resolve(bundleIdentifier: String?) -> String {
        guard let bundleIdentifier,
              bundleIdentifier.isEmpty == false
        else { return invalidRuntime }
        return bundleIdentifier
    }

    static var current: String {
        resolve(bundleIdentifier: Bundle.main.bundleIdentifier)
    }
}
