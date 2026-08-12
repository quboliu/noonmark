import SwiftUI
import UniformTypeIdentifiers
import NoonmarkCore
import NoonmarkStorage

struct IOSDataPackageDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    static var writableContentTypes: [UTType] { [.json] }

    let data: Data

    init(snapshot: NoonmarkSnapshot) throws {
        data = try NoonmarkDataPackage.encode(snapshot)
    }

    init(configuration: ReadConfiguration) throws {
        guard let contents = configuration.file.regularFileContents else {
            throw DataPackageError.malformedDataPackage("数据包没有文件内容")
        }
        _ = try NoonmarkDataPackage.decode(contents)
        data = contents
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
