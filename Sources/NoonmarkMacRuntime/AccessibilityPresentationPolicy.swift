public struct AccessibilityDisplayOptions: Equatable, Sendable {
    public let increasesContrast: Bool
    public let differentiatesWithoutColor: Bool
    public let reducesMotion: Bool
    public let reducesTransparency: Bool

    public init(
        increasesContrast: Bool,
        differentiatesWithoutColor: Bool,
        reducesMotion: Bool,
        reducesTransparency: Bool
    ) {
        self.increasesContrast = increasesContrast
        self.differentiatesWithoutColor = differentiatesWithoutColor
        self.reducesMotion = reducesMotion
        self.reducesTransparency = reducesTransparency
    }
}

public struct AccessibilityPresentationPolicy: Equatable, Sendable {
    public let options: AccessibilityDisplayOptions

    public init(options: AccessibilityDisplayOptions) {
        self.options = options
    }

    public var animatesTransitions: Bool {
        options.reducesMotion == false
    }

    public var usesTextualCountMarkers: Bool {
        options.differentiatesWithoutColor
    }

    public var layeredSurfaceOpacity: Double {
        options.reducesTransparency ? 1 : 0.78
    }

    public var usesEnhancedBoundaries: Bool {
        options.increasesContrast
    }
}
