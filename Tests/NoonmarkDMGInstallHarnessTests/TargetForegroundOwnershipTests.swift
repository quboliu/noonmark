import AppKit
@testable import NoonmarkDMGInstallHarness
import XCTest

final class TargetForegroundOwnershipTests: XCTestCase {
    private let expectedBundleIdentifier = "app.noonmark.mac.dmg-validation"
    private let expectedBundleURL = URL(
        fileURLWithPath: "/tmp/noonmark-foreground-tests/NoonmarkDMGValidation.app"
    )
    private let processInstance = TargetProcessInstanceToken(
        startTimeSeconds: 1_800_000_000,
        startTimeMicroseconds: 123_456
    )

    func testKernelProcessInstanceTokenIsStableForTheCurrentProcess() {
        let first = TargetProcessInstanceToken.read(
            processIdentifier: getpid()
        )
        let second = TargetProcessInstanceToken.read(
            processIdentifier: getpid()
        )

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertLessThan(first?.startTimeMicroseconds ?? .max, 1_000_000)
    }

    func testIdentityMismatchOrTerminatedProcessNeverRequestsActivation() {
        let cases: [(String, FakeRunningApplication)] = [
            (
                "pid",
                FakeRunningApplication(
                    processIdentifier: 42,
                    bundleIdentifier: expectedBundleIdentifier,
                    bundleURL: expectedBundleURL
                )
            ),
            (
                "bundle",
                FakeRunningApplication(
                    bundleIdentifier: "app.noonmark.mac",
                    bundleURL: expectedBundleURL
                )
            ),
            (
                "path",
                FakeRunningApplication(
                    bundleIdentifier: expectedBundleIdentifier,
                    bundleURL: URL(fileURLWithPath: "/tmp/forged.app")
                )
            ),
            (
                "terminated",
                FakeRunningApplication(
                    isTerminated: true,
                    bundleIdentifier: expectedBundleIdentifier,
                    bundleURL: expectedBundleURL
                )
            )
        ]

        for (name, application) in cases {
            XCTAssertThrowsError(
                try makeOwnership(application: application).establish(),
                name
            )
            XCTAssertEqual(application.activationRequestCount, 0, name)
        }
    }

    func testNonRegularTargetNeverRequestsActivation() {
        let application = FakeRunningApplication(
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: expectedBundleURL,
            activationPolicy: .accessory
        )

        XCTAssertThrowsError(
            try makeOwnership(application: application).establish()
        ) { error in
            XCTAssertEqual(
                error as? TargetForegroundOwnership.Failure,
                .unsupportedActivationPolicy("accessory")
            )
        }
        XCTAssertEqual(application.activationRequestCount, 0)
    }

    func testRejectedActivationRequestFailsClosed() {
        let application = FakeRunningApplication(
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: expectedBundleURL,
            activationAccepted: false
        )

        XCTAssertThrowsError(
            try makeOwnership(application: application).establish()
        ) { error in
            XCTAssertEqual(
                error as? TargetForegroundOwnership.Failure,
                .activationRequestRejected
            )
        }
        XCTAssertEqual(application.activationRequestCount, 1)
        XCTAssertEqual(application.lastActivationOptions?.rawValue, 0)
    }

    func testReusedPIDWithTheSameBundleAndPathNeverRequestsActivation() {
        let original = FakeRunningApplication(
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: expectedBundleURL,
            instanceIdentifier: "original"
        )
        let replacement = FakeRunningApplication(
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: expectedBundleURL,
            instanceIdentifier: "replacement"
        )

        XCTAssertThrowsError(
            try makeOwnership(
                application: original,
                resolveApplication: { _ in replacement }
            ).establish()
        ) { error in
            XCTAssertEqual(
                error as? TargetForegroundOwnership.Failure,
                .processInstanceChanged
            )
        }
        XCTAssertEqual(original.activationRequestCount, 0)
        XCTAssertEqual(replacement.activationRequestCount, 0)
    }

    func testAppKitOnlyOrAccessibilityOnlyFrontmostStateFailsClosed() {
        let cases = [
            (
                "AppKit-only",
                FakeRunningApplication(
                    bundleIdentifier: expectedBundleIdentifier,
                    bundleURL: expectedBundleURL,
                    isActive: true
                ),
                FakeFrontmostObserver(isFrontmost: false)
            ),
            (
                "AX-only",
                FakeRunningApplication(
                    bundleIdentifier: expectedBundleIdentifier,
                    bundleURL: expectedBundleURL,
                    isActive: false
                ),
                FakeFrontmostObserver(isFrontmost: true)
            )
        ]

        for (name, application, accessibility) in cases {
            XCTAssertThrowsError(
                try makeOwnership(
                    application: application,
                    accessibility: accessibility,
                    timeout: 0
                ).establish(),
                name
            ) { error in
                XCTAssertEqual(
                    error as? TargetForegroundOwnership.Failure,
                    .frontmostProofTimedOut
                )
            }
        }
    }

    func testExactTargetMustReachBothFrontmostSignalsWithinOriginalBudget() throws {
        let application = FakeRunningApplication(
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: expectedBundleURL,
            isActive: false
        )
        let accessibility = FakeFrontmostObserver(isFrontmost: false)
        var uptime: TimeInterval = 100
        let ownership = makeOwnership(
            application: application,
            accessibility: accessibility,
            timeout: 8,
            uptime: { uptime },
            pumpEvents: { interval in
                uptime += interval
                application.isActive = true
                accessibility.isFrontmost = true
            }
        )

        let evidence = try ownership.establish()

        XCTAssertEqual(application.activationRequestCount, 1)
        XCTAssertEqual(application.lastActivationOptions?.rawValue, 0)
        XCTAssertEqual(evidence.processIdentifier, 41)
        XCTAssertEqual(evidence.processInstance, processInstance)
        XCTAssertEqual(evidence.activationPolicy, "regular")
        XCTAssertTrue(evidence.requestAccepted)
        XCTAssertFalse(evidence.activeBefore)
        XCTAssertFalse(evidence.axFrontmostBefore)
        XCTAssertTrue(evidence.activeAfter)
        XCTAssertTrue(evidence.axFrontmostAfter)
    }

    func testProofThatAppearsAfterTheMonotonicDeadlineIsRejected() {
        let application = FakeRunningApplication(
            bundleIdentifier: expectedBundleIdentifier,
            bundleURL: expectedBundleURL,
            isActive: false
        )
        let accessibility = FakeFrontmostObserver(isFrontmost: false)
        var uptime: TimeInterval = 200

        XCTAssertThrowsError(
            try makeOwnership(
                application: application,
                accessibility: accessibility,
                timeout: 0.05,
                uptime: { uptime },
                pumpEvents: { interval in
                    uptime += interval + 0.001
                    application.isActive = true
                    accessibility.isFrontmost = true
                }
            ).establish()
        ) { error in
            XCTAssertEqual(
                error as? TargetForegroundOwnership.Failure,
                .frontmostProofTimedOut
            )
        }
    }

    private func makeOwnership(
        application: FakeRunningApplication,
        accessibility: FakeFrontmostObserver = FakeFrontmostObserver(
            isFrontmost: false
        ),
        timeout: TimeInterval = 8,
        uptime: @escaping () -> TimeInterval = { 0 },
        resolveApplication: ((pid_t) -> TargetRunningApplication?)? = nil,
        readProcessInstance: ((pid_t) -> TargetProcessInstanceToken?)? = nil,
        pumpEvents: @escaping (TimeInterval) -> Void = { _ in }
    ) -> TargetForegroundOwnership {
        TargetForegroundOwnership(
            expected: .init(
                processIdentifier: 41,
                bundleIdentifier: expectedBundleIdentifier,
                bundleURL: expectedBundleURL
            ),
            application: application,
            accessibility: accessibility,
            timeout: timeout,
            uptime: uptime,
            resolveApplication: resolveApplication ?? { _ in application },
            readProcessInstance: readProcessInstance ?? { _ in
                self.processInstance
            },
            pumpEvents: pumpEvents
        )
    }
}

private final class FakeRunningApplication: TargetRunningApplication {
    let processIdentifier: pid_t
    var isTerminated: Bool
    let bundleIdentifier: String?
    let bundleURL: URL?
    let activationPolicy: NSApplication.ActivationPolicy
    var isActive: Bool
    let activationAccepted: Bool
    let instanceIdentifier: String
    private(set) var activationRequestCount = 0
    private(set) var lastActivationOptions: NSApplication.ActivationOptions?

    init(
        processIdentifier: pid_t = 41,
        isTerminated: Bool = false,
        bundleIdentifier: String?,
        bundleURL: URL?,
        activationPolicy: NSApplication.ActivationPolicy = .regular,
        isActive: Bool = false,
        activationAccepted: Bool = true,
        instanceIdentifier: String = "original"
    ) {
        self.processIdentifier = processIdentifier
        self.isTerminated = isTerminated
        self.bundleIdentifier = bundleIdentifier
        self.bundleURL = bundleURL
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.activationAccepted = activationAccepted
        self.instanceIdentifier = instanceIdentifier
    }

    func activate(options: NSApplication.ActivationOptions) -> Bool {
        activationRequestCount += 1
        lastActivationOptions = options
        return activationAccepted
    }

    func isSameProcessInstance(as other: TargetRunningApplication) -> Bool {
        guard let other = other as? FakeRunningApplication else { return false }
        return instanceIdentifier == other.instanceIdentifier
    }
}

private final class FakeFrontmostObserver: TargetFrontmostObserving {
    var isFrontmost: Bool

    init(isFrontmost: Bool) {
        self.isFrontmost = isFrontmost
    }
}
