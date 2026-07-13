import NoonmarkCore

extension ClassificationCatalogProjection {
    func manageableItems(for kind: ClassificationItemKind) -> [ClassificationCatalogItemProjection] {
        let source = kind == .category ? categories : labels
        return source.filter { $0.mergedIntoID == nil }
    }

    func activeManageableItems(for kind: ClassificationItemKind) -> [ClassificationCatalogItemProjection] {
        manageableItems(for: kind).filter { $0.lifecycle == .active }
    }
}
