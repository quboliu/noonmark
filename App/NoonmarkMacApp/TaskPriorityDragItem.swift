import NoonmarkCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let noonmarkTaskPriority = UTType(
        exportedAs: "app.noonmark.task-priority"
    )
}

struct TaskPriorityDragItem: Codable, Hashable, Transferable {
    let traceID: DayTraceID
    let date: LocalDate

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .noonmarkTaskPriority)
    }
}
