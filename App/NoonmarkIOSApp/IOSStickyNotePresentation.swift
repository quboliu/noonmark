import Foundation

enum StickyNotePresentationMode: String, CaseIterable, Identifiable {
    case stream
    case wall

    var id: String { rawValue }
}
