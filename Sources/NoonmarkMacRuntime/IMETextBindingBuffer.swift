/// Owns the boundary between an AppKit field editor's native draft and a
/// SwiftUI binding.
///
/// Marked text and short bursts stay native. A versioned publication schedule
/// exposes only a complete, idle snapshot to the parent binding. This prevents
/// parent view updates from replacing the field editor between IME phrases.
public struct IMETextBindingBuffer: Sendable {
    public struct PublicationSchedule:
        Equatable,
        Hashable,
        Sendable
    {
        public let revision: UInt64
        public let sequence: UInt64
        public let delayMilliseconds: UInt64
    }

    public enum SchedulingDirective: Equatable, Sendable {
        case unchanged
        case cancel
        case schedule(PublicationSchedule)
    }

    public enum ExternalTextDecision: Equatable, Sendable {
        case preserveNative
        case applyExternal(String)
    }

    public static let defaultIdleDelayMilliseconds: UInt64 = 200

    public private(set) var nativeText: String
    public private(set) var isComposing = false

    public var hasUnpublishedText: Bool {
        nativeText != publishedText
    }

    private var publishedText: String
    private var revision: UInt64 = 0
    private var sequence: UInt64 = 0

    public init(initialText: String) {
        nativeText = initialText
        publishedText = initialText
    }

    public mutating func nativeSnapshotDidChange(
        text nextText: String,
        isComposing nextIsComposing: Bool
    ) -> SchedulingDirective {
        let textChanged = nativeText != nextText
        let compositionChanged =
            isComposing != nextIsComposing
        guard textChanged || compositionChanged else {
            return .unchanged
        }
        nativeText = nextText
        isComposing = nextIsComposing
        revision &+= 1
        invalidateSchedule()
        guard isComposing == false,
              hasUnpublishedText
        else {
            return .cancel
        }
        return .schedule(
            PublicationSchedule(
                revision: revision,
                sequence: sequence,
                delayMilliseconds:
                Self.defaultIdleDelayMilliseconds
            )
        )
    }

    public mutating func reconcileExternalText(
        _ nextText: String
    ) -> ExternalTextDecision {
        if nextText == nativeText {
            guard isComposing == false else {
                return .preserveNative
            }
            publishedText = nextText
            invalidateSchedule()
            return .preserveNative
        }
        guard isComposing == false,
              hasUnpublishedText == false
        else {
            return .preserveNative
        }
        nativeText = nextText
        publishedText = nextText
        revision &+= 1
        invalidateSchedule()
        return .applyExternal(nextText)
    }

    public mutating func takePublication(
        for schedule: PublicationSchedule
    ) -> String? {
        guard schedule.revision == revision,
              schedule.sequence == sequence,
              isComposing == false,
              hasUnpublishedText
        else {
            return nil
        }
        return acknowledgeNativeText()
    }

    public mutating func takeImmediatePublication() -> String? {
        guard isComposing == false,
              hasUnpublishedText
        else {
            return nil
        }
        return acknowledgeNativeText()
    }

    private mutating func acknowledgeNativeText() -> String {
        publishedText = nativeText
        invalidateSchedule()
        return nativeText
    }

    private mutating func invalidateSchedule() {
        sequence &+= 1
    }
}
