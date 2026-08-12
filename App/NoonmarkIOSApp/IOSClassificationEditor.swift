@_spi(ClassificationUserDecision) import NoonmarkCore
import SwiftUI

enum IOSClassificationTarget: Hashable {
    case task(TaskChainID)
    case taskCycle(TaskCycleSeriesID)
}

struct IOSClassificationEditor: View {
    @EnvironmentObject private var store: IOSStore
    let target: IOSClassificationTarget

    @State private var categoryID: String?
    @State private var labelIDs = Set<String>()

    private var catalog: ClassificationCatalogProjection? {
        store.classificationCatalog
    }

    var body: some View {
        Group {
            if let catalog {
                Picker("分类", selection: categoryBinding) {
                    Text("未分类").tag(String?.none)
                    ForEach(catalog.categories.filter { $0.lifecycle == .active }) { item in
                        Text(item.name).tag(Optional(item.id))
                    }
                }
                .accessibilityIdentifier("ios.classification.category")

                ForEach(catalog.labels.filter { $0.lifecycle == .active }) { item in
                    Toggle(item.name, isOn: labelBinding(for: item.id))
                        .accessibilityIdentifier("ios.classification.label.\(item.id)")
                }
            } else {
                Text("当前没有可用分类目录")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: target) { _, _ in
            load()
        }
    }

    private var categoryBinding: Binding<String?> {
        Binding(
            get: { categoryID },
            set: {
                categoryID = $0
                save()
            }
        )
    }

    private func labelBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { labelIDs.contains(id) },
            set: { enabled in
                if enabled {
                    labelIDs.insert(id)
                } else {
                    labelIDs.remove(id)
                }
                save()
            }
        )
    }

    private func load() {
        let projection: TaskClassificationProjection? = switch target {
        case let .task(chainID):
            store.taskClassification(for: chainID)
        case let .taskCycle(seriesID):
            store.taskCycleClassification(for: seriesID)
        }
        categoryID = projection?.category?.id
        labelIDs = Set(projection?.labels.map(\.id) ?? [])
    }

    private func save() {
        switch target {
        case let .task(chainID):
            store.setTaskClassification(
                chainID: chainID,
                categoryID: categoryID,
                labelIDs: labelIDs
            )
        case let .taskCycle(seriesID):
            store.setTaskCycleClassification(
                seriesID: seriesID,
                categoryID: categoryID,
                labelIDs: labelIDs
            )
        }
    }
}
