import Foundation

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
else {
    FileHandle.standardError.write(Data("release summary is empty or invalid UTF-8\n".utf8))
    exit(EXIT_FAILURE)
}

guard text.unicodeScalars.allSatisfy({ scalar in
    scalar.value == 0x0A || scalar.value == 0x0D ||
        scalar.value == 0x09 || (0x20...0x7E).contains(scalar.value)
}) else {
    FileHandle.standardError.write(
        Data("release summary must use ASCII English text\n".utf8)
    )
    exit(EXIT_FAILURE)
}
