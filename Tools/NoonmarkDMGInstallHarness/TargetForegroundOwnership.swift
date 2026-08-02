import AppKit
import Darwin
import Foundation

protocol TargetRunningApplication: AnyObject {
    var processIdentifier: pid_t { get }
    var isTerminated: Bool { get }
    var bundleIdentifier: String? { get }
    var bundleURL: URL? { get }
    var activationPolicy: NSApplication.ActivationPolicy { get }
    var isActive: Bool { get }

    func activate(options: NSApplication.ActivationOptions) -> Bool
    func isSameProcessInstance(as other: TargetRunningApplication) -> Bool
}

extension NSRunningApplication: TargetRunningApplication {
    func isSameProcessInstance(as other: TargetRunningApplication) -> Bool {
        guard let other = other as? NSRunningApplication else { return false }
        return isEqual(other)
    }
}

protocol TargetFrontmostObserving: AnyObject {
    var isFrontmost: Bool { get }
}

extension AXTarget: TargetFrontmostObserving {
    var isFrontmost: Bool {
        boolean(application, kAXFrontmostAttribute as String) == true
    }
}

struct TargetProcessInstanceToken: Equatable {
    let startTimeSeconds: UInt64
    let startTimeMicroseconds: UInt64

    static func read(processIdentifier: pid_t) -> Self? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let byteCount = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(
                processIdentifier,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                expectedSize
            )
        }
        guard byteCount == expectedSize,
              info.pbi_pid == UInt32(processIdentifier),
              info.pbi_start_tvsec > 0,
              info.pbi_start_tvusec < 1_000_000
        else {
            return nil
        }
        return Self(
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec
        )
    }
}

/// Establishes foreground ownership only after the exact target identity has
/// been proven. Subsequent interaction remains verify-only and fail-closed.
struct TargetForegroundOwnership {
    struct ExpectedIdentity {
        let processIdentifier: pid_t
        let bundleIdentifier: String
        let bundleURL: URL
    }

    struct Evidence: Equatable {
        let processIdentifier: pid_t
        let processInstance: TargetProcessInstanceToken
        let activationPolicy: String
        let requestAccepted: Bool
        let activeBefore: Bool
        let axFrontmostBefore: Bool
        let activeAfter: Bool
        let axFrontmostAfter: Bool

        var ledgerDetail: String {
            "process_identifier=\(processIdentifier) "
                + "process_start_tvsec=\(processInstance.startTimeSeconds) "
                + "process_start_tvusec=\(processInstance.startTimeMicroseconds) "
                + "activation_policy=\(activationPolicy) "
                + "request_accepted=\(requestAccepted) "
                + "active_before=\(activeBefore) "
                + "ax_frontmost_before=\(axFrontmostBefore) "
                + "active_after=\(activeAfter) "
                + "ax_frontmost_after=\(axFrontmostAfter)"
        }
    }

    enum Failure: LocalizedError, Equatable {
        case identityMismatch(String)
        case processInstanceUnavailable
        case processInstanceChanged
        case unsupportedActivationPolicy(String)
        case activationRequestRejected
        case targetTerminatedDuringProof
        case frontmostProofTimedOut

        var errorDescription: String? {
            switch self {
            case let .identityMismatch(field):
                "Validation target identity changed before activation: \(field)"
            case .processInstanceUnavailable:
                "Validation target process instance identity was unavailable"
            case .processInstanceChanged:
                "Validation target process instance changed during activation"
            case let .unsupportedActivationPolicy(policy):
                "Validation target activation policy was \(policy), expected regular"
            case .activationRequestRejected:
                "Validation target rejected the exact-process activation request"
            case .targetTerminatedDuringProof:
                "Validation target terminated while proving foreground ownership"
            case .frontmostProofTimedOut:
                "Timed out proving both AppKit-active and AX-frontmost for the validation app"
            }
        }
    }

    let expected: ExpectedIdentity
    let application: TargetRunningApplication
    let accessibility: TargetFrontmostObserving
    let timeout: TimeInterval
    let uptime: () -> TimeInterval
    let resolveApplication: (pid_t) -> TargetRunningApplication?
    let readProcessInstance: (pid_t) -> TargetProcessInstanceToken?
    let pumpEvents: (TimeInterval) -> Void

    init(
        expected: ExpectedIdentity,
        application: TargetRunningApplication,
        accessibility: TargetFrontmostObserving,
        timeout: TimeInterval = 8,
        uptime: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        resolveApplication: @escaping (pid_t) -> TargetRunningApplication? = {
            NSRunningApplication(processIdentifier: $0)
        },
        readProcessInstance: @escaping (pid_t) -> TargetProcessInstanceToken? = {
            TargetProcessInstanceToken.read(processIdentifier: $0)
        },
        pumpEvents: @escaping (TimeInterval) -> Void = { interval in
            RunLoop.current.run(
                until: Date(timeIntervalSinceNow: interval)
            )
        }
    ) {
        self.expected = expected
        self.application = application
        self.accessibility = accessibility
        self.timeout = timeout
        self.uptime = uptime
        self.resolveApplication = resolveApplication
        self.readProcessInstance = readProcessInstance
        self.pumpEvents = pumpEvents
    }

    func establish() throws -> Evidence {
        guard timeout.isFinite, timeout >= 0 else {
            throw Failure.frontmostProofTimedOut
        }
        try verifyExactIdentity(application)
        guard let processInstance = readProcessInstance(
            expected.processIdentifier
        ) else {
            throw Failure.processInstanceUnavailable
        }
        let current = try resolveCurrentApplication(
            processInstance: processInstance
        )
        let policy = Self.activationPolicyName(current.activationPolicy)
        guard current.activationPolicy == .regular else {
            throw Failure.unsupportedActivationPolicy(policy)
        }

        let activeBefore = current.isActive
        let axFrontmostBefore = accessibility.isFrontmost
        let requestAccepted = current.activate(options: [])
        guard requestAccepted else {
            throw Failure.activationRequestRejected
        }

        let deadline = uptime() + timeout
        while true {
            guard uptime() <= deadline else {
                throw Failure.frontmostProofTimedOut
            }
            let observed = try resolveCurrentApplication(
                processInstance: processInstance
            )
            let activeAfter = observed.isActive
            let axFrontmostAfter = accessibility.isFrontmost
            let proofTime = uptime()
            if activeAfter, axFrontmostAfter, proofTime <= deadline {
                return Evidence(
                    processIdentifier: expected.processIdentifier,
                    processInstance: processInstance,
                    activationPolicy: policy,
                    requestAccepted: requestAccepted,
                    activeBefore: activeBefore,
                    axFrontmostBefore: axFrontmostBefore,
                    activeAfter: activeAfter,
                    axFrontmostAfter: axFrontmostAfter
                )
            }
            guard proofTime < deadline else {
                throw Failure.frontmostProofTimedOut
            }
            pumpEvents(min(0.05, deadline - proofTime))
        }
    }

    private func resolveCurrentApplication(
        processInstance: TargetProcessInstanceToken
    ) throws -> TargetRunningApplication {
        guard let current = resolveApplication(expected.processIdentifier) else {
            throw Failure.targetTerminatedDuringProof
        }
        guard application.isSameProcessInstance(as: current) else {
            throw Failure.processInstanceChanged
        }
        try verifyExactIdentity(current)
        guard readProcessInstance(expected.processIdentifier) == processInstance else {
            throw Failure.processInstanceChanged
        }
        return current
    }

    private func verifyExactIdentity(
        _ candidate: TargetRunningApplication
    ) throws {
        guard candidate.processIdentifier == expected.processIdentifier else {
            throw Failure.identityMismatch("process_identifier")
        }
        guard candidate.isTerminated == false else {
            throw Failure.identityMismatch("terminated")
        }
        guard candidate.bundleIdentifier == expected.bundleIdentifier else {
            throw Failure.identityMismatch("bundle_identifier")
        }
        guard let bundleURL = candidate.bundleURL else {
            throw Failure.identityMismatch("bundle_url")
        }
        let expectedPath = expected.bundleURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        let actualPath = bundleURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard actualPath == expectedPath else {
            throw Failure.identityMismatch("bundle_path")
        }
    }

    private static func activationPolicyName(
        _ policy: NSApplication.ActivationPolicy
    ) -> String {
        switch policy {
        case .regular:
            "regular"
        case .accessory:
            "accessory"
        case .prohibited:
            "prohibited"
        @unknown default:
            "unknown-\(policy.rawValue)"
        }
    }
}
