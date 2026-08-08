import Foundation
import NaturalLanguage

let input = FileHandle.standardInput.readDataToEndOfFile()
guard let text = String(data: input, encoding: .utf8),
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
else {
    FileHandle.standardError.write(Data("release summary is empty or invalid UTF-8\n".utf8))
    exit(EXIT_FAILURE)
}

let recognizer = NLLanguageRecognizer()
recognizer.processString(text)
let dominantLanguage = recognizer.dominantLanguage
guard dominantLanguage == .english else {
    let detected = dominantLanguage?.rawValue ?? "unknown"
    FileHandle.standardError.write(
        Data("release summary language is \(detected), expected en\n".utf8)
    )
    exit(EXIT_FAILURE)
}

