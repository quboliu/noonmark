public enum IMETextBindingPublicationPolicy {
    public static func shouldPublishToSwiftUI(
        isComposing: Bool,
        defersMarkedTextUpdates: Bool
    ) -> Bool {
        defersMarkedTextUpdates == false || isComposing == false
    }
}
