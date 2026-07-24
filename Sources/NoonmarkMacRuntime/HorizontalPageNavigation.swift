public enum HorizontalPageNavigationDirection: Equatable, Sendable {
    case previous
    case next
}

public enum HorizontalPageNavigationPhase: Equatable, Sendable {
    case none
    case mayBegin
    case began
    case changed
    case ended
    case cancelled
}

public struct HorizontalPageNavigationSample: Equatable, Sendable {
    public let deltaX: Double
    public let deltaY: Double
    public let phase: HorizontalPageNavigationPhase
    public let isMomentum: Bool
    public let isPrecise: Bool

    public init(
        deltaX: Double,
        deltaY: Double,
        phase: HorizontalPageNavigationPhase,
        isMomentum: Bool = false,
        isPrecise: Bool = true
    ) {
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.phase = phase
        self.isMomentum = isMomentum
        self.isPrecise = isPrecise
    }
}

/// Recognizes one deliberate horizontal page change from a precise trackpad
/// scroll sequence while leaving vertical and diagonal scrolling untouched.
public struct HorizontalPageNavigationRecognizer: Sendable {
    public struct Policy: Equatable, Sendable {
        public let minimumAxisLockDistance: Double
        public let horizontalDominanceRatio: Double
        public let activationDistance: Double

        public init(
            minimumAxisLockDistance: Double = 8,
            horizontalDominanceRatio: Double = 1.35,
            activationDistance: Double = 48
        ) {
            precondition(minimumAxisLockDistance > 0)
            precondition(horizontalDominanceRatio > 1)
            precondition(activationDistance >= minimumAxisLockDistance)
            self.minimumAxisLockDistance = minimumAxisLockDistance
            self.horizontalDominanceRatio = horizontalDominanceRatio
            self.activationDistance = activationDistance
        }

        public static let standard = Policy()
    }

    private enum AxisLock {
        case undecided
        case horizontal
        case vertical
    }

    private let policy: Policy
    private var accumulatedX = 0.0
    private var accumulatedY = 0.0
    private var axisLock = AxisLock.undecided
    private var didNavigate = false
    private var isTrackingGesture = false

    public init(policy: Policy = .standard) {
        self.policy = policy
    }

    public mutating func consume(
        _ sample: HorizontalPageNavigationSample
    ) -> HorizontalPageNavigationDirection? {
        if sample.phase == .mayBegin || sample.phase == .began {
            reset()
            guard sample.isPrecise, sample.isMomentum == false else {
                return nil
            }
            isTrackingGesture = true
        }

        if sample.phase == .ended || sample.phase == .cancelled {
            reset()
            return nil
        }

        guard isTrackingGesture,
              sample.phase != .none,
              sample.isPrecise,
              sample.isMomentum == false,
              didNavigate == false
        else {
            return nil
        }

        accumulatedX += sample.deltaX
        accumulatedY += sample.deltaY
        resolveAxisLockIfNeeded()

        guard axisLock == .horizontal,
              abs(accumulatedX) >= policy.activationDistance,
              abs(accumulatedX)
              >= abs(accumulatedY) * policy.horizontalDominanceRatio
        else {
            return nil
        }

        didNavigate = true
        return accumulatedX > 0 ? .next : .previous
    }

    public mutating func reset() {
        accumulatedX = 0
        accumulatedY = 0
        axisLock = .undecided
        didNavigate = false
        isTrackingGesture = false
    }

    private mutating func resolveAxisLockIfNeeded() {
        guard axisLock == .undecided else { return }
        let horizontalDistance = abs(accumulatedX)
        let verticalDistance = abs(accumulatedY)
        guard max(horizontalDistance, verticalDistance)
            >= policy.minimumAxisLockDistance
        else {
            return
        }
        let horizontalDominates = horizontalDistance
            >= verticalDistance * policy.horizontalDominanceRatio
        let verticalDominates = verticalDistance
            >= horizontalDistance * policy.horizontalDominanceRatio

        if horizontalDominates {
            axisLock = .horizontal
        } else if verticalDominates {
            axisLock = .vertical
        }
    }
}
