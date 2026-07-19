import AppKit
import NoonmarkMacUIContract
import SwiftUI

enum NoonmarkVisualMetrics {
    static let launchSize = NSSize(
        width: MacUIWindowLayout.defaultWidth,
        height: MacUIWindowLayout.defaultHeight
    )
    static let minimumSize = NSSize(
        width: MacUIWindowLayout.minimumWidth,
        height: MacUIWindowLayout.minimumHeight
    )

    static let sidebarWidth = CGFloat(MacUIShellLayout.sidebarWidth)
    static let detailRailWidth = CGFloat(MacUIShellLayout.detailRailWidth)
    static let calendarRailWidth = CGFloat(MacUIShellLayout.calendarRailWidth)
    static let toolbarButtonSize = CGFloat(MacUIShellLayout.toolbarButtonSize)
    static let pageHorizontalPadding = CGFloat(MacUIShellLayout.pageHorizontalPadding)
    static let taskRowVerticalPadding = CGFloat(MacUIShellLayout.taskRowVerticalPadding)
    static let detailPadding = CGFloat(MacUIShellLayout.detailPadding)
    static let navigationRowHeight = CGFloat(MacUIShellLayout.navigationRowHeight)
    static let taskRowCompletionControlSize = CGFloat(
        MacUITaskRowLayout.completionControlSize
    )
    static let taskRowAccessorySpacing = CGFloat(MacUITaskRowLayout.accessorySpacing)
    static let calendarDetailTitlePointSize = CGFloat(
        MacUICalendarDetailRowLayout.titlePointSize
    )
    static let calendarDetailMetadataPointSize = CGFloat(
        MacUICalendarDetailRowLayout.metadataPointSize
    )
    static let calendarDetailHorizontalPadding = CGFloat(
        MacUICalendarDetailRowLayout.horizontalPadding
    )
    static let calendarDetailVerticalPadding = CGFloat(
        MacUICalendarDetailRowLayout.verticalPadding
    )
    static let futurePlanMetadataSpacing = CGFloat(
        MacUIFuturePlanDetailLayout.metadataSpacing
    )

    static let detailTitleDescriptionSpacing = CGFloat(
        MacUIDetailEditorLayout.titleDescriptionSpacing
    )
    static let detailTitleMinimumHeight = CGFloat(
        MacUIDetailEditorLayout.titleHeight.lowerBound
    )
    static let detailTitleMaximumHeight = CGFloat(
        MacUIDetailEditorLayout.titleHeight.upperBound
    )
    static let detailDescriptionMinimumHeight = CGFloat(
        MacUIDetailEditorLayout.descriptionHeight.lowerBound
    )
    static let detailDescriptionMaximumHeight = CGFloat(
        MacUIDetailEditorLayout.descriptionHeight.upperBound
    )
    static let detailTextInset = CGFloat(MacUIDetailEditorLayout.textInset)

    static let toolbarIconSize = CGFloat(MacUIIconMetrics.toolbarSize)
    static let navigationIconSize = CGFloat(MacUIIconMetrics.navigationSize)
    static let compactEditorPointSize = CGFloat(MacUITypographyMetrics.compactEditorPointSize)
    static let compactEditorVerticalInset = CGFloat(
        MacUITypographyMetrics.compactEditorVerticalInset
    )

    static func compactPointSize(_ baseSize: CGFloat) -> CGFloat {
        CGFloat(MacUITypographyMetrics.compactPointSize(Double(baseSize)))
    }
}

extension Font {
    static func noonmarkSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(
            size: NoonmarkVisualMetrics.compactPointSize(size),
            weight: weight,
            design: design
        )
    }

    static func noonmarkCustom(_ name: String, size: CGFloat) -> Font {
        .custom(name, size: NoonmarkVisualMetrics.compactPointSize(size))
    }

    static func noonmarkRenderedSystem(
        size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}

extension NSFont {
    static func noonmarkSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight = .regular
    ) -> NSFont {
        .systemFont(
            ofSize: NoonmarkVisualMetrics.compactPointSize(size),
            weight: weight
        )
    }
}
