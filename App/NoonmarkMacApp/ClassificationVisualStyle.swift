import SwiftUI

func classificationUIColor(_ colorHex: String) -> Color {
    let value = colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
    let hexadecimal = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard hexadecimal.count == 6, let rgb = UInt64(hexadecimal, radix: 16) else {
        return Theme.accent
    }
    return Color(
        red: Double((rgb >> 16) & 0xFF) / 255,
        green: Double((rgb >> 8) & 0xFF) / 255,
        blue: Double(rgb & 0xFF) / 255
    )
}
