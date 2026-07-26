import NoonmarkCore

extension NoonmarkStore {
    func standaloneCollectionItems<Item>(
        _ items: [Item],
        chainID: (Item) -> TaskChainID
    ) -> [Item] {
        items.filter {
            engine.chains[chainID($0)]?.cycleMembership == nil
        }
    }
}
