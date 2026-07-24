import NoonmarkCore
import NoonmarkMacRuntime
import SwiftUI

func classificationUIColor(
    _ colorHex: String,
    fallback: Color = Theme.accent
) -> Color {
    let value = colorHex.trimmingCharacters(in: .whitespacesAndNewlines)
    let hexadecimal = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard hexadecimal.count == 6, let rgb = UInt64(hexadecimal, radix: 16) else {
        return fallback
    }
    return Color(
        red: Double((rgb >> 16) & 0xFF) / 255,
        green: Double((rgb >> 8) & 0xFF) / 255,
        blue: Double(rgb & 0xFF) / 255
    )
}

extension TaskClassificationProjection {
    var isEmpty: Bool {
        category == nil && labels.isEmpty
    }
}

extension ClassificationItemProjection {
    private var categoryVisualStyle: TaskCategoryVisualStyle {
        TaskCategoryVisualStyle(
            colorHex: colorHex,
            isUserApproved: presentationApproval == .userApproved
        )
    }

    var color: Color {
        classificationUIColor(colorHex, fallback: Theme.navPool)
    }

    var categoryPresentationColor: Color {
        guard let foregroundColorHex = categoryVisualStyle.foregroundColorHex else {
            return Theme.text1
        }
        return classificationUIColor(foregroundColorHex, fallback: Theme.text1)
    }

    var usesApprovedCategoryPresentation: Bool {
        categoryVisualStyle.usesTintedBackground
    }
}

extension ClassificationCatalogItemProjection {
    private var categoryVisualStyle: TaskCategoryVisualStyle {
        TaskCategoryVisualStyle(
            colorHex: colorHex,
            isUserApproved: presentationApproval == .userApproved
        )
    }

    var color: Color {
        classificationUIColor(colorHex, fallback: Theme.navPool)
    }

    var categoryPresentationColor: Color {
        guard let foregroundColorHex = categoryVisualStyle.foregroundColorHex else {
            return Theme.text1
        }
        return classificationUIColor(foregroundColorHex, fallback: Theme.text1)
    }

    var usesApprovedCategoryPresentation: Bool {
        categoryVisualStyle.usesTintedBackground
    }
}
